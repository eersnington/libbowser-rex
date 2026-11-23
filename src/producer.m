#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include "frames.h"
#include "internal.h"
#import "link.h"
#import "remote_api.h"

enum { EV_ATTACHED = 1000, EV_DETACHED };

// Queued input events, across all hosts, before the producer stops reading
// from its hosts. A producer that doesn't tick then pushes back on its hosts,
// whose send queues merge latest-wins input and finally drop it as stalled.
#define MAX_EVENTS 4096

#define TICKET_TTL_NS (60 * NSEC_PER_SEC)

@class BWSurface;

typedef enum {
  CONN_NEW,     // waiting for HELLO
  CONN_WELCOME, // sent WELCOME, waiting for READY
  CONN_LIVE,    // the surface's host
} conn_state;

@interface BWConn : NSObject {
 @public
  BWLink *link; // nil once closed
  conn_state state;
  bool paused;
  uint64_t nonce;
  mach_port_t framePort; // send right to the host's frame port, IOSURFACE only
  __weak BWSurface *surface;
}
@end

@interface BWEvent : NSObject {
 @public
  uint16_t type;
  BWSurface *surface;
  bw_buf payload;
}
@end

@interface BWTicket : NSObject {
 @public
  BWSurface *surface;
  uint64_t expires; // CLOCK_MONOTONIC ns, which counts sleep
}
@end

@interface BWProducer : NSObject {
 @public
  bowser_producer_config_s cfg;
  NSLock *lock; // guards everything below that the io queue touches
  dispatch_queue_t io;
  int listenFd;
  char socketDir[96];
  char socketPath[104];
  dispatch_source_t acceptSource;
  bw_frame_server *frameServer;
  char frameService[BW_SERVICE_NAME_MAX];
  uint64_t ticketTTL;
  NSMutableArray<BWEvent *> *events;
  NSMutableDictionary<NSString *, BWTicket *> *tickets;
  NSMutableSet<BWConn *> *conns;
  NSMutableSet<BWSurface *> *surfaces; // live surfaces
}
@end

@interface BWSurface : NSObject {
 @public
  __weak BWProducer *producer; // nil once the surface or its producer is freed
  bool live;
  bowser_size_s size;
  CAContext *context; // CALAYERHOST only
  CALayer *root;
  CAContextID contextId;
  BWConn *conn; // the attached host, if any
  uint64_t frameSeq;
}
@end

@implementation BWConn
- (void)dealloc {
  if (framePort) mach_port_deallocate(mach_task_self(), framePort);
}
@end

@implementation BWEvent
- (void)dealloc {
  bw_buf_free(&payload);
}
@end

@implementation BWTicket
@end

@implementation BWSurface
@end

@implementation BWProducer
@end

static inline BWProducer *P(bowser_producer_t *p) { return (__bridge BWProducer *)(void *)p; }
static inline BWSurface *S(bowser_surface_t *s) { return (__bridge BWSurface *)(void *)s; }
static inline bowser_surface_t *S_C(BWSurface *s) { return (__bridge bowser_surface_t *)s; }

static uint64_t monotonic_ns(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC); }

// ---- io queue ---------------------------------------------------------

// Call with p->lock held.
static void enqueue(BWProducer *p, uint16_t type, BWSurface *s, bw_buf *payload) {
  BWEvent *e = [BWEvent new];
  e->type = type;
  e->surface = s;
  if (payload) {
    e->payload = *payload;
    *payload = (bw_buf){0};
  }
  [p->events addObject:e];
}

static void wake(BWProducer *p) {
  if (p->cfg.wakeup_cb) p->cfg.wakeup_cb(p->cfg.userdata);
}

// Call with p->lock held. finish: write what's queued for the host first.
static void close_conn(BWProducer *p, BWConn *c, bool finish) {
  if (!c->link) return;
  if (finish) bw_link_finish(c->link);
  else bw_link_close(c->link);
  c->link = nil;
  BWSurface *s = c->surface;
  if (s && s->conn == c) s->conn = nil;
  c->surface = nil;
  [p->conns removeObject:c];
}

// Call with p->lock held.
static void send_result(BWConn *c, uint16_t type, bowser_result_e why) {
  bw_buf b = {0};
  bw_put_u32(&b, why);
  bw_link_send(c->link, type, &b);
  bw_buf_free(&b);
}

