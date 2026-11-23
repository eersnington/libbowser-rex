#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "frames.h"
#include "internal.h"
#import "link.h"
#import "remote_api.h"

#define ATTACH_TIMEOUT_NS (3 * NSEC_PER_SEC)

// Messages waiting for a tick before the host stops reading. A host that
// doesn't tick then pushes back on the producer, as a producer does on hosts.
#define MAX_MESSAGES 4096

@interface BWMessage : NSObject {
 @public
  char *name, *body;
}
@end
@implementation BWMessage
- (void)dealloc {
  free(name);
  free(body);
}
@end

@interface BWHost : NSObject {
 @public
  bowser_host_config_s cfg;
  bowser_transport_e transport;
  BWLink *link;
  dispatch_queue_t io;
  bw_frame_client *frames;
  NSLock *lock; // guards the fields up to `closed`
  // The newest state from the producer, delivered at the next tick. Each is
  // latest-wins, so a host that ticks late holds one of each, not a queue.
  bool hasCaret, hasComposition, hasCursor;
  bowser_rect_s caret;
  bool compositionActive;
  NSData *compositionRects;
  bowser_cursor_e cursor;
  NSMutableArray<BWMessage *> *messages; // in order, never merged
  bool paused;                           // too many messages; reading waits for a tick
  bowser_result_e ended;     // why the connection ended; BOWSER_OK while it's up
  IOSurfaceRef pendingFrame; // newest unshown frame, IOSURFACE only
  bool closed;               // bowser_host_detach ran
  bool endReported;
  IOSurfaceRef shownFrame;
  CALayer *layer;   // what the embedder mounts
  CALayer *content; // CALayerHost or the IOSurface layer
  bowser_size_s size;
}
@end

// Frames arrive holding a use count (see frames.h). Giving it back tells the
// producer it may draw into the surface again.
static void release_frame(IOSurfaceRef s) {
  if (!s) return;
  IOSurfaceDecrementUseCount(s);
  CFRelease(s);
}

@implementation BWHost
- (void)dealloc {
  release_frame(pendingFrame);
  release_frame(shownFrame);
}
@end

static inline BWHost *H(bowser_host_t *h) { return (__bridge BWHost *)(void *)h; }

static void wake(BWHost *h) {
  if (h->cfg.wakeup_cb) h->cfg.wakeup_cb(h->cfg.userdata);
}

// A reason that came from the other process. It must never read as success.
static bowser_result_e peer_reason(uint32_t v) {
  return v > BOWSER_OK && v <= BOWSER_ERR_STALLED ? (bowser_result_e)v : BOWSER_ERR_DISCONNECTED;
}

static void host_read(BWHost *h) {
  bool woke = false;
  [h->lock lock];
  uint16_t type;
  bw_buf payload;
  while (!h->closed && !h->ended && !h->paused && bw_link_next(h->link, &type, &payload)) {
    bw_rd r = bw_reader(&payload);
    switch (type) {
    case BW_MSG_CARET: {
      bowser_rect_s caret = bw_get_rect(&r);
      if (r.err) break;
      h->caret = caret;
      h->hasCaret = woke = true;
      break;
    }
    case BW_MSG_COMPOSITION: {
      bool active = bw_get_u8(&r);
      uint32_t count = bw_get_u32(&r);
      if (r.err || count > r.left / 32) break;
      NSMutableData *rects = [NSMutableData dataWithLength:count * sizeof(bowser_rect_s)];
      bowser_rect_s *out = rects.mutableBytes;
      for (uint32_t i = 0; i < count; i++) out[i] = bw_get_rect(&r);
      h->compositionActive = active;
      h->compositionRects = rects;
      h->hasComposition = woke = true;
      break;
    }
    case BW_MSG_CURSOR: {
      uint32_t cursor = bw_get_u32(&r);
      if (r.err) break;
      h->cursor = (bowser_cursor_e)cursor;
      h->hasCursor = woke = true;
      break;
    }
    case BW_MSG_PRODUCER_MESSAGE: {
      BWMessage *m = [BWMessage new];
      if (!bw_get_message(&r, &m->name, &m->body)) break;
      [h->messages addObject:m];
      woke = true;
      if (h->messages.count >= MAX_MESSAGES) {
        bw_link_pause(h->link);
        h->paused = true;
      }
      break;
    }
    case BW_MSG_DETACH:
      h->ended = peer_reason(bw_get_u32(&r));
      break;
    }
    bw_buf_free(&payload);
  }
  bowser_result_e why;
  if (!h->closed && !h->paused && (h->ended || bw_link_ended(h->link, &why))) {
    if (!h->ended) h->ended = why;
    bw_link_close(h->link);
    woke = true;
  }
  bool closed = h->closed;
  [h->lock unlock];
  if (woke && !closed) wake(h);
}

