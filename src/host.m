#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "frames.h"
#include "internal.h"
#import "remote_api.h"

@interface BWHost : NSObject {
 @public
  bowser_host_config_s cfg;
  bowser_transport_e transport;
  int fd;
  bw_buf rx;
  dispatch_queue_t io;
  dispatch_source_t source;
  NSLock *lock; // guards events, pendingFrame, closed
  NSMutableArray<NSData *> *events; // u16 type + payload
  bool closed;
  bool detachReported;
  bw_frame_client *frames;
  IOSurfaceRef pendingFrame; // newest unshown frame, IOSURFACE only
  IOSurfaceRef shownFrame;
  CALayer *layer;   // what the embedder mounts
  CALayer *content; // CALayerHost or the IOSurface layer
  bowser_size_s size;
}
@end

@implementation BWHost
- (void)dealloc {
  bw_buf_free(&rx);
  if (pendingFrame) CFRelease(pendingFrame);
  if (shownFrame) CFRelease(shownFrame);
}
@end

enum { EV_DISCONNECTED = 1000 };

static inline BWHost *H(bowser_host_t *h) { return (__bridge BWHost *)(void *)h; }

static void wake(BWHost *h) {
  if (h->cfg.wakeup_cb) h->cfg.wakeup_cb(h->cfg.userdata);
}

static void push_event(BWHost *h, uint16_t type, const bw_buf *payload) {
  NSMutableData *d = [NSMutableData dataWithBytes:&type length:2];
  if (payload && payload->len) [d appendBytes:payload->data length:payload->len];
  [h->events addObject:d];
}

static void host_readable(BWHost *h) {
  bool alive = bw_recv_some(h->fd, &h->rx);
  [h->lock lock];
  uint16_t type;
  bw_buf payload;
  bool bad = false, woke = false;
  while (!h->closed && bw_next_frame(&h->rx, &type, &payload, &bad)) {
    if (type >= BW_MSG_DETACH && type <= BW_MSG_CURSOR) {
      push_event(h, type, &payload);
      woke = true;
    }
    bw_buf_free(&payload);
  }
  if ((!alive || bad) && !h->closed) {
    push_event(h, EV_DISCONNECTED, NULL);
    h->fd = -1; // the cancel handler closes the socket
    dispatch_source_cancel(h->source);
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
  // Latest frame wins: an unshown older frame is dropped.
  if (h->pendingFrame) CFRelease(h->pendingFrame);
  h->pendingFrame = surface;
  bool closed = h->closed;
  [h->lock unlock];
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

bowser_result_e bowser_host_attach(const char *ticket, const bowser_host_config_s *cfg, bowser_host_t **out) {
  if (!cfg || !out || cfg->size < sizeof *cfg) return bw_fail(BOWSER_ERR_INVALID, "bad config");
  char path[104], token[BW_TOKEN_LEN + 1];
  if (!parse_ticket(ticket, path, sizeof path, token, sizeof token))
    return bw_fail(BOWSER_ERR_TICKET, "malformed ticket");

  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un addr = {.sun_family = AF_UNIX};
  strlcpy(addr.sun_path, path, sizeof addr.sun_path);
  if (fd < 0 || connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
    if (fd >= 0) close(fd);
    return bw_fail(BOWSER_ERR_TICKET, "producer at %s is gone", path);
  }
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
  struct timeval tv = {.tv_sec = 3};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);

  BWHost *h = [BWHost new];
  h->cfg = *cfg;
  h->fd = fd;
  h->lock = [NSLock new];
  h->events = [NSMutableArray new];

  bw_buf hello = {0}, payload = {0};
  bw_put_str(&hello, token);
  bool sent = bw_send(fd, BW_MSG_HELLO, &hello);
  bw_buf_free(&hello);
  uint16_t type = 0;
  if (!sent || !bw_recv_frame_blocking(fd, &h->rx, &type, &payload)) {
    close(fd);
    return bw_fail(BOWSER_ERR_DISCONNECTED, "no answer from the producer");
  }
  bw_rd r = bw_reader(&payload);
  if (type == BW_MSG_REJECT) {
    bowser_result_e why = (bowser_result_e)bw_get_u32(&r);
    bw_buf_free(&payload);
    close(fd);
    return bw_fail(why, "the producer rejected the ticket");
  }
  if (type != BW_MSG_WELCOME) {
    bw_buf_free(&payload);
    close(fd);
    return bw_fail(BOWSER_ERR_INVALID, "unexpected handshake message %u", type);
  }
  h->transport = (bowser_transport_e)bw_get_u32(&r);
  CAContextID contextId = bw_get_u32(&r);
  h->size = bw_get_size(&r);
  char *service = bw_get_str(&r);
  uint64_t nonce = bw_get_u64(&r);
  bool err = r.err;
  bw_buf_free(&payload);
  if (err) {
    free(service);
    close(fd);
    return bw_fail(BOWSER_ERR_INVALID, "malformed welcome");
  }

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  h->layer = [CALayer layer];
  h->layer.geometryFlipped = YES; // top-left origin, like the producer
  h->layer.masksToBounds = YES;
  if (h->transport == BOWSER_TRANSPORT_CALAYERHOST) {
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

  if (h->transport == BOWSER_TRANSPORT_IOSURFACE) {
    h->frames = bw_frame_client_new(service, nonce, on_frame, (__bridge void *)h);
    if (!h->frames) {
      free(service);
      close(fd);
      return bw_fail(BOWSER_ERR_TRANSPORT, "can't subscribe to frames");
    }
  }
  free(service);

  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
  h->io = dispatch_queue_create("dev.libbowser.host.io", DISPATCH_QUEUE_SERIAL);
  h->source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, h->io);
  __weak BWHost *weakHost = h;
  dispatch_source_set_event_handler(h->source, ^{
    BWHost *host = weakHost;
    if (host) host_readable(host);
  });
  dispatch_source_set_cancel_handler(h->source, ^{ close(fd); });
  dispatch_resume(h->source);

  *out = (__bridge_retained void *)h;
  return BOWSER_OK;
}

void bowser_host_detach(bowser_host_t *handle) {
  if (!handle) return;
  BWHost *h = (__bridge_transfer BWHost *)(void *)handle;
  [h->lock lock];
  h->closed = true;
  h->fd = -1;
  dispatch_source_cancel(h->source);
  [h->lock unlock];
  dispatch_sync(h->io, ^{}); // no io handler runs after this
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
  NSArray<NSData *> *batch = [h->events copy];
  [h->events removeAllObjects];
  IOSurfaceRef frame = h->pendingFrame;
  h->pendingFrame = NULL;
  [h->lock unlock];

  if (frame) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    h->content.contents = (__bridge id)frame;
    [CATransaction commit];
    if (h->shownFrame) CFRelease(h->shownFrame);
    h->shownFrame = frame;
    place_content(h);
  }

  void *ud = h->cfg.userdata;
  for (NSData *d in batch) {
    uint16_t type;
    memcpy(&type, d.bytes, 2);
    bw_buf payload = {.data = (uint8_t *)d.bytes + 2, .len = d.length - 2};
    bw_rd r = bw_reader(&payload);
    switch (type) {
    case BW_MSG_CARET: {
      bowser_rect_s caret = bw_get_rect(&r);
      if (!r.err && h->cfg.caret_cb) h->cfg.caret_cb(ud, handle, caret);
      break;
    }
    case BW_MSG_COMPOSITION: {
      bool active = bw_get_u8(&r);
      uint32_t count = bw_get_u32(&r);
      if (r.err || count > r.left / 32) break;
      bowser_rect_s *rects = calloc(count ? count : 1, sizeof *rects);
      for (uint32_t i = 0; i < count; i++) rects[i] = bw_get_rect(&r);
      if (!r.err && h->cfg.composition_cb) h->cfg.composition_cb(ud, handle, active, rects, count);
      free(rects);
      break;
    }
    case BW_MSG_CURSOR: {
      uint32_t cursor = bw_get_u32(&r);
      if (!r.err && h->cfg.cursor_cb) h->cfg.cursor_cb(ud, handle, (bowser_cursor_e)cursor);
      break;
    }
    case BW_MSG_DETACH:
    case EV_DISCONNECTED: {
      bowser_result_e why = type == BW_MSG_DETACH ? (bowser_result_e)bw_get_u32(&r) : BOWSER_ERR_DISCONNECTED;
      if (!h->detachReported && h->cfg.detached_cb) h->cfg.detached_cb(ud, handle, why);
      h->detachReported = true;
      break;
    }
    }
  }
}