// Call with p->lock held.
static void prune_tickets(BWProducer *p) {
  uint64_t now = monotonic_ns();
  NSMutableArray *expired = [NSMutableArray new];
  [p->tickets enumerateKeysAndObjectsUsingBlock:^(NSString *k, BWTicket *t, BOOL *stop) {
    if (t->expires <= now) [expired addObject:k];
  }];
  [p->tickets removeObjectsForKeys:expired];
}

static void handle_hello(BWProducer *p, BWConn *c, bw_buf *payload) {
  bw_rd r = bw_reader(payload);
  char *token = bw_get_str(&r);
  NSString *key = [NSString stringWithUTF8String:token];
  free(token);

  prune_tickets(p);
  BWTicket *t = key ? p->tickets[key] : nil;
  if (key) [p->tickets removeObjectForKey:key]; // single use, even when it fails below
  BWSurface *s = t ? t->surface : nil;
  if (!s || !s->live) {
    send_result(c, BW_MSG_REJECT, BOWSER_ERR_TICKET);
    close_conn(p, c, true);
    return;
  }
  c->surface = s;
  c->nonce = ((uint64_t)arc4random() << 32) | arc4random();
  c->state = CONN_WELCOME;

  bw_buf out = {0};
  bw_put_u32(&out, p->cfg.transport);
  bw_put_u32(&out, s->contextId);
  bw_put_size(&out, s->size);
  bw_put_str(&out, p->frameService);
  bw_put_u64(&out, c->nonce);
  bw_link_send(c->link, BW_MSG_WELCOME, &out);
  bw_buf_free(&out);
}

// READY: the new host is fully set up, so only now does it replace the old
// one. A host that fails after WELCOME leaves the current host attached.
static void handle_ready(BWProducer *p, BWConn *c) {
  BWSurface *s = c->surface;
  if (!s || !s->live) {
    close_conn(p, c, false);
    return;
  }
  BWConn *old = s->conn;
  s->conn = c;
  c->state = CONN_LIVE;
  if (old) {
    send_result(old, BW_MSG_DETACH, BOWSER_ERR_REPLACED);
    close_conn(p, old, true); // the surface stays attached, so no EV_DETACHED
  }
  enqueue(p, EV_ATTACHED, s, NULL);
}

static void conn_read(BWProducer *p, BWConn *c) {
  bool woke = false;
  [p->lock lock];
  uint16_t type;
  bw_buf payload;
  while (c->link && !c->paused && bw_link_next(c->link, &type, &payload)) {
    if (c->state == CONN_NEW && type == BW_MSG_HELLO) {
      handle_hello(p, c, &payload);
    } else if (c->state == CONN_WELCOME && type == BW_MSG_READY) {
      handle_ready(p, c);
      woke = true;
    } else if (c->state == CONN_LIVE &&
               ((type >= BW_MSG_RESIZE && type <= BW_MSG_TEXT) || type == BW_MSG_MESSAGE || type == BW_MSG_DISPLAY)) {
      enqueue(p, type, c->surface, &payload);
      woke = true;
      if (p->events.count >= MAX_EVENTS) {
        bw_link_pause(c->link);
        c->paused = true;
      }
    } else {
      close_conn(p, c, false); // out of order: not our host
    }
    bw_buf_free(&payload);
  }
  bowser_result_e why;
  if (c->link && !c->paused && bw_link_ended(c->link, &why)) {
    if (c->state == CONN_LIVE) {
      enqueue(p, EV_DETACHED, c->surface, NULL);
      woke = true;
    }
    close_conn(p, c, false);
  }
  [p->lock unlock];
  if (woke) wake(p);
}

static void accept_ready(BWProducer *p) {
  int fd = accept(p->listenFd, NULL, NULL);
  if (fd < 0) return;
  // macOS has no accept4. A child that inherits this socket, such as a shell
  // or an engine helper, would keep the host from seeing the producer exit.
  fcntl(fd, F_SETFD, FD_CLOEXEC);
  uid_t uid;
  gid_t gid;
  if (getpeereid(fd, &uid, &gid) != 0 || uid != geteuid()) {
    close(fd);
    return;
  }
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);

  BWConn *c = [BWConn new];
  __weak BWConn *weakConn = c;
  __weak BWProducer *weakProducer = p;
  c->link = bw_link_new(fd, p->io, NULL, ^{
    BWConn *conn = weakConn;
    BWProducer *producer = weakProducer;
    if (conn && producer) conn_read(producer, conn);
  });
  [p->lock lock];
  [p->conns addObject:c];
  [p->lock unlock];
  bw_link_start(c->link);
}