static void on_frame(void *ctx, IOSurfaceRef surface, uint64_t seq) {
  (void)seq;
  BWHost *h = (__bridge BWHost *)ctx;
  [h->lock lock];
  IOSurfaceRef dropped = h->pendingFrame; // latest frame wins
  h->pendingFrame = surface;
  bool closed = h->closed;
  [h->lock unlock];
  release_frame(dropped);
  if (!closed) wake(h);
}

static bool parse_ticket(const char *ticket, char *path, size_t pathLen, char *token, size_t tokenLen) {
  size_t prefix = strlen(BW_TICKET_PREFIX);
  if (!ticket || strncmp(ticket, BW_TICKET_PREFIX, prefix) != 0) return false;
  const char *rest = ticket + prefix;
  const char *hash = strrchr(rest, '#');
  if (!hash || (size_t)(hash - rest) >= pathLen || strlen(hash + 1) >= tokenLen) return false;
  memcpy(path, rest, (size_t)(hash - rest));
  path[hash - rest] = 0;
  strlcpy(token, hash + 1, tokenLen);
  return true;
}

static void place_content(BWHost *h) {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (h->transport == BOWSER_TRANSPORT_CALAYERHOST) {
    h->content.frame = CGRectMake(0, 0, h->size.width, h->size.height);
  } else if (h->shownFrame) {
    // Show the frame at its own size: a resize never stretches an old frame.
    double scale = h->size.scale > 0 ? h->size.scale : 1;
    h->content.contentsScale = scale;
    h->content.frame = CGRectMake(0, 0, IOSurfaceGetWidth(h->shownFrame) / scale,
                                  IOSurfaceGetHeight(h->shownFrame) / scale);
  }
  [CATransaction commit];
}

static int connect_producer(const char *path) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  // macOS has no SOCK_CLOEXEC. A child that inherits this socket would keep
  // the connection open after the host detaches.
  fcntl(fd, F_SETFD, FD_CLOEXEC);
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
  struct sockaddr_un addr = {.sun_family = AF_UNIX};
  strlcpy(addr.sun_path, path, sizeof addr.sun_path);
  if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
    close(fd);
    return -1;
  }
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
  return fd;
}

// Wait for one frame, until the deadline.
static bool read_frame(int fd, bw_buf *rx, uint64_t deadline, uint16_t *type, bw_buf *payload) {
  for (;;) {
    bool bad;
    if (bw_next_frame(rx, type, payload, &bad)) return true;
    if (bad) return false;
    uint64_t now = bw_now_ns();
    if (now >= deadline) return false;
    struct pollfd pfd = {.fd = fd, .events = POLLIN};
    int n = poll(&pfd, 1, (int)((deadline - now) / NSEC_PER_MSEC) + 1);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0 || !bw_recv_some(fd, rx)) return false;
  }
}

