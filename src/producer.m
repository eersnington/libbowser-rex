#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include "frames.h"
#include "internal.h"
#import "remote_api.h"

enum { EV_ATTACHED = 1000, EV_DETACHED };

@class BWSurface;

@interface BWConn : NSObject {
 @public
  int fd;
  bw_buf rx;
  dispatch_source_t source;
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

@interface BWProducer : NSObject {
 @public
  bowser_producer_config_s cfg;
  NSLock *lock; // guards everything below that the io queue touches
  dispatch_queue_t io;
  int listenFd;
  char socketPath[104];
  dispatch_source_t acceptSource;
  bw_frame_server *frameServer;
  char frameService[BW_SERVICE_NAME_MAX];
  NSMutableArray<BWEvent *> *events;
  NSMutableDictionary<NSString *, BWSurface *> *tickets;
  NSMutableSet<BWConn *> *conns;
  NSMutableSet<BWSurface *> *surfaces; // keeps surfaces alive until bowser_surface_free
}
@end

@interface BWSurface : NSObject {
 @public
  __weak BWProducer *producer;
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
  bw_buf_free(&rx);
  if (framePort) mach_port_deallocate(mach_task_self(), framePort);
}
@end

@implementation BWEvent
- (void)dealloc {
  bw_buf_free(&payload);
}
@end

@implementation BWSurface
@end

@implementation BWProducer
@end

static inline BWProducer *P(bowser_producer_t *p) { return (__bridge BWProducer *)(void *)p; }
static inline BWSurface *S(bowser_surface_t *s) { return (__bridge BWSurface *)(void *)s; }
static inline bowser_surface_t *S_C(BWSurface *s) { return (__bridge bowser_surface_t *)s; }

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

// Call with p->lock held.
static void close_conn(BWProducer *p, BWConn *c) {
  if (c->source) {
    dispatch_source_cancel(c->source);
    c->source = nil;
    c->fd = -1; // the cancel handler closes the socket
  }
  BWSurface *s = c->surface;
  if (s && s->conn == c) s->conn = nil;
  c->surface = nil;
  [p->conns removeObject:c];
}

static void send_locked(BWConn *c, uint16_t type, bw_buf *payload) {
  if (c && c->fd >= 0) bw_send(c->fd, type, payload);
}

static void handle_hello(BWProducer *p, BWConn *c, bw_buf *payload) {
  bw_rd r = bw_reader(payload);
  char *token = bw_get_str(&r);
  NSString *key = [NSString stringWithUTF8String:token];
  free(token);

  BWSurface *s = key ? p->tickets[key] : nil;
  if (key) [p->tickets removeObjectForKey:key]; // single use, even when it fails below
  if (!s) {
    bw_buf out = {0};
    bw_put_u32(&out, BOWSER_ERR_TICKET);
    send_locked(c, BW_MSG_REJECT, &out);
    bw_buf_free(&out);
    close_conn(p, c);
    return;
  }

  BWConn *old = s->conn;
  c->surface = s;
  c->nonce = ((uint64_t)arc4random() << 32) | arc4random();
  s->conn = c;

  bw_buf out = {0};
  bw_put_u32(&out, p->cfg.transport);
  bw_put_u32(&out, s->contextId);
  bw_put_size(&out, s->size);
  bw_put_str(&out, p->frameService);
  bw_put_u64(&out, c->nonce);
  send_locked(c, BW_MSG_WELCOME, &out);
  bw_buf_free(&out);

  if (old) {
    bw_buf why = {0};
    bw_put_u32(&why, BOWSER_ERR_REPLACED);
    send_locked(old, BW_MSG_DETACH, &why);
    bw_buf_free(&why);
    old->surface = nil; // the surface stays attached, so no EV_DETACHED
    close_conn(p, old);
  }
  enqueue(p, EV_ATTACHED, s, NULL);
}

static void conn_readable(BWProducer *p, BWConn *c) {
  bool alive = bw_recv_some(c->fd, &c->rx);
  bool woke = false;
  [p->lock lock];
  uint16_t type;
  bw_buf payload;
  bool bad = false;
  while (c->source && bw_next_frame(&c->rx, &type, &payload, &bad)) {
    if (!c->surface) {
      if (type == BW_MSG_HELLO) handle_hello(p, c, &payload);
      else close_conn(p, c);
      woke = true;
    } else if (type >= BW_MSG_RESIZE && type <= BW_MSG_TEXT) {
      enqueue(p, type, c->surface, &payload);
      woke = true;
    }
    bw_buf_free(&payload);
  }
  if ((!alive || bad) && c->source) {
    BWSurface *s = c->surface;
    if (s && s->conn == c) {
      enqueue(p, EV_DETACHED, s, NULL);
      woke = true;
    }
    close_conn(p, c);
  }
  [p->lock unlock];
  if (woke) wake(p);
}

static void accept_ready(BWProducer *p) {
  int fd = accept(p->listenFd, NULL, NULL);
  if (fd < 0) return;
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);

  BWConn *c = [BWConn new];
  c->fd = fd;
  c->source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, p->io);
  __weak BWConn *weakConn = c;
  __weak BWProducer *weakProducer = p;
  dispatch_source_set_event_handler(c->source, ^{
    BWConn *conn = weakConn;
    BWProducer *producer = weakProducer;
    if (conn && producer) conn_readable(producer, conn);
  });
  dispatch_source_set_cancel_handler(c->source, ^{ close(fd); });
  [p->lock lock];
  [p->conns addObject:c];
  [p->lock unlock];
  dispatch_resume(c->source);
}