static void on_subscribe(void *ctx, uint64_t nonce, mach_port_t port) {
  BWProducer *p = (__bridge BWProducer *)ctx;
  [p->lock lock];
  for (BWConn *c in p->conns) {
    if (c->state != CONN_NEW && c->nonce == nonce) {
      if (c->framePort) mach_port_deallocate(mach_task_self(), c->framePort);
      c->framePort = port;
      port = MACH_PORT_NULL;
      break;
    }
  }
  [p->lock unlock];
  if (port) mach_port_deallocate(mach_task_self(), port);
}

// ---- Producer API -----------------------------------------------------

static bool make_socket_path(BWProducer *p) {
  const char *tmp = getenv("TMPDIR");
  if (!tmp || !*tmp || strlen(tmp) > 64) tmp = "/tmp";
  snprintf(p->socketDir, sizeof p->socketDir, "%s%sbowser.XXXXXX", tmp, tmp[strlen(tmp) - 1] == '/' ? "" : "/");
  // mkdtemp makes the directory 0700, so only our user can reach the socket,
  // from the moment it exists.
  if (!mkdtemp(p->socketDir)) return false;
  snprintf(p->socketPath, sizeof p->socketPath, "%s/s", p->socketDir);
  return true;
}

bowser_result_e bowser_producer_new(const bowser_producer_config_s *cfg, bowser_producer_t **out) {
  bowser_producer_config_s config;
  if (!cfg || !out || !bw_copy_config(&config, sizeof config, cfg, BOWSER_PRODUCER_CONFIG_MIN_SIZE))
    return bw_fail(BOWSER_ERR_INVALID, "bad config");
  if (config.transport != BOWSER_TRANSPORT_CALAYERHOST && config.transport != BOWSER_TRANSPORT_IOSURFACE)
    return bw_fail(BOWSER_ERR_TRANSPORT, "unknown transport %d", config.transport);

  BWProducer *p = [BWProducer new];
  p->cfg = config;
  p->lock = [NSLock new];
  p->io = dispatch_queue_create("dev.libbowser.producer.io", DISPATCH_QUEUE_SERIAL);
  p->events = [NSMutableArray new];
  p->tickets = [NSMutableDictionary new];
  p->conns = [NSMutableSet new];
  p->surfaces = [NSMutableSet new];
  // Test hook: the end-to-end tests shorten the ticket lifetime.
  const char *ttl = getenv("BOWSER_TICKET_TTL_MS");
  p->ticketTTL = ttl ? strtoull(ttl, NULL, 10) * NSEC_PER_MSEC : TICKET_TTL_NS;

  if (!make_socket_path(p)) return bw_fail(BOWSER_ERR_TRANSPORT, "can't make a socket directory in %s", p->socketDir);
  p->listenFd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (p->listenFd >= 0) fcntl(p->listenFd, F_SETFD, FD_CLOEXEC);
  struct sockaddr_un addr = {.sun_family = AF_UNIX};
  strlcpy(addr.sun_path, p->socketPath, sizeof addr.sun_path);
  if (p->listenFd < 0 || bind(p->listenFd, (struct sockaddr *)&addr, sizeof addr) != 0 ||
      listen(p->listenFd, 8) != 0) {
    if (p->listenFd >= 0) close(p->listenFd);
    unlink(p->socketPath);
    rmdir(p->socketDir);
    return bw_fail(BOWSER_ERR_TRANSPORT, "can't listen on %s", p->socketPath);
  }
  // A client that gives up between the read event and accept() must not
  // block the io queue.
  fcntl(p->listenFd, F_SETFL, fcntl(p->listenFd, F_GETFL) | O_NONBLOCK);

  if (config.transport == BOWSER_TRANSPORT_IOSURFACE) {
    p->frameServer = bw_frame_server_new(p->frameService, on_subscribe, (__bridge void *)p);
    if (!p->frameServer) {
      close(p->listenFd);
      unlink(p->socketPath);
      rmdir(p->socketDir);
      return bw_fail(BOWSER_ERR_TRANSPORT, "can't start the frame service");
    }
  }

  int listenFd = p->listenFd;
  p->acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)listenFd, 0, p->io);
  __weak BWProducer *weakProducer = p;
  dispatch_source_set_event_handler(p->acceptSource, ^{
    BWProducer *producer = weakProducer;
    if (producer) accept_ready(producer);
  });
  dispatch_source_set_cancel_handler(p->acceptSource, ^{ close(listenFd); });
  dispatch_resume(p->acceptSource);

  *out = (__bridge_retained void *)p;
  return BOWSER_OK;
}