bowser_result_e bowser_host_attach(const char *ticket, const bowser_host_config_s *cfg, bowser_host_t **out) {
  bowser_host_config_s config;
  if (!cfg || !out || !bw_copy_config(&config, sizeof config, cfg, BOWSER_HOST_CONFIG_MIN_SIZE))
    return bw_fail(BOWSER_ERR_INVALID, "bad config");
  char path[104], token[BW_TOKEN_LEN + 1];
  if (!parse_ticket(ticket, path, sizeof path, token, sizeof token))
    return bw_fail(BOWSER_ERR_TICKET, "malformed ticket");
  uint64_t deadline = bw_now_ns() + ATTACH_TIMEOUT_NS;

  int fd = connect_producer(path);
  if (fd < 0) return bw_fail(BOWSER_ERR_TICKET, "producer at %s is gone", path);
  uid_t uid;
  gid_t gid;
  // The host sends the producer keystrokes, so it must be our own user's.
  if (getpeereid(fd, &uid, &gid) != 0 || uid != geteuid()) {
    close(fd);
    return bw_fail(BOWSER_ERR_TICKET, "producer at %s belongs to another user", path);
  }

  bw_buf hello = {0}, frame = {0}, rx = {0}, payload = {0};
  bw_put_str(&hello, token);
  bw_put_frame(&frame, BW_MSG_HELLO, &hello);
  // A fresh socket has room for this small frame, so one write sends it whole.
  bool sent = write(fd, frame.data, frame.len) == (ssize_t)frame.len;
  bw_buf_free(&hello);
  bw_buf_free(&frame);
  uint16_t type = 0;
  if (!sent || !read_frame(fd, &rx, deadline, &type, &payload)) {
    bw_buf_free(&rx);
    close(fd);
    return bw_fail(BOWSER_ERR_DISCONNECTED, "no answer from the producer");
  }
  bw_rd r = bw_reader(&payload);
  if (type == BW_MSG_REJECT) {
    bowser_result_e why = peer_reason(bw_get_u32(&r));
    bw_buf_free(&payload);
    bw_buf_free(&rx);
    close(fd);
    return bw_fail(why, "the producer rejected the ticket");
  }
  bowser_transport_e transport = (bowser_transport_e)bw_get_u32(&r);
  CAContextID contextId = bw_get_u32(&r);
  bowser_size_s size = bw_get_size(&r);
  char *service = bw_get_str(&r);
  uint64_t nonce = bw_get_u64(&r);
  bool bad = r.err || type != BW_MSG_WELCOME ||
             (transport != BOWSER_TRANSPORT_CALAYERHOST && transport != BOWSER_TRANSPORT_IOSURFACE);
  bw_buf_free(&payload);
  if (bad) {
    free(service);
    bw_buf_free(&rx);
    close(fd);
    return bw_fail(BOWSER_ERR_INVALID, "malformed welcome");
  }

  BWHost *h = [BWHost new];
  h->cfg = config;
  h->transport = transport;
  h->size = size;
  h->lock = [NSLock new];
  h->messages = [NSMutableArray new];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  h->layer = [CALayer layer];
  h->layer.geometryFlipped = YES; // top-left origin, like the producer
  h->layer.masksToBounds = YES;
  if (transport == BOWSER_TRANSPORT_CALAYERHOST) {
    CALayerHost *lh = [CALayerHost layer];
    lh.contextId = contextId;
    h->content = lh;
  } else {
    h->content = [CALayer layer];
    h->content.contentsGravity = kCAGravityTopLeft;
  }
  h->content.anchorPoint = CGPointZero;
  [h->layer addSublayer:h->content];
  [CATransaction commit];
  place_content(h);

  if (transport == BOWSER_TRANSPORT_IOSURFACE) {
    uint64_t now = bw_now_ns();
    mach_msg_timeout_t left = now < deadline ? (mach_msg_timeout_t)((deadline - now) / NSEC_PER_MSEC) : 0;
    h->frames = bw_frame_client_new(service, nonce, left, on_frame, (__bridge void *)h);
    if (!h->frames) {
      free(service);
      bw_buf_free(&rx);
      close(fd);
      return bw_fail(BOWSER_ERR_TRANSPORT, "can't subscribe to frames");
    }
  }
  free(service);

  h->io = dispatch_queue_create("dev.libbowser.host.io", DISPATCH_QUEUE_SERIAL);
  __weak BWHost *weakHost = h;
  h->link = bw_link_new(fd, h->io, &rx, ^{
    BWHost *host = weakHost;
    if (host) host_read(host);
  });
  // The producer commits the attach, and replaces any older host, only now
  // that this one is fully set up.
  bw_link_send(h->link, BW_MSG_READY, NULL);
  bw_link_start(h->link);

  *out = (__bridge_retained void *)h;
  return BOWSER_OK;
}

void bowser_host_detach(bowser_host_t *handle) {
  if (!handle) return;
  BWHost *h = (__bridge_transfer BWHost *)(void *)handle;
  [h->lock lock];
  h->closed = true;
  [h->lock unlock];
  bw_link_finish(h->link); // input sent before the detach still arrives
  dispatch_sync(h->io, ^{}); // no reader runs after this
  bw_frame_client_free(h->frames);
  h->frames = NULL;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [h->layer removeFromSuperlayer];
  h->content.contents = nil;
  [CATransaction commit];
}