static void on_subscribe(void *ctx, uint64_t nonce, mach_port_t port) {
  BWProducer *p = (__bridge BWProducer *)ctx;
  [p->lock lock];
  for (BWConn *c in p->conns) {
    if (c->surface && c->nonce == nonce) {
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

bowser_result_e bowser_producer_new(const bowser_producer_config_s *cfg, bowser_producer_t **out) {
  if (!cfg || !out || cfg->size < sizeof *cfg) return bw_fail(BOWSER_ERR_INVALID, "bad config");
  if (cfg->transport != BOWSER_TRANSPORT_CALAYERHOST && cfg->transport != BOWSER_TRANSPORT_IOSURFACE)
    return bw_fail(BOWSER_ERR_TRANSPORT, "unknown transport %d", cfg->transport);

  BWProducer *p = [BWProducer new];
  p->cfg = *cfg;
  p->lock = [NSLock new];
  p->io = dispatch_queue_create("dev.libbowser.producer.io", DISPATCH_QUEUE_SERIAL);
  p->events = [NSMutableArray new];
  p->tickets = [NSMutableDictionary new];
  p->conns = [NSMutableSet new];
  p->surfaces = [NSMutableSet new];

  const char *tmp = getenv("TMPDIR");
  if (!tmp || strlen(tmp) > 60) tmp = "/tmp/";
  snprintf(p->socketPath, sizeof p->socketPath, "%s%sbowser-%d-%08x.sock", tmp,
           tmp[strlen(tmp) - 1] == '/' ? "" : "/", getpid(), arc4random());

  p->listenFd = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un addr = {.sun_family = AF_UNIX};
  strlcpy(addr.sun_path, p->socketPath, sizeof addr.sun_path);
  if (p->listenFd < 0 || bind(p->listenFd, (struct sockaddr *)&addr, sizeof addr) != 0 ||
      listen(p->listenFd, 8) != 0) {
    if (p->listenFd >= 0) close(p->listenFd);
    return bw_fail(BOWSER_ERR_TRANSPORT, "can't listen on %s", p->socketPath);
  }
  chmod(p->socketPath, 0600);

  if (cfg->transport == BOWSER_TRANSPORT_IOSURFACE) {
    p->frameServer = bw_frame_server_new(p->frameService, on_subscribe, (__bridge void *)p);
    if (!p->frameServer) {
      close(p->listenFd);
      unlink(p->socketPath);
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

void bowser_producer_free(bowser_producer_t *handle) {
  if (!handle) return;
  BWProducer *p = (__bridge_transfer BWProducer *)(void *)handle;
  dispatch_source_cancel(p->acceptSource);
  [p->lock lock];
  for (BWConn *c in [p->conns allObjects]) close_conn(p, c);
  [p->surfaces removeAllObjects];
  [p->lock unlock];
  dispatch_sync(p->io, ^{}); // no io handler runs after this
  bw_frame_server_free(p->frameServer);
  unlink(p->socketPath);
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
  }
}

void bowser_producer_tick(bowser_producer_t *handle) {
  BWProducer *p = P(handle);
  [p->lock lock];
  NSArray<BWEvent *> *batch = [p->events copy];
  [p->events removeAllObjects];
  [p->lock unlock];
  for (BWEvent *e in batch) {
    // Skip events for surfaces freed since they were queued.
    if ([p->surfaces containsObject:e->surface]) dispatch_event(p, e);
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
  *out = S_C(s);
  return BOWSER_OK;
}

void bowser_surface_free(bowser_surface_t *handle) {
  BWSurface *s = S(handle);
  BWProducer *p = s ? s->producer : nil;
  if (!p) return;
  [p->lock lock];
  for (NSString *k in [p->tickets allKeysForObject:s]) [p->tickets removeObjectForKey:k];
  if (s->conn) {
    bw_buf why = {0};
    bw_put_u32(&why, BOWSER_ERR_DISCONNECTED);
    send_locked(s->conn, BW_MSG_DETACH, &why);
    bw_buf_free(&why);
    close_conn(p, s->conn);
  }
  s->context.layer = nil;
  s->context = nil;
  [p->surfaces removeObject:s];
  [p->lock unlock];
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
  [p->lock lock];
  p->tickets[@(token)] = s;
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
  if (!p || p->cfg.transport != BOWSER_TRANSPORT_IOSURFACE)
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

static void send_to_host(bowser_surface_t *handle, uint16_t type, bw_buf *payload) {
  BWSurface *s = S(handle);
  BWProducer *p = s->producer;
  if (!p) return;
  [p->lock lock];
  send_locked(s->conn, type, payload);
  [p->lock unlock];
}

void bowser_surface_set_caret(bowser_surface_t *s, bowser_rect_s caret) {
  bw_buf b = {0};
  bw_put_rect(&b, caret);
  send_to_host(s, BW_MSG_CARET, &b);
  bw_buf_free(&b);
}

void bowser_surface_set_composition(bowser_surface_t *s, bool active, const bowser_rect_s *rects, size_t count) {
  bw_buf b = {0};
  bw_put_u8(&b, active);
  bw_put_u32(&b, (uint32_t)count);
  for (size_t i = 0; i < count; i++) bw_put_rect(&b, rects[i]);
  send_to_host(s, BW_MSG_COMPOSITION, &b);
  bw_buf_free(&b);
}

void bowser_surface_set_cursor(bowser_surface_t *s, bowser_cursor_e cursor) {
  bw_buf b = {0};
  bw_put_u32(&b, cursor);
  send_to_host(s, BW_MSG_CURSOR, &b);
  bw_buf_free(&b);
}