// Call with p->lock held. Tells the surface's hosts, live and pending, why.
static void end_surface(BWProducer *p, BWSurface *s, bowser_result_e why) {
  s->live = false;
  NSMutableArray *dead = [NSMutableArray new];
  [p->tickets enumerateKeysAndObjectsUsingBlock:^(NSString *k, BWTicket *t, BOOL *stop) {
    if (t->surface == s) [dead addObject:k];
  }];
  [p->tickets removeObjectsForKeys:dead];
  for (BWConn *c in [p->conns allObjects]) {
    if (c->surface != s) continue;
    send_result(c, BW_MSG_DETACH, why);
    close_conn(p, c, true);
  }
  [p->surfaces removeObject:s];
}

void bowser_producer_free(bowser_producer_t *handle) {
  if (!handle) return;
  BWProducer *p = (__bridge_transfer BWProducer *)(void *)handle;
  dispatch_source_cancel(p->acceptSource);
  [p->lock lock];
  NSArray<BWSurface *> *surfaces = [p->surfaces allObjects];
  for (BWSurface *s in surfaces) {
    end_surface(p, s, BOWSER_ERR_DISCONNECTED);
    s->producer = nil; // the handle stays valid but inert
  }
  for (BWConn *c in [p->conns allObjects]) close_conn(p, c, false);
  [p->lock unlock];
  dispatch_sync(p->io, ^{}); // no io handler runs after this
  bw_frame_server_free(p->frameServer);
  for (BWSurface *s in surfaces) {
    s->context.layer = nil;
    s->context = nil;
  }
  unlink(p->socketPath);
  rmdir(p->socketDir);
}

static void dispatch_event(BWProducer *p, BWEvent *e) {
  const bowser_producer_config_s *cfg = &p->cfg;
  void *ud = cfg->userdata;
  bowser_surface_t *s = S_C(e->surface);
  bw_rd r = bw_reader(&e->payload);

  switch (e->type) {
  case EV_ATTACHED:
  case EV_DETACHED:
    if (cfg->attach_cb) cfg->attach_cb(ud, s, e->type == EV_ATTACHED);
    break;
  case BW_MSG_RESIZE: {
    bowser_size_s size = bw_get_size(&r);
    if (r.err || size.width <= 0 || size.height <= 0 || size.scale <= 0) break;
    [p->lock lock];
    e->surface->size = size;
    [p->lock unlock];
    if (e->surface->root) {
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      e->surface->root.frame = CGRectMake(0, 0, size.width, size.height);
      [CATransaction commit];
    }
    if (cfg->resize_cb) cfg->resize_cb(ud, s, size);
    break;
  }
  case BW_MSG_FOCUS: {
    bool focused = bw_get_u8(&r);
    if (!r.err && cfg->focus_cb) cfg->focus_cb(ud, s, focused);
    break;
  }
  case BW_MSG_KEY: {
    bowser_key_s k = {0};
    k.action = (bowser_key_action_e)bw_get_u32(&r);
    k.keycode = (uint16_t)bw_get_u32(&r);
    k.mods = bw_get_u64(&r);
    char *text = bw_get_str(&r), *unmod = bw_get_str(&r);
    k.text = text;
    k.unmodified_text = unmod;
    k.timestamp_ns = bw_get_u64(&r);
    if (!r.err && cfg->key_cb) cfg->key_cb(ud, s, &k);
    free(text);
    free(unmod);
    break;
  }
  case BW_MSG_MOUSE: {
    bowser_mouse_s m = {0};
    m.action = (bowser_mouse_action_e)bw_get_u32(&r);
    m.button = bw_get_i32(&r);
    m.x = bw_get_f64(&r);
    m.y = bw_get_f64(&r);
    m.click_count = bw_get_i32(&r);
    m.mods = bw_get_u64(&r);
    m.timestamp_ns = bw_get_u64(&r);
    if (!r.err && cfg->mouse_cb) cfg->mouse_cb(ud, s, &m);
    break;
  }
  case BW_MSG_SCROLL: {
    bowser_scroll_s sc = {0};
    sc.dx = bw_get_f64(&r);
    sc.dy = bw_get_f64(&r);
    sc.precise = bw_get_u8(&r);
    sc.phase = bw_get_i32(&r);
    sc.momentum_phase = bw_get_i32(&r);
    sc.x = bw_get_f64(&r);
    sc.y = bw_get_f64(&r);
    sc.mods = bw_get_u64(&r);
    sc.timestamp_ns = bw_get_u64(&r);
    if (!r.err && cfg->scroll_cb) cfg->scroll_cb(ud, s, &sc);
    break;
  }
  case BW_MSG_TEXT: {
    bowser_text_s t = {0};
    t.kind = (bowser_text_kind_e)bw_get_u32(&r);
    char *text = bw_get_str(&r);
    t.text = text;
    t.selected_location = bw_get_i64(&r);
    t.selected_length = bw_get_i64(&r);
    t.replacement_location = bw_get_i64(&r);
    t.replacement_length = bw_get_i64(&r);
    if (!r.err && cfg->text_cb) cfg->text_cb(ud, s, &t);
    free(text);
    break;
  }
  case BW_MSG_MESSAGE: {
    char *name, *body;
    if (!bw_get_message(&r, &name, &body)) break;
    if (cfg->message_cb) cfg->message_cb(ud, s, name, body);
    free(name);
    free(body);
    break;
  }
  case BW_MSG_DISPLAY: {
    uint32_t display = bw_get_u32(&r);
    if (!r.err && cfg->display_cb) cfg->display_cb(ud, s, display);
    break;
  }
  }
}