void bowser_host_tick(bowser_host_t *handle) {
  BWHost *h = H(handle);
  [h->lock lock];
  bool hasCaret = h->hasCaret, hasComposition = h->hasComposition, hasCursor = h->hasCursor;
  bowser_rect_s caret = h->caret;
  bool active = h->compositionActive;
  NSData *rects = h->compositionRects;
  bowser_cursor_e cursor = h->cursor;
  h->hasCaret = h->hasComposition = h->hasCursor = false;
  NSArray<BWMessage *> *messages = h->messages.count ? [h->messages copy] : nil;
  [h->messages removeAllObjects];
  if (h->paused) {
    h->paused = false;
    bw_link_resume(h->link);
  }
  bowser_result_e ended = h->endReported ? BOWSER_OK : h->ended;
  if (ended) h->endReported = true;
  IOSurfaceRef frame = h->pendingFrame;
  h->pendingFrame = NULL;
  [h->lock unlock];

  if (frame) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    h->content.contents = (__bridge id)frame;
    [CATransaction commit];
    release_frame(h->shownFrame);
    h->shownFrame = frame;
    place_content(h);
  }

  // A callback may detach the host; then it gets nothing more.
  void *ud = h->cfg.userdata;
  if (hasCaret && h->cfg.caret_cb && !h->closed) h->cfg.caret_cb(ud, handle, caret);
  if (hasComposition && h->cfg.composition_cb && !h->closed)
    h->cfg.composition_cb(ud, handle, active, rects.bytes, rects.length / sizeof(bowser_rect_s));
  if (hasCursor && h->cfg.cursor_cb && !h->closed) h->cfg.cursor_cb(ud, handle, cursor);
  // Messages sent before the producer let go arrive before detached_cb.
  for (BWMessage *m in messages) {
    if (!h->cfg.message_cb || h->closed) break;
    h->cfg.message_cb(ud, handle, m->name, m->body);
  }
  if (ended && h->cfg.detached_cb && !h->closed) h->cfg.detached_cb(ud, handle, ended);
}

bowser_transport_e bowser_host_transport(bowser_host_t *h) { return H(h)->transport; }
CALayer *bowser_host_layer(bowser_host_t *h) { return H(h)->layer; }

static bowser_result_e send_msg(BWHost *h, uint16_t type, bw_buf *b) {
  bowser_result_e rc = bw_link_send(h->link, type, b);
  bw_buf_free(b);
  return rc;
}

static uint64_t stamp(uint64_t timestamp_ns) { return timestamp_ns ? timestamp_ns : bw_now_ns(); }

bowser_result_e bowser_host_resize(bowser_host_t *handle, bowser_size_s size) {
  BWHost *h = H(handle);
  h->size = size;
  place_content(h);
  bw_buf b = {0};
  bw_put_size(&b, size);
  return send_msg(h, BW_MSG_RESIZE, &b);
}

bowser_result_e bowser_host_focus(bowser_host_t *h, bool focused) {
  bw_buf b = {0};
  bw_put_u8(&b, focused);
  return send_msg(H(h), BW_MSG_FOCUS, &b);
}

bowser_result_e bowser_host_key(bowser_host_t *h, const bowser_key_s *k) {
  bw_buf b = {0};
  bw_put_u32(&b, k->action);
  bw_put_u32(&b, k->keycode);
  bw_put_u64(&b, k->mods);
  bw_put_str(&b, k->text);
  bw_put_str(&b, k->unmodified_text);
  bw_put_u64(&b, stamp(k->timestamp_ns));
  return send_msg(H(h), BW_MSG_KEY, &b);
}

bowser_result_e bowser_host_mouse(bowser_host_t *h, const bowser_mouse_s *m) {
  bw_buf b = {0};
  bw_put_u32(&b, m->action);
  bw_put_i32(&b, m->button);
  bw_put_f64(&b, m->x);
  bw_put_f64(&b, m->y);
  bw_put_i32(&b, m->click_count);
  bw_put_u64(&b, m->mods);
  bw_put_u64(&b, stamp(m->timestamp_ns));
  return send_msg(H(h), BW_MSG_MOUSE, &b);
}

bowser_result_e bowser_host_scroll(bowser_host_t *h, const bowser_scroll_s *s) {
  bw_buf b = {0};
  bw_put_f64(&b, s->dx);
  bw_put_f64(&b, s->dy);
  bw_put_u8(&b, s->precise);
  bw_put_i32(&b, s->phase);
  bw_put_i32(&b, s->momentum_phase);
  bw_put_f64(&b, s->x);
  bw_put_f64(&b, s->y);
  bw_put_u64(&b, s->mods);
  bw_put_u64(&b, stamp(s->timestamp_ns));
  return send_msg(H(h), BW_MSG_SCROLL, &b);
}

bowser_result_e bowser_host_text(bowser_host_t *h, const bowser_text_s *t) {
  bw_buf b = {0};
  bw_put_u32(&b, t->kind);
  bw_put_str(&b, t->text);
  bw_put_i64(&b, t->selected_location);
  bw_put_i64(&b, t->selected_length);
  bw_put_i64(&b, t->replacement_location);
  bw_put_i64(&b, t->replacement_length);
  return send_msg(H(h), BW_MSG_TEXT, &b);
}

bowser_result_e bowser_host_send(bowser_host_t *h, const char *name, const char *body) {
  bw_buf b = {0};
  bowser_result_e rc = bw_put_message(&b, name, body);
  if (rc) return rc;
  return send_msg(H(h), BW_MSG_MESSAGE, &b);
}