bowser_transport_e bowser_host_transport(bowser_host_t *h) { return H(h)->transport; }
CALayer *bowser_host_layer(bowser_host_t *h) { return H(h)->layer; }

static void send_msg(BWHost *h, uint16_t type, bw_buf *b) {
  [h->lock lock];
  if (!h->closed) bw_send(h->fd, type, b);
  [h->lock unlock];
  bw_buf_free(b);
}

void bowser_host_resize(bowser_host_t *handle, bowser_size_s size) {
  BWHost *h = H(handle);
  h->size = size;
  place_content(h);
  bw_buf b = {0};
  bw_put_size(&b, size);
  send_msg(h, BW_MSG_RESIZE, &b);
}

void bowser_host_focus(bowser_host_t *h, bool focused) {
  bw_buf b = {0};
  bw_put_u8(&b, focused);
  send_msg(H(h), BW_MSG_FOCUS, &b);
}

void bowser_host_key(bowser_host_t *h, const bowser_key_s *k) {
  bw_buf b = {0};
  bw_put_u32(&b, k->action);
  bw_put_u32(&b, k->keycode);
  bw_put_u64(&b, k->mods);
  bw_put_str(&b, k->text);
  bw_put_str(&b, k->unmodified_text);
  send_msg(H(h), BW_MSG_KEY, &b);
}

void bowser_host_mouse(bowser_host_t *h, const bowser_mouse_s *m) {
  bw_buf b = {0};
  bw_put_u32(&b, m->action);
  bw_put_i32(&b, m->button);
  bw_put_f64(&b, m->x);
  bw_put_f64(&b, m->y);
  bw_put_i32(&b, m->click_count);
  bw_put_u64(&b, m->mods);
  send_msg(H(h), BW_MSG_MOUSE, &b);
}

void bowser_host_scroll(bowser_host_t *h, const bowser_scroll_s *s) {
  bw_buf b = {0};
  bw_put_f64(&b, s->dx);
  bw_put_f64(&b, s->dy);
  bw_put_u8(&b, s->precise);
  bw_put_i32(&b, s->phase);
  bw_put_i32(&b, s->momentum_phase);
  bw_put_f64(&b, s->x);
  bw_put_f64(&b, s->y);
  bw_put_u64(&b, s->mods);
  send_msg(H(h), BW_MSG_SCROLL, &b);
}

void bowser_host_text(bowser_host_t *h, const bowser_text_s *t) {
  bw_buf b = {0};
  bw_put_u32(&b, t->kind);
  bw_put_str(&b, t->text);
  bw_put_i64(&b, t->selected_location);
  bw_put_i64(&b, t->selected_length);
  bw_put_i64(&b, t->replacement_location);
  bw_put_i64(&b, t->replacement_length);
  send_msg(H(h), BW_MSG_TEXT, &b);
}