void bowser_producer_tick(bowser_producer_t *handle) {
  BWProducer *p = P(handle);
  [p->lock lock];
  NSArray<BWEvent *> *batch = [p->events copy];
  [p->events removeAllObjects];
  for (BWConn *c in p->conns) {
    if (!c->paused) continue;
    c->paused = false;
    bw_link_resume(c->link);
  }
  [p->lock unlock];
  for (BWEvent *e in batch) {
    // A callback may free a surface, or the producer; then it gets nothing more.
    if (e->surface->live) dispatch_event(p, e);
  }
}

// ---- Surface API ------------------------------------------------------

bowser_result_e bowser_surface_new(bowser_producer_t *handle, bowser_size_s size, bowser_surface_t **out) {
  BWProducer *p = P(handle);
  if (!p || !out) return bw_fail(BOWSER_ERR_INVALID, "null argument");
  if (size.width <= 0 || size.height <= 0) return bw_fail(BOWSER_ERR_INVALID, "empty size");
  if (size.scale <= 0) size.scale = 1;

  BWSurface *s = [BWSurface new];
  s->producer = p;
  s->live = true;
  s->size = size;
  if (p->cfg.transport == BOWSER_TRANSPORT_CALAYERHOST) {
    s->context = [CAContext contextWithCGSConnection:CGSMainConnectionID()
                                             options:@{kCAContextCIFilterBehavior : @"ignore"}];
    if (!s->context) return bw_fail(BOWSER_ERR_TRANSPORT, "can't create a CAContext");
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    s->root = [CALayer layer];
    s->root.geometryFlipped = YES;
    s->root.anchorPoint = CGPointZero;
    s->root.frame = CGRectMake(0, 0, size.width, size.height);
    s->context.layer = s->root;
    [CATransaction commit];
    s->contextId = s->context.contextId;
  }
  [p->lock lock];
  [p->surfaces addObject:s];
  [p->lock unlock];
  // The handle owns a reference, so it outlives the producer if need be.
  *out = (__bridge_retained bowser_surface_t *)s;
  return BOWSER_OK;
}

void bowser_surface_free(bowser_surface_t *handle) {
  if (!handle) return;
  BWSurface *s = (__bridge_transfer BWSurface *)(void *)handle;
  BWProducer *p = s->producer;
  if (!p) return;
  s->producer = nil;
  [p->lock lock];
  end_surface(p, s, BOWSER_ERR_DISCONNECTED);
  [p->lock unlock];
  s->context.layer = nil;
  s->context = nil;
}

bowser_size_s bowser_surface_size(bowser_surface_t *handle) {
  BWSurface *s = S(handle);
  BWProducer *p = s->producer;
  [p->lock lock];
  bowser_size_s size = s->size;
  [p->lock unlock];
  return size;
}

char *bowser_surface_ticket(bowser_surface_t *handle) {
  BWSurface *s = S(handle);
  BWProducer *p = s ? s->producer : nil;
  if (!p) return NULL;
  uint8_t raw[BW_TOKEN_LEN / 2];
  arc4random_buf(raw, sizeof raw);
  char token[BW_TOKEN_LEN + 1];
  for (size_t i = 0; i < sizeof raw; i++) snprintf(token + i * 2, 3, "%02x", raw[i]);
  BWTicket *t = [BWTicket new];
  t->surface = s;
  t->expires = monotonic_ns() + p->ticketTTL;
  [p->lock lock];
  prune_tickets(p);
  p->tickets[@(token)] = t;
  [p->lock unlock];
  char *ticket = NULL;
  asprintf(&ticket, BW_TICKET_PREFIX "%s#%s", p->socketPath, token);
  return ticket;
}

CALayer *bowser_surface_root_layer(bowser_surface_t *handle) { return S(handle)->root; }

bowser_result_e bowser_surface_present(bowser_surface_t *handle, IOSurfaceRef surface, bowser_rect_s dirty) {
  (void)dirty; // the whole surface is sent; dirty rects are for a later damage-tracking pass
  BWSurface *s = S(handle);
  BWProducer *p = s->producer;
  if (!p) return bw_fail(BOWSER_ERR_DISCONNECTED, "the producer is gone");
  if (p->cfg.transport != BOWSER_TRANSPORT_IOSURFACE)
    return bw_fail(BOWSER_ERR_TRANSPORT, "present needs the IOSURFACE transport");
  [p->lock lock];
  mach_port_t port = s->conn ? s->conn->framePort : MACH_PORT_NULL;
  if (port) mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_SEND, 1);
  uint64_t seq = ++s->frameSeq;
  [p->lock unlock];
  if (!port) return bw_fail(BOWSER_ERR_DISCONNECTED, "no host is attached");
  bool sent = bw_frame_send(port, surface, seq);
  mach_port_deallocate(mach_task_self(), port);
  return sent ? BOWSER_OK : bw_fail(BOWSER_ERR_DISCONNECTED, "host is behind; frame dropped");
}

static bowser_result_e send_to_host(bowser_surface_t *handle, uint16_t type, bw_buf *payload) {
  BWSurface *s = S(handle);
  BWProducer *p = s->producer;
  bowser_result_e rc = BOWSER_ERR_DISCONNECTED;
  if (p) {
    [p->lock lock];
    if (s->conn) rc = bw_link_send(s->conn->link, type, payload);
    [p->lock unlock];
  }
  bw_buf_free(payload);
  return rc == BOWSER_ERR_DISCONNECTED ? bw_fail(rc, "no host is attached") : rc;
}

bowser_result_e bowser_surface_set_caret(bowser_surface_t *s, bowser_rect_s caret) {
  bw_buf b = {0};
  bw_put_rect(&b, caret);
  return send_to_host(s, BW_MSG_CARET, &b);
}

bowser_result_e bowser_surface_set_composition(bowser_surface_t *s, bool active, const bowser_rect_s *rects,
                                               size_t count) {
  bw_buf b = {0};
  bw_put_u8(&b, active);
  bw_put_u32(&b, (uint32_t)count);
  for (size_t i = 0; i < count; i++) bw_put_rect(&b, rects[i]);
  return send_to_host(s, BW_MSG_COMPOSITION, &b);
}

bowser_result_e bowser_surface_set_cursor(bowser_surface_t *s, bowser_cursor_e cursor) {
  bw_buf b = {0};
  bw_put_u32(&b, cursor);
  return send_to_host(s, BW_MSG_CURSOR, &b);
}

bowser_result_e bowser_surface_send(bowser_surface_t *s, const char *name, const char *body) {
  bw_buf b = {0};
  bowser_result_e rc = bw_put_message(&b, name, body);
  if (rc) return rc;
  return send_to_host(s, BW_MSG_PRODUCER_MESSAGE, &b);
}
