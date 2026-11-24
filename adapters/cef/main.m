// bowser-cef: one CEF engine that serves many libbowser surfaces, one browser
// per surface. All of them share a profile, so logins persist, and share
// CEF's GPU, network, and storage processes.
//
// A tab runs in one of two modes:
//
// - Windowed (windowed.m), the default on CALAYERHOST: zero copy. Chromium
//   runs as in a window, one the user never sees, and the surface's layer
//   tree hosts Chromium's own GPU-process layers.
// - Off-screen rendering (OSR), on IOSURFACE, or with --mode osr: CEF's GPU
//   process draws each frame into an IOSurface from its own pool and lends it
//   to us for the length of on_accelerated_paint. We copy it into an
//   IOSurface we own (Metal blit), then show that copy with the surface's
//   transport: as layer contents in our CAContext on CALAYERHOST, or with
//   bowser_surface_present on IOSURFACE.
//
// Usage:
//   bowser-cef [--profile DIR] [--mode M]
//       Control mode: JSON lines on stdin and stdout (see README.md). Exits
//       when stdin closes.
//   bowser-cef [--profile DIR] [--mode M] [--transport T] [--url URL] [--tickets N]
//       One tab: prints N tickets (default 1), one per line, then runs until
//       SIGTERM or SIGINT. For tests, demos, and benchmarks.
//   M: windowed (default) or osr. It sets CALAYERHOST tabs' mode; IOSURFACE
//   tabs are always OSR.
//
// CEF paces frames with its own timer. Driving it from the display link
// (external_begin_frame_enabled) measured no better: frame-interval jitter
// 2-4 ms against 2 ms, so it isn't used.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>

#include "engine.h"
#include <mach/mach_time.h>

#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_command_line_capi.h"
#include "include/capi/cef_trace_capi.h"
#include "include/capi/cef_context_menu_handler_capi.h"
#include "include/capi/cef_dialog_handler_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_find_handler_capi.h"
#include "include/capi/cef_input_event_utils_capi.h"
#include "include/capi/cef_jsdialog_handler_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_render_handler_capi.h"
#include "include/cef_api_hash.h"
#include "include/cef_application_mac.h"

// Copies of CEF frames a tab keeps. The host shows one, the next is in
// flight, and the rest let us skip any the window server still reads.
enum { kViewPoolMax = 6, kPopupPoolMax = 3 };

// ---- CEF plumbing ---------------------------------------------------

// The handlers are static objects that live as long as the process, so their
// reference counts have nothing to track. Only the per-tab client counts.
static void CEF_CALLBACK static_add_ref(cef_base_ref_counted_t *self) {}
static int CEF_CALLBACK static_release(cef_base_ref_counted_t *self) { return 0; }
static int CEF_CALLBACK static_has_one_ref(cef_base_ref_counted_t *self) { return 0; }
static int CEF_CALLBACK static_has_ref(cef_base_ref_counted_t *self) { return 1; }
#define STATIC_BASE(type)                                                                                    \
  .base = {.size = sizeof(type), .add_ref = static_add_ref, .release = static_release,                      \
           .has_one_ref = static_has_one_ref, .has_at_least_one_ref = static_has_ref}

// CEF hands each struct argument and return value over with a reference the
// receiver must drop, and takes one with each struct we pass it.
static void unref(void *object) {
  cef_base_ref_counted_t *base = object;
  if (base) base->release(base);
}

// A cef_string_t copy of a UTF-8 string. Free it with cef_string_clear.
static cef_string_t cef_str(const char *utf8) {
  cef_string_t s = {0};
  cef_string_utf8_to_utf16(utf8, strlen(utf8), &s);
  return s;
}

static NSString *ns_str(const cef_string_t *s) {
  if (!s || !s->str) return @"";
  return [NSString stringWithCharacters:(const unichar *)s->str length:s->length];
}

// ---- State ----------------------------------------------------------

@interface Buffer : NSObject {
@public
  IOSurfaceRef surface;
  id<MTLTexture> texture;
  uint64_t shownAt; // frame number, for least-recently-shown reuse
}
@end
@implementation Buffer
- (void)dealloc { CFRelease(surface); }
@end

@implementation Tab
@end

static struct {
  bool control;      // JSON lines on stdin/stdout
  bool contextReady; // CEF can create browsers
  Tab *spare;        // a windowed tab with no page yet, made ahead (take_spare)
  bool quitting;
  bool osrOnly; // --mode osr: CALAYERHOST tabs render off screen too
  int ticking;  // inside bowser_producer_tick
  bowser_producer_t *producers[2]; // by transport, made on first use
  NSMutableDictionary<NSString *, Tab *> *tabs;
  NSMutableDictionary<NSValue *, Tab *> *bySurface;
  NSMutableArray<Tab *> *pending; // opened before the context was ready
  unsigned nextId;
  id<MTLDevice> device;
  id<MTLCommandQueue> queue;
  dispatch_source_t input;
  NSMutableData *line;
  NSMutableDictionary<NSNumber *, id> *menus; // open menus by id
  int nextMenu;
  NSString *tracePath; // trace_stop's destination while CEF writes it
} E;

bool engine_log_enabled(void) {
  static int on = -1;
  if (on < 0) on = getenv("BOWSER_LOG") != NULL;
  return on;
}

static Tab *tab_for_surface(bowser_surface_t *s) { return E.bySurface[[NSValue valueWithPointer:s]]; }

// ---- Control channel ------------------------------------------------

static void emit(NSDictionary *object) {
  if (!E.control) return;
  NSData *d = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingWithoutEscapingSlashes error:nil];
  fwrite(d.bytes, 1, d.length, stdout);
  fputc('\n', stdout);
  fflush(stdout);
}

static NSString *json_text(NSDictionary *object) {
  NSData *d = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingWithoutEscapingSlashes error:nil];
  return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

// A message to the tab's host, if one is attached, and to the controller.
static void publish(Tab *t, NSString *name, NSDictionary *body) {
  if (t->attached && t->surface) bowser_surface_send(t->surface, name.UTF8String, json_text(body).UTF8String);
  NSMutableDictionary *event = [body mutableCopy];
  event[@"event"] = name;
  event[@"surface"] = t->sid;
  emit(event);
}

static NSDictionary *state_of(Tab *t) {
  return @{
    @"url" : t->url ?: @"",
    @"title" : t->title ?: @"",
    @"loading" : @(t->loading),
    @"progress" : @(t->progress),
    @"can_go_back" : @(t->canGoBack),
    @"can_go_forward" : @(t->canGoForward),
  };
}

static void send_state(Tab *t) {
  t->stateSentAt = CACurrentMediaTime();
  publish(t, @"state", state_of(t));
}

// Loading changes the state many times a frame; send at most one per frame,
// the first at once and the newest at the end.
static void state_changed(Tab *t) {
  if (t->stateQueued) return;
  double frame = 1.0 / fmax(1, NSScreen.mainScreen.maximumFramesPerSecond);
  double wait = t->stateSentAt + frame - CACurrentMediaTime();
  if (wait <= 0) return send_state(t);
  t->stateQueued = true;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    t->stateQueued = false;
    if (t->surface) send_state(t);
  });
}

// ---- Frames ---------------------------------------------------------

static MTLPixelFormat metal_format(OSType format) {
  switch (format) {
  case 'BGRA': return MTLPixelFormatBGRA8Unorm;
  case 'RGBA': return MTLPixelFormatRGBA8Unorm;
  default: return MTLPixelFormatInvalid;
  }
}

static id<MTLTexture> texture_for(IOSurfaceRef s, MTLTextureUsage usage) {
  MTLPixelFormat format = metal_format(IOSurfaceGetPixelFormat(s));
  MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                               width:IOSurfaceGetWidth(s)
                                                                              height:IOSurfaceGetHeight(s)
                                                                           mipmapped:NO];
  d.usage = usage;
  return [E.device newTextureWithDescriptor:d iosurface:s plane:0];
}

// A buffer shaped like `like` that no one is reading: neither the window
// server nor the host. Least recently shown first, so a frame the host hasn't
// picked up yet isn't overwritten. `keep` is never returned.
static Buffer *take_buffer(NSMutableArray<Buffer *> *pool, int max, IOSurfaceRef like, Buffer *keep) {
  size_t w = IOSurfaceGetWidth(like), h = IOSurfaceGetHeight(like);
  OSType format = IOSurfaceGetPixelFormat(like);
  [pool filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(Buffer *b, NSDictionary *_) {
          return b == keep || (IOSurfaceGetWidth(b->surface) == w && IOSurfaceGetHeight(b->surface) == h &&
                               IOSurfaceGetPixelFormat(b->surface) == format);
        }]];
  Buffer *best = nil;
  for (Buffer *b in pool)
    if (b != keep && IOSurfaceGetWidth(b->surface) == w && IOSurfaceGetHeight(b->surface) == h &&
        !IOSurfaceIsInUse(b->surface) && (!best || b->shownAt < best->shownAt))
      best = b;
  if (best || (int)pool.count >= max) return best;

  Buffer *b = [Buffer new];
  b->surface = IOSurfaceCreate((__bridge CFDictionaryRef) @{
    (id)kIOSurfaceWidth : @(w),
    (id)kIOSurfaceHeight : @(h),
    (id)kIOSurfaceBytesPerElement : @4,
    (id)kIOSurfacePixelFormat : @(format),
  });
  CFTypeRef cs = IOSurfaceCopyValue(like, kIOSurfaceColorSpace);
  if (cs) {
    IOSurfaceSetValue(b->surface, kIOSurfaceColorSpace, cs);
    CFRelease(cs);
  }
  b->texture = texture_for(b->surface, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
  [pool addObject:b];
  return b;
}

// Copy all of src into dst with its top-left corner at (x, y) pixels, clipped.
static void blit(id<MTLBlitCommandEncoder> enc, id<MTLTexture> src, id<MTLTexture> dst, long x, long y) {
  long sx = x < 0 ? -x : 0, sy = y < 0 ? -y : 0;
  long dx = x < 0 ? 0 : x, dy = y < 0 ? 0 : y;
  long w = MIN((long)src.width - sx, (long)dst.width - dx), h = MIN((long)src.height - sy, (long)dst.height - dy);
  if (w <= 0 || h <= 0) return;
  [enc copyFromTexture:src
           sourceSlice:0
           sourceLevel:0
          sourceOrigin:MTLOriginMake(sx, sy, 0)
            sourceSize:MTLSizeMake(w, h, 1)
             toTexture:dst
      destinationSlice:0
      destinationLevel:0
     destinationOrigin:MTLOriginMake(dx, dy, 0)];
}

// Ask CEF for a fresh frame soon. Used when a frame couldn't reach the host:
// a page that has stopped changing would otherwise never send a newer one.
static void request_repaint(Tab *t) {
  if (t->repaintQueued) return;
  t->repaintQueued = true;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    t->repaintQueued = false;
    if (t->host && t->attached) t->host->invalidate(t->host, PET_VIEW);
  });
}

static void show(Tab *t, Buffer *b) {
  double scale = t->size.scale;
  if (t->transport == BOWSER_TRANSPORT_CALAYERHOST) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    t->content.contents = (__bridge id)b->surface;
    t->content.contentsScale = scale;
    // At the frame's own size, so a resize never stretches an old frame.
    t->content.frame =
        CGRectMake(0, 0, IOSurfaceGetWidth(b->surface) / scale, IOSurfaceGetHeight(b->surface) / scale);
    [CATransaction commit];
  } else if (t->attached) {
    bowser_size_s sz = t->size;
    if (bowser_surface_present(t->surface, b->surface, (bowser_rect_s){0, 0, sz.width, sz.height}) != BOWSER_OK)
      request_repaint(t);
  }
  b->shownAt = ++t->frameNo;
  t->last = b;
}

static void count_frame(Tab *t, IOSurfaceRef src, double copyMs, double gpuMs) {
  CFTimeInterval now = CACurrentMediaTime();
  double budgetMs = 1000.0 / NSScreen.mainScreen.maximumFramesPerSecond;
  if (t->lastPaint > 0 && now - t->lastPaint < 0.25) { // longer gaps are idle, not late
    double gap = (now - t->lastPaint) * 1000;
    if (gap > budgetMs * 1.5) t->late++;
    t->maxGapMs = fmax(t->maxGapMs, gap);
    t->jitter2 += (gap - budgetMs) * (gap - budgetMs);
  }
  t->lastPaint = now;
  t->frames++;
  t->copyMs += copyMs;
  t->copyMaxMs = fmax(t->copyMaxMs, copyMs);
  t->gpuMs += gpuMs;
  [t->sources addObject:@(IOSurfaceGetID(src))];
  if (t->resizeAt > 0 && IOSurfaceGetWidth(src) == (size_t)lround(t->size.width * t->size.scale) &&
      IOSurfaceGetHeight(src) == (size_t)lround(t->size.height * t->size.scale)) {
    t->resizeMaxMs = fmax(t->resizeMaxMs, (now - t->resizeAt) * 1000);
    t->resizeAt = 0;
  }
  if (t->windowStart == 0) t->windowStart = now;
  if (now - t->windowStart < 2) return;
  fprintf(stderr,
          "%s  %.1f fps  late %d  jitter %.1f ms  max gap %.1f ms  copy %.2f ms avg (gpu %.2f) %.2f max  "
          "resize->frame %.0f ms  %lu cef surfaces  [%s]\n",
          t->transport == BOWSER_TRANSPORT_CALAYERHOST ? "calayerhost" : "iosurface",
          t->frames / (now - t->windowStart), t->late, sqrt(t->jitter2 / t->frames), t->maxGapMs,
          t->copyMs / t->frames, t->gpuMs / t->frames, t->copyMaxMs, t->resizeMaxMs,
          (unsigned long)t->sources.count, t->sid.UTF8String);
  t->windowStart = now;
  t->frames = t->late = 0;
  t->maxGapMs = t->jitter2 = t->copyMs = t->copyMaxMs = t->gpuMs = t->resizeMaxMs = 0;
  [t->sources removeAllObjects];
}

// The popup's top-left corner in the view's pixels.
static void popup_origin(Tab *t, long *x, long *y) {
  *x = lround(t->popupRect.x * t->size.scale);
  *y = lround(t->popupRect.y * t->size.scale);
}

// IOSURFACE has one image per frame, so a popup is drawn into it. CALAYERHOST
// shows it as its own layer instead, and the window server composites.
static bool composites_popup(Tab *t) {
  return t->transport == BOWSER_TRANSPORT_IOSURFACE && t->popupShown && t->popup;
}

static void paint_view(Tab *t, IOSurfaceRef src) {
  CFTimeInterval start = CACurrentMediaTime();
  Buffer *b = take_buffer(t->pool, kViewPoolMax, src, nil);
  if (!b) {
    request_repaint(t); // every copy is still on screen; try again next frame
    return;
  }
  // CEF reclaims `src` when this callback returns, so the copy must be
  // finished, not just queued, before we return.
  id<MTLCommandBuffer> cb = [E.queue commandBuffer];
  id<MTLBlitCommandEncoder> enc = [cb blitCommandEncoder];
  blit(enc, texture_for(src, MTLTextureUsageShaderRead), b->texture, 0, 0);
  if (composites_popup(t)) {
    long x, y;
    popup_origin(t, &x, &y);
    blit(enc, t->popup->texture, b->texture, x, y);
  }
  [enc endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
  double copyMs = (CACurrentMediaTime() - start) * 1000;
  show(t, b);
  count_frame(t, src, copyMs, (cb.GPUEndTime - cb.GPUStartTime) * 1000);
}

static void place_popup_layer(Tab *t) {
  if (!t->popupLayer) return;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  bool visible = t->popupShown && t->popup;
  t->popupLayer.hidden = !visible;
  if (visible) {
    double scale = t->size.scale;
    t->popupLayer.contents = (__bridge id)t->popup->surface;
    t->popupLayer.contentsScale = scale;
    t->popupLayer.frame = CGRectMake(t->popupRect.x, t->popupRect.y, IOSurfaceGetWidth(t->popup->surface) / scale,
                                     IOSurfaceGetHeight(t->popup->surface) / scale);
  } else {
    t->popupLayer.contents = nil;
  }
  [CATransaction commit];
}

static void paint_popup(Tab *t, IOSurfaceRef src) {
  if (!t->popupShown) return;
  Buffer *p = take_buffer(t->popupPool, kPopupPoolMax, src, nil);
  if (!p) return;
  id<MTLCommandBuffer> cb = [E.queue commandBuffer];
  id<MTLBlitCommandEncoder> enc = [cb blitCommandEncoder];
  blit(enc, texture_for(src, MTLTextureUsageShaderRead), p->texture, 0, 0);
  // IOSURFACE: the popup changed but the view may not have, so redraw the
  // newest frame with the new popup over it. The popup covers its old self:
  // it only moves or shrinks through on_popup_size, which repaints the view.
  Buffer *frame = nil;
  if (t->transport == BOWSER_TRANSPORT_IOSURFACE && t->last) {
    frame = take_buffer(t->pool, kViewPoolMax, t->last->surface, t->last);
    if (frame) {
      long x, y;
      popup_origin(t, &x, &y);
      blit(enc, t->last->texture, frame->texture, 0, 0);
      blit(enc, p->texture, frame->texture, x, y);
    }
  }
  [enc endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
  p->shownAt = ++t->frameNo;
  t->popup = p;
  if (frame) show(t, frame);
  place_popup_layer(t);
}

static Tab *tab_of(cef_browser_t *browser);

static void CEF_CALLBACK on_accelerated_paint(cef_render_handler_t *self, cef_browser_t *browser,
                                              cef_paint_element_type_t type, size_t dirtyCount,
                                              const cef_rect_t *dirty, const cef_accelerated_paint_info_t *info) {
  Tab *t = tab_of(browser);
  unref(browser);
  IOSurfaceRef src = info->shared_texture_io_surface;
  if (!t || !t->surface || !src) return;
  if (metal_format(IOSurfaceGetPixelFormat(src)) == MTLPixelFormatInvalid) {
    fprintf(stderr, "bowser-cef: unsupported pixel format %#x\n", (unsigned)IOSurfaceGetPixelFormat(src));
    return;
  }
  if (type == PET_VIEW) paint_view(t, src);
  else paint_popup(t, src);
}

static void CEF_CALLBACK on_popup_show(cef_render_handler_t *self, cef_browser_t *browser, int shown) {
  Tab *t = tab_of(browser);
  unref(browser);
  if (!t) return;
  t->popupShown = shown;
  if (!shown) {
    t->popup = nil;
    [t->popupPool removeAllObjects];
    place_popup_layer(t);
    // The view under the popup didn't change, so CEF won't repaint it.
    if (t->host && t->transport == BOWSER_TRANSPORT_IOSURFACE) t->host->invalidate(t->host, PET_VIEW);
  }
}

static void CEF_CALLBACK on_popup_size(cef_render_handler_t *self, cef_browser_t *browser, const cef_rect_t *rect) {
  Tab *t = tab_of(browser);
  unref(browser);
  if (!t) return;
  // Keep the popup inside the view, as Chromium's own views do: a <select>
  // near the bottom opens upward instead of off the surface.
  cef_rect_t r = *rect;
  int w = (int)lround(t->size.width), h = (int)lround(t->size.height);
  if (r.x + r.width > w) r.x = w - r.width;
  if (r.y + r.height > h) r.y = h - r.height;
  r.x = MAX(r.x, 0);
  r.y = MAX(r.y, 0);
  t->popupRect = r;
  place_popup_layer(t);
  if (t->host && t->transport == BOWSER_TRANSPORT_IOSURFACE) t->host->invalidate(t->host, PET_VIEW);
}

// ---- Geometry -------------------------------------------------------

static void CEF_CALLBACK get_view_rect(cef_render_handler_t *self, cef_browser_t *browser, cef_rect_t *rect) {
  Tab *t = tab_of(browser);
  unref(browser);
  bowser_size_s s = t ? t->size : (bowser_size_s){800, 500, 2};
  *rect = (cef_rect_t){0, 0, (int)fmax(1, lround(s.width)), (int)fmax(1, lround(s.height))};
}

static int CEF_CALLBACK get_screen_info(cef_render_handler_t *self, cef_browser_t *browser, cef_screen_info_t *info) {
  Tab *t = tab_of(browser);
  unref(browser);
  info->device_scale_factor = t ? (float)t->size.scale : 2;
  info->depth = 24;
  info->depth_per_component = 8;
  return 1;
}

static void on_resize(void *ud, bowser_surface_t *s, bowser_size_s size) {
  Tab *t = tab_for_surface(s);
  if (!t) return;
  bool rescaled = size.scale != t->size.scale;
  t->size = size;
  if (t->windowed) return windowed_resize(t);
  if (!t->host) return;
  if (t->last) t->resizeAt = CACurrentMediaTime(); // the first frame is a page load, not a resize
  if (rescaled) t->host->notify_screen_info_changed(t->host);
  t->host->was_resized(t->host);
}

// ---- Text input state -----------------------------------------------

static bowser_rect_s view_rect(cef_rect_t r) { return (bowser_rect_s){r.x, r.y, r.width, r.height}; }

static void CEF_CALLBACK on_ime_composition_range_changed(cef_render_handler_t *self, cef_browser_t *browser,
                                                          const cef_range_t *range, size_t count,
                                                          const cef_rect_t *bounds) {
  Tab *t = tab_of(browser);
  unref(browser);
  if (!t || !t->surface || count == 0) return;
  cef_rect_t end = bounds[count - 1];
  bowser_surface_set_caret(t->surface, (bowser_rect_s){end.x + end.width, end.y, 2, end.height});
  if (!t->composing) return;
  bowser_rect_s rects[count];
  for (size_t i = 0; i < count; i++) rects[i] = view_rect(bounds[i]);
  bowser_surface_set_composition(t->surface, true, rects, count);
}

static int CEF_CALLBACK on_cursor_change(cef_display_handler_t *self, cef_browser_t *browser, cef_cursor_handle_t h,
                                         cef_cursor_type_t type, const cef_cursor_info_t *custom) {
  Tab *t = tab_of(browser);
  unref(browser);
  if (!t || !t->surface) return 1;
  bowser_cursor_e c;
  switch (type) {
  case CT_IBEAM:
  case CT_VERTICALTEXT: c = BOWSER_CURSOR_IBEAM; break;
  case CT_HAND: c = BOWSER_CURSOR_POINTER; break;
  case CT_CROSS:
  case CT_CELL: c = BOWSER_CURSOR_CROSSHAIR; break;
  case CT_NOTALLOWED:
  case CT_NODROP: c = BOWSER_CURSOR_NOT_ALLOWED; break;
  case CT_EASTRESIZE:
  case CT_WESTRESIZE:
  case CT_EASTWESTRESIZE:
  case CT_COLUMNRESIZE: c = BOWSER_CURSOR_RESIZE_LEFT_RIGHT; break;
  case CT_NORTHRESIZE:
  case CT_SOUTHRESIZE:
  case CT_NORTHSOUTHRESIZE:
  case CT_ROWRESIZE: c = BOWSER_CURSOR_RESIZE_UP_DOWN; break;
  default: c = BOWSER_CURSOR_ARROW; break;
  }
  if (c != t->cursor) {
    t->cursor = c;
    bowser_surface_set_cursor(t->surface, c);
  }
  return 1;
}

// Chromium would show a tooltip window from this process. Suppress it until
// the vocabulary can hand tooltips to the host.
static int CEF_CALLBACK on_tooltip(cef_display_handler_t *self, cef_browser_t *browser, cef_string_t *text) {
  unref(browser);
  return 1;
}

// BOWSER_LOG=1 also prints the pages' consoles.
static int CEF_CALLBACK on_console_message(cef_display_handler_t *self, cef_browser_t *browser,
                                           cef_log_severity_t level, const cef_string_t *message,
                                           const cef_string_t *source, int line) {
  Tab *t = tab_of(browser);
  unref(browser);
  ENGINE_LOG("%s: console: %s\n", t ? t->sid.UTF8String : "?", ns_str(message).UTF8String);
  return 1;
}

// ---- Navigation state -----------------------------------------------

static void CEF_CALLBACK on_address_change(cef_display_handler_t *self, cef_browser_t *browser, cef_frame_t *frame,
                                           const cef_string_t *url) {
  Tab *t = tab_of(browser);
  if (t && frame->is_main(frame)) {
    t->url = ns_str(url);
    state_changed(t);
  }
  unref(frame);
  unref(browser);
}

static void CEF_CALLBACK on_title_change(cef_display_handler_t *self, cef_browser_t *browser,
                                         const cef_string_t *title) {
  Tab *t = tab_of(browser);
  unref(browser);
  if (!t) return;
  t->title = ns_str(title);
  ENGINE_LOG("%s: title %s\n", t->sid.UTF8String, t->title.UTF8String);
  state_changed(t);
}

static void CEF_CALLBACK on_loading_progress_change(cef_display_handler_t *self, cef_browser_t *browser,
                                                    double progress) {
  Tab *t = tab_of(browser);
  unref(browser);
  if (!t) return;
  t->progress = progress;
  state_changed(t);
}

static void CEF_CALLBACK on_loading_state_change(cef_load_handler_t *self, cef_browser_t *browser, int loading,
                                                 int canGoBack, int canGoForward) {
  Tab *t = tab_of(browser);
  unref(browser);
  if (!t) return;
  t->loading = loading;
  t->canGoBack = canGoBack;
  t->canGoForward = canGoForward;
  state_changed(t);
}

// An error page keeps the old address, but the user should see the one that failed.
static void CEF_CALLBACK on_load_error(cef_load_handler_t *self, cef_browser_t *browser, cef_frame_t *frame,
                                       cef_errorcode_t code, const cef_string_t *text, const cef_string_t *failed) {
  Tab *t = tab_of(browser);
  if (t && frame->is_main(frame) && code != ERR_ABORTED) { // ABORTED: stopped, or replaced by a newer load
    t->url = ns_str(failed);
    state_changed(t);
  }
  unref(frame);
  unref(browser);
}

static void CEF_CALLBACK on_find_result(cef_find_handler_t *self, cef_browser_t *browser, int identifier, int count,
                                        const cef_rect_t *selection, int active, int final) {
  Tab *t = tab_of(browser);
  unref(browser);
  // Earlier updates count matches still being found, with none active yet.
  if (!t || !final || (count == t->findCount && active == t->findActive)) return;
  t->findCount = count;
  t->findActive = active;
  publish(t, @"find_result", @{@"count" : @(count), @"active" : @(active)});
}

// ---- Menus ----------------------------------------------------------
//
// The host shows every menu, as a real NSMenu in its own process: the
// producer has no window of its own on screen to put one over. See `menu` and
// `menu_result` in README.md.

@interface Menu : NSObject {
@public
  Tab *tab;
  void (^done)(int index);
  CFTimeInterval deadline;
}
@end
@implementation Menu
@end

static const double kMenuTimeout = 30; // s: then the producer stops waiting for the host

NSDictionary *menu_item(NSString *label, bool enabled, bool checked, bool separator, NSArray *children) {
  NSMutableDictionary *item = [@{
    @"label" : label ?: @"",
    @"enabled" : @(enabled),
    @"checked" : @(checked),
    @"separator" : @(separator),
  } mutableCopy];
  if (children) item[@"children"] = children;
  return item;
}

static void finish_menu(int mid, int index) {
  Menu *m = E.menus[@(mid)];
  if (!m) return;
  [E.menus removeObjectForKey:@(mid)];
  m->done(index);
}

static bool menu_answer(Tab *t, int mid, int index) {
  Menu *m = E.menus[@(mid)];
  if (!m || m->tab != t) return false;
  finish_menu(mid, index < 0 ? -1 : index);
  return true;
}

static void dismiss_menus(Tab *t) {
  for (NSNumber *mid in E.menus.allKeys)
    if (((Menu *)E.menus[mid])->tab == t) finish_menu(mid.intValue, -1);
}

// Returns the menu's id, or 0 if it was dismissed at once.
static int open_menu(Tab *t, NSString *kind, CGPoint at, int selected, NSArray *items, void (^done)(int index)) {
  int mid = ++E.nextMenu;
  NSDictionary *body = @{
    @"id" : @(mid),
    @"kind" : kind,
    @"x" : @(at.x),
    @"y" : @(at.y),
    @"selected" : @(selected),
    @"items" : items,
  };
  // Not kept for a later host: by then the page has moved on.
  if (!t->surface || !t->attached || bowser_surface_send(t->surface, "menu", json_text(body).UTF8String) != BOWSER_OK) {
    ENGINE_LOG("%s: menu %d dismissed: %s\n", t->sid.UTF8String, mid, t->attached ? bowser_last_error() : "no host");
    done(-1);
    return 0;
  }
  Menu *m = [Menu new];
  m->tab = t;
  m->done = done;
  m->deadline = CACurrentMediaTime() + kMenuTimeout;
  E.menus[@(mid)] = m;
  return mid;
}

void menu_show(Tab *t, NSString *kind, CGPoint at, int selected, NSArray *items, void (^done)(int index)) {
  int mid = open_menu(t, kind, at, selected, items, done);
  if (mid)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kMenuTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(),
                   ^{ finish_menu(mid, -1); });
}

int menu_show_sync(Tab *t, NSString *kind, CGPoint at, int selected, NSArray *items) {
  // The answer comes in a tick, and ticks don't nest.
  if (E.ticking) {
    ENGINE_LOG("%s: a menu opened inside a tick is dismissed\n", t->sid.UTF8String);
    return -1;
  }
  __block int result = -2;
  int mid = open_menu(t, kind, at, selected, items, ^(int index) { result = index; });
  // As a real menu does: Chromium, our ticks, and the control channel run on.
  while (result == -2) {
    if (CACurrentMediaTime() > ((Menu *)E.menus[@(mid)])->deadline) finish_menu(mid, -1);
    else CFRunLoopRunInMode((__bridge CFStringRef)NSEventTrackingRunLoopMode, 0.1, true);
  }
  return result;
}

// ---- Messages: the browser vocabulary (README.md) -------------------

// What `navigate` loads for what the user typed. A URL with a scheme loads as
// is. Something shaped like a host gets https://, or http:// for localhost
// and IP addresses, which rarely have certificates. Anything else searches
// DuckDuckGo.
static NSString *fixup_url(NSString *typed) {
  NSString *s = [typed stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (s.length == 0) return nil;
  NSRange scheme = [s rangeOfString:@"^[A-Za-z][A-Za-z0-9+.-]*:" options:NSRegularExpressionSearch];
  if (scheme.location != NSNotFound) {
    NSString *name = [s substringToIndex:scheme.length - 1].lowercaseString;
    // Without "//", "localhost:3000" also looks like a scheme; only these
    // schemes take no authority.
    if ([s rangeOfString:@"://"].location == scheme.length - 1 ||
        [@[ @"about", @"data", @"mailto", @"view-source" ] containsObject:name])
      return s;
  }
  if ([s rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location == NSNotFound) {
    NSString *hostPort = [s componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/?#"]][0];
    NSString *host = [hostPort stringByReplacingOccurrencesOfString:@":[0-9]+$"
                                                         withString:@""
                                                            options:NSRegularExpressionSearch
                                                              range:NSMakeRange(0, hostPort.length)];
    bool local = [host isEqualToString:@"localhost"] ||
                 [host rangeOfString:@"^([0-9]{1,3}\\.){3}[0-9]{1,3}$|^\\[[0-9A-Fa-f:]+\\]$"
                             options:NSRegularExpressionSearch]
                         .location != NSNotFound;
    if (local) return [@"http://" stringByAppendingString:s];
    if ([host rangeOfString:@"^([A-Za-z0-9-]+\\.)+[A-Za-z]{2,}$" options:NSRegularExpressionSearch].location !=
        NSNotFound)
      return [@"https://" stringByAppendingString:s];
  }
  NSMutableCharacterSet *allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
  [allowed removeCharactersInString:@"&+=#"];
  return [@"https://duckduckgo.com/?q=" stringByAppendingString:[s stringByAddingPercentEncodingWithAllowedCharacters:allowed]];
}

static void load(Tab *t, NSString *url) {
  cef_frame_t *main = t->browser->get_main_frame(t->browser);
  cef_string_t u = cef_str(url.UTF8String);
  main->load_url(main, &u);
  cef_string_clear(&u);
  unref(main);
}

static bool flag(NSDictionary *body, NSString *key, bool fallback) {
  id v = body[key];
  return [v isKindOfClass:NSNumber.class] ? [v boolValue] : fallback;
}

// Act on one message. Returns an error, or nil.
static NSString *handle_message(Tab *t, NSString *name, NSDictionary *body) {
  if (!t->browser && [name isEqualToString:@"navigate"]) {
    // CEF is still making the browser: it loads this instead, once made.
    id typed = body[@"url"];
    NSString *url = [typed isKindOfClass:NSString.class] ? fixup_url(typed) : nil;
    if (!url) return @"navigate needs a url";
    t->url = t->startURL = url;
    if (t->started) t->loadOnCreate = true;
    return nil;
  }
  if (!t->browser) return @"the page is still starting";
  cef_browser_t *b = t->browser;
  if ([name isEqualToString:@"navigate"]) {
    id typed = body[@"url"];
    NSString *url = [typed isKindOfClass:NSString.class] ? fixup_url(typed) : nil;
    if (!url) return @"navigate needs a url";
    load(t, url);
  } else if ([name isEqualToString:@"back"]) {
    b->go_back(b);
  } else if ([name isEqualToString:@"forward"]) {
    b->go_forward(b);
  } else if ([name isEqualToString:@"reload"]) {
    b->reload(b);
  } else if ([name isEqualToString:@"stop"]) {
    b->stop_load(b);
  } else if ([name isEqualToString:@"edit"]) {
    NSArray *commands = @[ @"copy", @"cut", @"paste", @"select_all", @"undo", @"redo", @"delete" ];
    NSUInteger i = [commands indexOfObject:body[@"command"] ?: @""];
    if (i == NSNotFound) return @"edit needs a command: copy, cut, paste, select_all, undo, redo, or delete";
    // Edit commands act where the user is: the focused frame, such as an iframe.
    cef_frame_t *f = b->get_focused_frame(b);
    if (!f) f = b->get_main_frame(b);
    void(CEF_CALLBACK * run[])(cef_frame_t *) = {f->copy, f->cut, f->paste, f->select_all, f->undo, f->redo, f->del};
    run[i](f);
    unref(f);
  } else if ([name isEqualToString:@"find"]) {
    id text = body[@"text"];
    if (![text isKindOfClass:NSString.class] || [text length] == 0) return @"find needs text";
    // CEF's findNext is Chromium's find_match: false only highlights, with no
    // active match. A new text starts a new search either way, so a fresh
    // search of the same text has to stop the old one first.
    bool next = flag(body, @"next", false);
    if (!next && [text isEqualToString:t->findText]) t->host->stop_finding(t->host, 0);
    t->findText = text;
    cef_string_t s = cef_str([text UTF8String]);
    t->host->find(t->host, &s, flag(body, @"forward", true), 0, 1);
    cef_string_clear(&s);
  } else if ([name isEqualToString:@"find_stop"]) {
    t->host->stop_finding(t->host, 0); // the active match stays selected, as in Safari and Chrome
    t->findText = nil;
    t->findCount = t->findActive = 0;
  } else if ([name isEqualToString:@"zoom"]) {
    id delta = body[@"delta"];
    if (![delta isKindOfClass:NSNumber.class]) return @"zoom needs a delta: 1, -1, or 0";
    int d = [delta intValue];
    // Chromium's own steps (90%, 110%, ...), remembered per site in the profile.
    t->host->zoom(t->host, d > 0 ? CEF_ZOOM_COMMAND_IN : d < 0 ? CEF_ZOOM_COMMAND_OUT : CEF_ZOOM_COMMAND_RESET);
  } else if ([name isEqualToString:@"menu_result"]) {
    id mid = body[@"id"], index = body[@"index"];
    if (![mid isKindOfClass:NSNumber.class] || ![index isKindOfClass:NSNumber.class])
      return @"menu_result needs an id and an index";
    if (!menu_answer(t, [mid intValue], [index intValue])) return [NSString stringWithFormat:@"no open menu %@", mid];
  } else {
    return [NSString stringWithFormat:@"unknown message %@", name];
  }
  return nil;
}

static void on_message(void *ud, bowser_surface_t *s, const char *name, const char *body) {
  Tab *t = tab_for_surface(s);
  if (!t) return;
  NSDictionary *args = @{};
  if (body) {
    id parsed = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:body length:strlen(body)] options:0
                                                  error:nil];
    if ([parsed isKindOfClass:NSDictionary.class]) args = parsed;
  }
  NSString *error = handle_message(t, @(name), args);
  // A host gets no answers; a bad message is the host's bug, so say so here.
  if (error) fprintf(stderr, "bowser-cef: %s: %s\n", t->sid.UTF8String, error.UTF8String);
}

// ---- Input from the host --------------------------------------------

static uint32_t cef_modifiers(uint64_t mods) {
  uint32_t f = 0;
  if (mods & NSEventModifierFlagCapsLock) f |= CEF_EVENTFLAG_CAPS_LOCK_ON;
  if (mods & NSEventModifierFlagShift) f |= CEF_EVENTFLAG_SHIFT_DOWN;
  if (mods & NSEventModifierFlagControl) f |= CEF_EVENTFLAG_CONTROL_DOWN;
  if (mods & NSEventModifierFlagOption) f |= CEF_EVENTFLAG_ALT_DOWN;
  if (mods & NSEventModifierFlagCommand) f |= CEF_EVENTFLAG_COMMAND_DOWN;
  return f;
}

static void on_mouse(void *ud, bowser_surface_t *s, const bowser_mouse_s *m) {
  Tab *t = tab_for_surface(s);
  if (t && t->windowed) return windowed_mouse(t, m);
  if (!t || !t->host) return;
  // bowser numbers buttons left, right, middle.
  static const cef_mouse_button_type_t buttons[] = {CEF_MOUSE_BUTTON_LEFT, CEF_MOUSE_BUTTON_RIGHT,
                                                    CEF_MOUSE_BUTTON_MIDDLE};
  static const uint32_t held[] = {CEF_EVENTFLAG_LEFT_MOUSE_BUTTON, CEF_EVENTFLAG_RIGHT_MOUSE_BUTTON,
                                  CEF_EVENTFLAG_MIDDLE_MOUSE_BUTTON};
  int b = m->button >= 0 && m->button < 3 ? m->button : 0;
  cef_mouse_input_event_t e = {
      .size = sizeof e,
      .x = (float)m->x,
      .y = (float)m->y,
      // The host's screen position isn't in the ABI; view coordinates stand in.
      .screen_x = (float)m->x,
      .screen_y = (float)m->y,
      .button = CEF_MOUSE_BUTTON_NONE,
      .pointer_type = CEF_POINTER_TYPE_MOUSE,
      .pointer_id = INT32_MAX,
      .pressure = NAN,
      .device_id = -1,
  };
  switch (m->action) {
  case BOWSER_MOUSE_DOWN:
    t->heldButtons |= held[b];
    e.type = CEF_MOUSE_EVENT_DOWN;
    e.button = buttons[b];
    e.click_count = m->click_count;
    break;
  case BOWSER_MOUSE_UP:
    t->heldButtons &= ~held[b];
    e.type = CEF_MOUSE_EVENT_UP;
    e.button = buttons[b];
    e.click_count = m->click_count;
    break;
  case BOWSER_MOUSE_MOVE:
  case BOWSER_MOUSE_DRAG:
    e.type = CEF_MOUSE_EVENT_MOVE;
    for (int i = 0; i < 3; i++)
      if (t->heldButtons & held[i]) e.button = buttons[i];
    break;
  case BOWSER_MOUSE_EXIT: e.type = CEF_MOUSE_EVENT_LEAVE; break;
  }
  e.modifiers = cef_modifiers(m->mods) | t->heldButtons;
  t->host->send_mouse_event(t->host, &e);
}

static void on_scroll(void *ud, bowser_surface_t *s, const bowser_scroll_s *sc) {
  Tab *t = tab_for_surface(s);
  if (t && t->windowed) return windowed_scroll(t, sc);
  if (!t || !t->host) return;
  // AppKit's line deltas become pixels the way Chromium's own Mac event
  // builder does it: 40 px per line.
  const float kPixelsPerLine = 40;
  float scale = sc->precise ? 1 : kPixelsPerLine;
  // NSEventPhase and cef_wheel_event_phase_t share bit values.
  const int kPhases = CEF_WHEEL_PHASE_BEGAN | CEF_WHEEL_PHASE_STATIONARY | CEF_WHEEL_PHASE_CHANGED |
                      CEF_WHEEL_PHASE_ENDED | CEF_WHEEL_PHASE_CANCELLED | CEF_WHEEL_PHASE_MAY_BEGIN;
  cef_wheel_input_event_t w = {
      .size = sizeof w,
      .modifiers = cef_modifiers(sc->mods) | t->heldButtons,
      .x = (float)sc->x,
      .y = (float)sc->y,
      .screen_x = (float)sc->x,
      .screen_y = (float)sc->y,
      .delta_x = (float)sc->dx * scale,
      .delta_y = (float)sc->dy * scale,
      .wheel_ticks_x = (float)sc->dx * scale / kPixelsPerLine,
      .wheel_ticks_y = (float)sc->dy * scale / kPixelsPerLine,
      .delta_units = sc->precise ? CEF_GESTURE_SCROLL_PRECISE_PIXEL : CEF_GESTURE_SCROLL_PIXEL,
      .phase = sc->phase & kPhases,
      .momentum_phase = sc->momentum_phase & kPhases,
  };
  t->host->send_wheel_event(t->host, &w);
}

static void send_char(Tab *t, cef_keyboard_input_event_t e, char16_t c) {
  e.type = CEF_KEY_EVENT_CHAR;
  memset(e.text, 0, sizeof e.text);
  e.text[0] = c;
  t->host->send_keyboard_event(t->host, &e);
}

// Text arrives in two parts, like AppKit's: key events here, and the text they
// insert through on_text (NSTextInputClient). Chromium wants a RAWKEYDOWN per
// press and a CHAR per inserted character, so a press waits in pendingKey for
// its text. Keys that AppKit turns into commands instead of text (Return, Tab,
// Escape, Control and Command chords) get their CHAR right away, as Chromium's
// own Mac view does.
static void on_key(void *ud, bowser_surface_t *s, const bowser_key_s *k) {
  Tab *t = tab_for_surface(s);
  if (t && t->windowed) return windowed_key(t, k);
  if (!t || !t->host) return;
  NSEvent *ns = [NSEvent keyEventWithType:k->action == BOWSER_KEY_RELEASE ? NSEventTypeKeyUp : NSEventTypeKeyDown
                                 location:NSZeroPoint
                            modifierFlags:(NSEventModifierFlags)k->mods
                                timestamp:NSProcessInfo.processInfo.systemUptime
                             windowNumber:0
                                  context:nil
                               characters:@(k->text ? k->text : "")
              charactersIgnoringModifiers:@(k->unmodified_text ? k->unmodified_text : "")
                                isARepeat:k->action == BOWSER_KEY_REPEAT
                                  keyCode:k->keycode];
  cef_keyboard_input_event_t e = {.size = sizeof e};
  if (!ns || !cef_keyboard_input_event_from_mac_event((__bridge void *)ns, &e)) return;
  t->host->send_keyboard_event(t->host, &e);
  if (k->action == BOWSER_KEY_RELEASE) {
    t->pendingKey.size = 0;
    return;
  }
  bool chord = k->mods & (NSEventModifierFlagControl | NSEventModifierFlagCommand);
  if (!t->composing && e.text[0] && (e.text[0] < 0x20 || chord)) {
    send_char(t, e, e.text[0]);
    t->pendingKey.size = 0;
  } else {
    t->pendingKey = e;
  }
}

static cef_range_t cef_range(int64_t location, int64_t length) {
  if (location < 0) return (cef_range_t){UINT32_MAX, UINT32_MAX}; // NSNotFound: no range
  return (cef_range_t){(uint32_t)location, (uint32_t)(location + length)};
}

static void end_composition(Tab *t) {
  if (!t->composing) return;
  t->composing = false;
  bowser_surface_set_composition(t->surface, false, NULL, 0);
}

static void on_text(void *ud, bowser_surface_t *s, const bowser_text_s *in) {
  Tab *t = tab_for_surface(s);
  if (t && t->windowed) return windowed_text(t, in);
  if (!t || !t->host) return;
  NSString *text = @(in->text ? in->text : "");
  cef_string_t str = cef_str(text.UTF8String);
  cef_range_t replacement = cef_range(in->replacement_location, in->replacement_length);
  switch (in->kind) {
  case BOWSER_TEXT_INSERT:
    // One character typed with a key goes in as that key's CHAR, so pages see
    // keypress. Anything else (IME commits, emoji, dictation) is a commit.
    if (!t->composing && t->pendingKey.size && text.length == 1) {
      send_char(t, t->pendingKey, [text characterAtIndex:0]);
    } else {
      t->host->ime_commit_text(t->host, &str, &replacement, 0);
    }
    t->pendingKey.size = 0;
    end_composition(t);
    break;
  case BOWSER_TEXT_SET_MARKED:
    if (text.length == 0) {
      t->host->ime_cancel_composition(t->host);
      end_composition(t);
      break;
    }
    cef_composition_underline_t underline = {
        .size = sizeof underline,
        .range = {0, (uint32_t)text.length},
        .color = 0xFF000000,
        .style = CEF_CUS_SOLID,
    };
    cef_range_t selection = in->selected_location < 0 ? cef_range((int64_t)text.length, 0)
                                                      : cef_range(in->selected_location, in->selected_length);
    t->composing = true;
    t->pendingKey.size = 0;
    t->host->ime_set_composition(t->host, &str, 1, &underline, &replacement, &selection);
    break;
  case BOWSER_TEXT_UNMARK:
    t->host->ime_finish_composing_text(t->host, 0);
    end_composition(t);
    break;
  }
  cef_string_clear(&str);
}

static void on_focus(void *ud, bowser_surface_t *s, bool focused) {
  Tab *t = tab_for_surface(s);
  if (!t) return;
  t->focused = focused;
  if (t->windowed) return windowed_focus(t, focused);
  if (t->host) t->host->set_focus(t->host, focused);
}

static void on_display(void *ud, bowser_surface_t *s, uint32_t display) {
  Tab *t = tab_for_surface(s);
  // OSR paces with CEF's timer, not a display.
  if (t && t->windowed) windowed_display(t, display);
}

static void dismiss_menus(Tab *t);

static void on_attach(void *ud, bowser_surface_t *s, bool attached) {
  Tab *t = tab_for_surface(s);
  if (!t) return;
  t->attached = attached;
  ENGINE_LOG("%s: attached %d\n", t->sid.UTF8String, attached);
  if (!attached) t->focused = false;
  // A host that left can't answer; one that took over never saw the menu.
  dismiss_menus(t);
  emit(@{@"event" : @"attached", @"surface" : t->sid, @"attached" : @(attached)});
  if (t->windowed) {
    windowed_attach(t, attached);
    if (attached) bowser_surface_send(t->surface, "state", json_text(state_of(t)).UTF8String);
    return;
  }
  if (!attached) {
    // Keep only the frame a new host will be shown first.
    [t->pool filterUsingPredicate:[NSPredicate predicateWithFormat:@"self == %@", t->last]];
  }
  if (!t->host) return;
  // A tab no one shows is hidden: Chromium stops painting and throttles it.
  t->host->was_hidden(t->host, !attached);
  if (!attached) return;
  // A page that isn't changing paints nothing new, so give a new host the
  // frame we already have, and the state, which it can't have yet.
  if (t->last) show(t, t->last);
  bowser_surface_send(t->surface, "state", json_text(state_of(t)).UTF8String);
}

static void tick(bowser_transport_e transport) {
  if (!E.producers[transport]) return;
  if (E.ticking) { // ticks don't nest: once this one is done
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{ tick(transport); });
    return;
  }
  E.ticking++;
  bowser_producer_tick(E.producers[transport]);
  E.ticking--;
}

// A run loop block, not the main queue: a synchronous menu waits for its
// answer in a nested run loop, which runs no main-queue work when it was
// entered from some.
static void on_wakeup(void *ud) {
  bowser_transport_e transport = (bowser_transport_e)(intptr_t)ud;
  CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{ tick(transport); });
  CFRunLoopWakeUp(CFRunLoopGetMain());
}

// ---- Tabs -----------------------------------------------------------

// Each browser gets its own client, which leads CEF's callbacks back to its tab.
typedef struct {
  cef_client_t client;
  atomic_int refs;
  void *tab; // a retained Tab, released with the client
} TabClient;

static void CEF_CALLBACK client_add_ref(cef_base_ref_counted_t *self) {
  atomic_fetch_add(&((TabClient *)self)->refs, 1);
}
static int CEF_CALLBACK client_release(cef_base_ref_counted_t *self) {
  TabClient *c = (TabClient *)self;
  if (atomic_fetch_sub(&c->refs, 1) != 1) return 0;
  CFRelease(c->tab);
  free(c);
  return 1;
}
static int CEF_CALLBACK client_has_one_ref(cef_base_ref_counted_t *self) {
  return atomic_load(&((TabClient *)self)->refs) == 1;
}
static int CEF_CALLBACK client_has_ref(cef_base_ref_counted_t *self) {
  return atomic_load(&((TabClient *)self)->refs) >= 1;
}

static Tab *tab_of(cef_browser_t *browser) {
  cef_browser_host_t *h = browser->get_host(browser);
  cef_client_t *c = h ? h->get_client(h) : NULL;
  Tab *t = c && c->base.add_ref == client_add_ref ? (__bridge Tab *)((TabClient *)c)->tab : nil;
  unref(c);
  unref(h);
  return t;
}

static cef_client_t *new_client(Tab *t);

static void start_browser(Tab *t) {
  t->started = true;
  cef_window_info_t wi = {
      .size = sizeof wi,
      .windowless_rendering_enabled = 1,
      .shared_texture_enabled = 1,
  };
  if (t->windowed) {
    // A parent view, or CEF makes a window of its own, on screen.
    NSView *parent = windowed_open(t);
    wi = (cef_window_info_t){
        .size = sizeof wi,
        .bounds = {0, 0, (int)parent.bounds.size.width, (int)parent.bounds.size.height},
        .parent_view = (__bridge void *)parent,
        .runtime_style = CEF_RUNTIME_STYLE_ALLOY,
    };
  }
  cef_browser_settings_t bs = {
      .size = sizeof bs,
      .windowless_frame_rate = (int)NSScreen.mainScreen.maximumFramesPerSecond,
      .background_color = 0xFFFFFFFF, // opaque, like a browser tab
  };
  cef_string_t url = cef_str(t->startURL.UTF8String);
  cef_browser_host_create_browser(&wi, new_client(t), &url, &bs, NULL, NULL);
  cef_string_clear(&url);
}

static bowser_producer_t *producer_for(bowser_transport_e transport) {
  if (E.producers[transport]) return E.producers[transport];
  bowser_producer_config_s cfg = {
      .size = sizeof cfg,
      .transport = transport,
      .userdata = (void *)(intptr_t)transport,
      .wakeup_cb = on_wakeup,
      .key_cb = on_key,
      .mouse_cb = on_mouse,
      .scroll_cb = on_scroll,
      .text_cb = on_text,
      .resize_cb = on_resize,
      .focus_cb = on_focus,
      .attach_cb = on_attach,
      .message_cb = on_message,
      .display_cb = on_display,
  };
  if (bowser_producer_new(&cfg, &E.producers[transport]) != BOWSER_OK) return NULL;
  return E.producers[transport];
}

static Tab *open_tab(NSString *url, bowser_transport_e transport, bool windowed, NSString **error) {
  bowser_producer_t *p = producer_for(transport);
  Tab *t = [Tab new];
  t->transport = transport;
  t->windowed = windowed;
  t->size = (bowser_size_s){800, 500, NSScreen.mainScreen.backingScaleFactor};
  if (!p || bowser_surface_new(p, t->size, &t->surface) != BOWSER_OK) {
    *error = @(bowser_last_error());
    return nil;
  }
  t->sid = [NSString stringWithFormat:@"%u", ++E.nextId];
  t->startURL = url;
  t->url = url;
  t->pool = [NSMutableArray new];
  t->popupPool = [NSMutableArray new];
  t->sources = [NSMutableSet new];
  CALayer *root = bowser_surface_root_layer(t->surface);
  if (root && !windowed) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    t->content = [CALayer layer];
    t->content.anchorPoint = CGPointZero;
    t->content.opaque = YES;
    [root addSublayer:t->content];
    t->popupLayer = [CALayer layer];
    t->popupLayer.anchorPoint = CGPointZero;
    t->popupLayer.hidden = YES;
    [root addSublayer:t->popupLayer];
    [CATransaction commit];
  }
  if (windowed) windowed_open(t);
  E.tabs[t->sid] = t;
  E.bySurface[[NSValue valueWithPointer:t->surface]] = t;
  if (E.contextReady) start_browser(t);
  else [E.pending addObject:t];
  return t;
}

// A spare tab: a windowed browser with no page, made ahead so an open
// skips creating one (and, for the first, starting CEF's GPU process).
// Opening a page in it is one navigation. It is created with no URL, so the
// page it opens is the first entry in its history.
static void make_spare(void) {
  if (E.spare || E.osrOnly || E.quitting || !E.contextReady) return;
  NSString *error;
  E.spare = open_tab(@"", BOWSER_TRANSPORT_CALAYERHOST, true, &error);
  if (!E.spare) ENGINE_LOG("no spare tab: %s\n", error.UTF8String);
}

static void close_tab(Tab *t);

// Chromium starts its GPU process for the first page that draws, which
// costs the first real page about 400 ms. Draw a blank page now and close it.
static void warm_up(void) {
  NSString *error;
  Tab *t = open_tab(@"about:blank", BOWSER_TRANSPORT_CALAYERHOST, !E.osrOnly, &error);
  if (!t) return;
  NSString *sid = t->sid;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    Tab *w = E.tabs[sid];
    if (w) close_tab(w);
  });
}

static Tab *take_spare(NSString *url) {
  Tab *t = E.spare;
  E.spare = nil;
  if (!t || !t->surface) return nil;
  t->startURL = t->url = url;
  if (t->browser) load(t, url);
  else t->loadOnCreate = true;
  dispatch_async(dispatch_get_main_queue(), ^{ make_spare(); });
  return t;
}

// Hosts learn at once (the surface ends); the browser closes after.
static void close_tab(Tab *t) {
  if (!t->surface) return;
  [E.bySurface removeObjectForKey:[NSValue valueWithPointer:t->surface]];
  bowser_surface_free(t->surface);
  t->surface = NULL;
  t->attached = false;
  t->last = t->popup = nil;
  [t->pool removeAllObjects];
  [t->popupPool removeAllObjects];
  dismiss_menus(t);
  if (t->host) t->host->close_browser(t->host, 1);
  // A browser that CEF is still making closes in on_after_created.
  if (!t->started) {
    [E.pending removeObject:t];
    [E.tabs removeObjectForKey:t->sid];
  }
}

static void quit(void) {
  if (E.quitting) return;
  E.quitting = true;
  for (Tab *t in E.tabs.allValues) close_tab(t);
  if (E.tabs.count == 0) cef_quit_message_loop();
}

// ---- Browser lifetime -----------------------------------------------

static void CEF_CALLBACK on_after_created(cef_life_span_handler_t *self, cef_browser_t *browser) {
  Tab *t = tab_of(browser);
  if (!t) return unref(browser);
  t->browser = browser; // keep the reference we were given
  t->host = browser->get_host(browser);
  if (!t->surface) { // closed while CEF was making it
    t->host->close_browser(t->host, 1);
    return;
  }
  if (t->loadOnCreate) {
    t->loadOnCreate = false;
    load(t, t->url);
  }
  if (t->windowed) return windowed_created(t);
  t->host->was_resized(t->host); // the host may have resized us before now
  t->host->was_hidden(t->host, !t->attached);
}

static void CEF_CALLBACK on_before_close(cef_life_span_handler_t *self, cef_browser_t *browser) {
  Tab *t = tab_of(browser);
  unref(browser);
  if (!t) return;
  unref(t->host);
  unref(t->browser);
  t->host = NULL;
  t->browser = NULL;
  if (t->windowed) windowed_closed(t);
  if (t->surface) { // CEF closed it on its own
    close_tab(t);
    emit(@{@"event" : @"closed", @"surface" : t->sid});
  }
  [E.tabs removeObjectForKey:t->sid];
  if (E.quitting && E.tabs.count == 0) cef_quit_message_loop();
}

// ---- Native UI the producer must never show -------------------------
//
// The producer has no window on screen, so CEF would put menus, alerts, and
// file panels on whatever screen the user is looking at. Menus go to the host
// (see Menus); the rest is suppressed until the vocabulary can hand it over.
// windowed.m also keeps every window and menu of this process off screen.

// Links that target a new window (target=_blank, window.open) open in this
// tab instead: the host owns tabs, and there is no message for "new tab" yet.
static int CEF_CALLBACK on_before_popup(cef_life_span_handler_t *self, cef_browser_t *browser, cef_frame_t *frame,
                                        int popup_id, const cef_string_t *url, const cef_string_t *name,
                                        cef_window_open_disposition_t disposition, int gesture,
                                        const cef_popup_features_t *features, cef_window_info_t *wi,
                                        cef_client_t **client, cef_browser_settings_t *settings,
                                        cef_dictionary_value_t **extra, int *no_js_access) {
  cef_frame_t *main = browser->get_main_frame(browser);
  main->load_url(main, url);
  unref(main);
  unref(frame);
  unref(browser);
  return 1;
}

// Context menus: CEF's model, trimmed to what works without a window of our
// own, plus the link items a browser has.
enum { kOpenLink = MENU_ID_USER_FIRST, kCopyLink };

static bool kept_command(int command) {
  return (command >= MENU_ID_BACK && command <= MENU_ID_STOPLOAD) ||
         (command >= MENU_ID_UNDO && command <= MENU_ID_SELECT_ALL) ||
         (command >= MENU_ID_SPELLCHECK_SUGGESTION_0 && command <= MENU_ID_ADD_TO_DICTIONARY) ||
         command == kOpenLink || command == kCopyLink;
}

static void CEF_CALLBACK on_before_context_menu(cef_context_menu_handler_t *self, cef_browser_t *browser,
                                                cef_frame_t *frame, cef_context_menu_params_t *params,
                                                cef_menu_model_t *model) {
  // Print and View Source would open windows; Find has the find message.
  for (size_t i = model->get_count(model); i-- > 0;) {
    cef_menu_item_type_t type = model->get_type_at(model, i);
    if (type != MENUITEMTYPE_SEPARATOR && !kept_command(model->get_command_id_at(model, i))) model->remove_at(model, i);
  }
  int forward = model->get_index_of(model, MENU_ID_FORWARD);
  if (forward >= 0 && model->get_index_of(model, MENU_ID_RELOAD) < 0) {
    cef_string_t reload = cef_str("Reload");
    model->insert_item_at(model, (size_t)forward + 1, MENU_ID_RELOAD, &reload);
    cef_string_clear(&reload);
  }
  cef_string_userfree_t link = params->get_link_url(params);
  if (link && link->length) {
    cef_string_t open = cef_str("Open Link"), copy = cef_str("Copy Link Address");
    model->insert_separator_at(model, 0);
    model->insert_item_at(model, 0, kCopyLink, &copy);
    model->insert_item_at(model, 0, kOpenLink, &open);
    cef_string_clear(&open);
    cef_string_clear(&copy);
  }
  if (link) cef_string_userfree_free(link);
  // No separator first, last, or after another.
  for (size_t i = model->get_count(model); i-- > 0;) {
    if (model->get_type_at(model, i) != MENUITEMTYPE_SEPARATOR) continue;
    size_t n = model->get_count(model);
    if (i == 0 || i == n - 1 || model->get_type_at(model, i - 1) == MENUITEMTYPE_SEPARATOR) model->remove_at(model, i);
  }
  unref(model);
  unref(params);
  unref(frame);
  unref(browser);
}

static NSString *without_mnemonic(NSString *label) {
  NSMutableString *out = [NSMutableString new];
  for (NSUInteger i = 0; i < label.length; i++) {
    unichar c = [label characterAtIndex:i];
    if (c == '&' && i + 1 < label.length) c = [label characterAtIndex:++i]; // "&&" is "&"
    [out appendFormat:@"%C", c];
  }
  return out;
}

// The model's items for `menu`. commands gets the command of each flattened
// index, depth first, or 0 where there is none to run.
static NSArray *menu_items(cef_menu_model_t *m, NSMutableArray<NSNumber *> *commands) {
  NSMutableArray *items = [NSMutableArray new];
  for (size_t i = 0, n = m->get_count(m); i < n; i++) {
    if (!m->is_visible_at(m, i)) continue;
    cef_menu_item_type_t type = m->get_type_at(m, i);
    if (type == MENUITEMTYPE_SEPARATOR) {
      [commands addObject:@0];
      [items addObject:menu_item(@"", false, false, true, nil)];
      continue;
    }
    cef_string_userfree_t l = m->get_label_at(m, i);
    NSString *label = without_mnemonic(ns_str(l));
    if (l) cef_string_userfree_free(l);
    bool enabled = m->is_enabled_at(m, i);
    [commands addObject:@(enabled && type != MENUITEMTYPE_SUBMENU ? m->get_command_id_at(m, i) : 0)];
    NSArray *children = nil;
    if (type == MENUITEMTYPE_SUBMENU) {
      cef_menu_model_t *sub = m->get_sub_menu_at(m, i);
      children = sub ? menu_items(sub, commands) : @[];
      unref(sub);
    }
    [items addObject:menu_item(label, enabled, m->is_checked_at(m, i), false, children)];
  }
  return items;
}

static int CEF_CALLBACK run_context_menu(cef_context_menu_handler_t *self, cef_browser_t *browser, cef_frame_t *frame,
                                         cef_context_menu_params_t *params, cef_menu_model_t *model,
                                         cef_run_context_menu_callback_t *callback) {
  Tab *t = tab_of(browser);
  NSMutableArray<NSNumber *> *commands = [NSMutableArray new];
  NSArray *items = menu_items(model, commands);
  CGPoint at = {params->get_xcoord(params), params->get_ycoord(params)};
  unref(model);
  unref(params);
  unref(frame);
  unref(browser);
  if (!t || items.count == 0) {
    callback->cancel(callback);
    unref(callback);
    return 1;
  }
  menu_show(t, @"context", at, -1, items, ^(int index) {
    int command = index < (int)commands.count && index >= 0 ? commands[index].intValue : 0;
    if (command) callback->cont(callback, command, EVENTFLAG_NONE);
    else callback->cancel(callback);
    unref(callback);
  });
  return 1; // never CEF's own NSMenu
}

static int CEF_CALLBACK on_context_menu_command(cef_context_menu_handler_t *self, cef_browser_t *browser,
                                                cef_frame_t *frame, cef_context_menu_params_t *params, int command,
                                                cef_event_flags_t flags) {
  Tab *t = tab_of(browser);
  int handled = 0;
  if (command == kOpenLink || command == kCopyLink) {
    cef_string_userfree_t link = params->get_link_url(params);
    NSString *url = ns_str(link);
    if (link) cef_string_userfree_free(link);
    // In this tab, like target=_blank (see on_before_popup).
    if (command == kOpenLink && t && t->browser) load(t, url);
    if (command == kCopyLink) {
      [NSPasteboard.generalPasteboard clearContents];
      [NSPasteboard.generalPasteboard setString:url forType:NSPasteboardTypeString];
    }
    handled = 1;
  }
  unref(params);
  unref(frame);
  unref(browser);
  return handled;
}

static int CEF_CALLBACK on_jsdialog(cef_jsdialog_handler_t *self, cef_browser_t *browser, const cef_string_t *origin,
                                    cef_jsdialog_type_t type, const cef_string_t *message,
                                    const cef_string_t *prompt, cef_jsdialog_callback_t *callback, int *suppress) {
  *suppress = 1;
  unref(callback);
  unref(browser);
  return 0;
}

static int CEF_CALLBACK on_before_unload_dialog(cef_jsdialog_handler_t *self, cef_browser_t *browser,
                                                const cef_string_t *message, int is_reload,
                                                cef_jsdialog_callback_t *callback) {
  callback->cont(callback, 1, NULL); // leave the page
  unref(callback);
  unref(browser);
  return 1;
}

static int CEF_CALLBACK on_file_dialog(cef_dialog_handler_t *self, cef_browser_t *browser, cef_file_dialog_mode_t mode,
                                       const cef_string_t *title, const cef_string_t *path, cef_string_list_t filters,
                                       cef_string_list_t extensions, cef_string_list_t descriptions,
                                       cef_file_dialog_callback_t *callback) {
  callback->cancel(callback);
  unref(callback);
  unref(browser);
  return 1;
}

// ---- Handler tables -------------------------------------------------

static cef_render_handler_t render_handler = {
    STATIC_BASE(cef_render_handler_t),
    .get_view_rect = get_view_rect,
    .get_screen_info = get_screen_info,
    .on_popup_show = on_popup_show,
    .on_popup_size = on_popup_size,
    .on_accelerated_paint = on_accelerated_paint,
    .on_ime_composition_range_changed = on_ime_composition_range_changed,
};
static cef_display_handler_t display_handler = {
    STATIC_BASE(cef_display_handler_t),
    .on_address_change = on_address_change,
    .on_title_change = on_title_change,
    .on_loading_progress_change = on_loading_progress_change,
    .on_cursor_change = on_cursor_change,
    .on_tooltip = on_tooltip,
    .on_console_message = on_console_message,
};
static cef_load_handler_t load_handler = {
    STATIC_BASE(cef_load_handler_t),
    .on_loading_state_change = on_loading_state_change,
    .on_load_error = on_load_error,
};
static cef_find_handler_t find_handler = {
    STATIC_BASE(cef_find_handler_t),
    .on_find_result = on_find_result,
};
static cef_life_span_handler_t life_span_handler = {
    STATIC_BASE(cef_life_span_handler_t),
    .on_before_popup = on_before_popup,
    .on_after_created = on_after_created,
    .on_before_close = on_before_close,
};
static cef_context_menu_handler_t context_menu_handler = {
    STATIC_BASE(cef_context_menu_handler_t),
    .on_before_context_menu = on_before_context_menu,
    .run_context_menu = run_context_menu,
    .on_context_menu_command = on_context_menu_command,
};
static cef_jsdialog_handler_t jsdialog_handler = {
    STATIC_BASE(cef_jsdialog_handler_t),
    .on_jsdialog = on_jsdialog,
    .on_before_unload_dialog = on_before_unload_dialog,
};
static cef_dialog_handler_t dialog_handler = {
    STATIC_BASE(cef_dialog_handler_t),
    .on_file_dialog = on_file_dialog,
};

// Returned handlers carry a reference too; ours are static, so it's a no-op.
#define GETTER(name, type, object)                                                                           \
  static type *CEF_CALLBACK name(cef_client_t *self) { return &object; }
GETTER(get_render_handler, cef_render_handler_t, render_handler)
GETTER(get_display_handler, cef_display_handler_t, display_handler)
GETTER(get_load_handler, cef_load_handler_t, load_handler)
GETTER(get_find_handler, cef_find_handler_t, find_handler)
GETTER(get_life_span_handler, cef_life_span_handler_t, life_span_handler)
GETTER(get_context_menu_handler, cef_context_menu_handler_t, context_menu_handler)
GETTER(get_jsdialog_handler, cef_jsdialog_handler_t, jsdialog_handler)
GETTER(get_dialog_handler, cef_dialog_handler_t, dialog_handler)

// The new client's one reference goes to CEF with create_browser.
static cef_client_t *new_client(Tab *t) {
  TabClient *c = calloc(1, sizeof *c);
  c->client = (cef_client_t){
      .base = {.size = sizeof(cef_client_t), .add_ref = client_add_ref, .release = client_release,
               .has_one_ref = client_has_one_ref, .has_at_least_one_ref = client_has_ref},
      // Windowed browsers draw in their window; only OSR has a render handler.
      .get_render_handler = t->windowed ? NULL : get_render_handler,
      .get_display_handler = get_display_handler,
      .get_load_handler = get_load_handler,
      .get_find_handler = get_find_handler,
      .get_life_span_handler = get_life_span_handler,
      .get_context_menu_handler = get_context_menu_handler,
      .get_jsdialog_handler = get_jsdialog_handler,
      .get_dialog_handler = get_dialog_handler,
  };
  atomic_init(&c->refs, 1);
  c->tab = (void *)CFBridgingRetain(t);
  return &c->client;
}

// ---- Control commands -----------------------------------------------

static bool parse_transport(id value, bowser_transport_e *out) {
  if (value == nil || [value isEqual:@"calayerhost"]) *out = BOWSER_TRANSPORT_CALAYERHOST;
  else if ([value isEqual:@"iosurface"]) *out = BOWSER_TRANSPORT_IOSURFACE;
  else return false;
  return true;
}

static bool parse_mode(id value, bool *windowed) {
  if ([value isEqual:@"windowed"]) *windowed = true;
  else if ([value isEqual:@"osr"]) *windowed = false;
  else return false;
  return true;
}

static bool default_windowed(bowser_transport_e transport) {
  return transport == BOWSER_TRANSPORT_CALAYERHOST && !E.osrOnly;
}

// ---- Tracing ----------------------------------------------------------
// Chromium's own trace of every process, for finding where a frame was late.
// CEF writes it to a temporary name; the rename marks it complete.

static void CEF_CALLBACK on_end_tracing_complete(cef_end_tracing_callback_t *self, const cef_string_t *file) {
  NSString *tmp = ns_str(file);
  if (E.tracePath) rename(tmp.fileSystemRepresentation, E.tracePath.fileSystemRepresentation);
  E.tracePath = nil;
}

static cef_end_tracing_callback_t end_tracing_callback = {
    STATIC_BASE(cef_end_tracing_callback_t),
    .on_end_tracing_complete = on_end_tracing_complete,
};

static const char *kTraceCategories =
    "toplevel,benchmark,cc,viz,gpu,gpu.service,input,blink,latencyInfo,devtools.timeline,v8,"
    "disabled-by-default-devtools.timeline,disabled-by-default-devtools.timeline.frame,"
    "disabled-by-default-viz.quads";

static NSDictionary *trace_command(NSString *name, NSDictionary *cmd) {
  if ([name isEqualToString:@"trace_start"]) {
    id cats = cmd[@"categories"];
    cef_string_t c = cef_str([cats isKindOfClass:NSString.class] ? [cats UTF8String] : kTraceCategories);
    int ok = cef_begin_tracing(&c, NULL);
    cef_string_clear(&c);
    if (!ok) return @{@"error" : @"tracing is already on"};
    // The trace's clock against mach time, so other processes' events line up.
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    double mach_us = (double)mach_absolute_time() * tb.numer / tb.denom / 1000;
    return @{@"trace_us" : @(cef_now_from_system_trace_time()), @"mach_us" : @(mach_us)};
  }
  id path = cmd[@"path"];
  if (!path) {
    // No path: throw the trace away. A recorder restarts it this way so
    // Chromium's buffer, which stops when full, never fills.
    if (E.tracePath) return @{@"error" : @"a trace is still being written"};
    return cef_end_tracing(NULL, NULL) ? @{} : @{@"error" : @"tracing is off"};
  }
  if (![path isKindOfClass:NSString.class] || ![path isAbsolutePath]) return @{@"error" : @"trace_stop needs an absolute path"};
  NSString *tmp = [path stringByAppendingString:@".part"];
  cef_string_t f = cef_str([tmp UTF8String]);
  E.tracePath = path;
  int ok = cef_end_tracing(&f, &end_tracing_callback);
  cef_string_clear(&f);
  if (!ok) {
    E.tracePath = nil;
    return @{@"error" : @"tracing is off"};
  }
  return @{};
}

static NSDictionary *run_command(NSDictionary *cmd) {
  NSString *name = cmd[@"cmd"];
  if (![name isKindOfClass:NSString.class]) return @{@"error" : @"no cmd"};
  if ([name isEqualToString:@"open"]) {
    ENGINE_LOG("open %s\n", [cmd[@"url"] description].UTF8String);
    bowser_transport_e transport;
    if (!parse_transport(cmd[@"transport"], &transport)) return @{@"error" : @"transport: calayerhost or iosurface"};
    bool windowed = default_windowed(transport);
    id mode = cmd[@"mode"];
    if (mode && !parse_mode(mode, &windowed)) return @{@"error" : @"mode: windowed or osr"};
    if (windowed && transport != BOWSER_TRANSPORT_CALAYERHOST) return @{@"error" : @"windowed mode needs calayerhost"};
    id typed = cmd[@"url"];
    NSString *url = [typed isKindOfClass:NSString.class] ? fixup_url(typed) : nil;
    NSString *error;
    Tab *t = windowed && transport == BOWSER_TRANSPORT_CALAYERHOST ? take_spare(url ?: @"about:blank") : nil;
    if (!t) t = open_tab(url ?: @"about:blank", transport, windowed, &error);
    // Whoever opened it is about to attach a host: render the first frame now.
    if (t && t->windowed) windowed_await_host(t);
    return t ? @{@"surface" : t->sid, @"mode" : windowed ? @"windowed" : @"osr"} : @{@"error" : error};
  }
  if ([name isEqualToString:@"trace_start"] || [name isEqualToString:@"trace_stop"]) return trace_command(name, cmd);
  id sid = cmd[@"surface"];
  Tab *t = [sid isKindOfClass:NSString.class] ? E.tabs[sid] : nil;
  if (!t || !t->surface) return @{@"error" : [NSString stringWithFormat:@"no surface %@", sid]};
  if ([name isEqualToString:@"ticket"]) {
    ENGINE_LOG("%s: ticket\n", t->sid.UTF8String);
    char *ticket = bowser_surface_ticket(t->surface);
    NSDictionary *reply = @{@"ticket" : @(ticket)};
    bowser_string_free(ticket);
    return reply;
  }
  if ([name isEqualToString:@"close"]) {
    close_tab(t);
    return @{};
  }
  if ([name isEqualToString:@"message"]) {
    id message = cmd[@"name"], body = cmd[@"body"];
    if (![message isKindOfClass:NSString.class]) return @{@"error" : @"message needs a name"};
    if ([body isKindOfClass:NSString.class])
      body = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSString *error = handle_message(t, message, [body isKindOfClass:NSDictionary.class] ? body : @{});
    return error ? @{@"error" : error} : @{};
  }
  return @{@"error" : [NSString stringWithFormat:@"unknown cmd %@", name]};
}

static void run_line(NSData *line) {
  id cmd = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
  if (![cmd isKindOfClass:NSDictionary.class]) {
    emit(@{@"error" : @"not a JSON object"});
    return;
  }
  NSMutableDictionary *reply = [run_command(cmd) mutableCopy];
  if (cmd[@"id"]) reply[@"id"] = cmd[@"id"];
  emit(reply);
}

// Read commands from stdin. Its end means our parent is gone: quit.
static void start_control(void) {
  E.line = [NSMutableData new];
  fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK);
  E.input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(E.input, ^{
    char buf[16384];
    ssize_t n;
    while ((n = read(STDIN_FILENO, buf, sizeof buf)) > 0) [E.line appendBytes:buf length:(NSUInteger)n];
    bool ended = n == 0 || (errno != EAGAIN && errno != EINTR); // before commands can change errno
    for (;;) {
      const char *bytes = E.line.bytes;
      const char *nl = memchr(bytes, '\n', E.line.length);
      if (!nl) break;
      NSUInteger len = (NSUInteger)(nl - bytes);
      if (len) run_line([E.line subdataWithRange:NSMakeRange(0, len)]);
      [E.line replaceBytesInRange:NSMakeRange(0, len + 1) withBytes:NULL length:0];
    }
    if (ended) {
      dispatch_source_cancel(E.input);
      quit();
    }
  });
  dispatch_resume(E.input);
}

// ---- App ------------------------------------------------------------

static void CEF_CALLBACK on_context_initialized(cef_browser_process_handler_t *self) {
  E.contextReady = true;
  for (Tab *t in E.pending) start_browser(t);
  [E.pending removeAllObjects];
  if (E.control) {
    warm_up();
    make_spare();
    emit(@{@"event" : @"ready", @"pid" : @(getpid())});
    start_control();
  }
}

// Another process started with our profile. It exits (see main); we carry on.
static int CEF_CALLBACK on_already_running_app_relaunch(cef_browser_process_handler_t *self,
                                                        cef_command_line_t *cl, const cef_string_t *dir) {
  unref(cl);
  return 1;
}

static cef_browser_process_handler_t browser_process_handler = {
    STATIC_BASE(cef_browser_process_handler_t),
    .on_context_initialized = on_context_initialized,
    .on_already_running_app_relaunch = on_already_running_app_relaunch,
};

static void CEF_CALLBACK on_before_command_line_processing(cef_app_t *self, const cef_string_t *process_type,
                                                           cef_command_line_t *cl) {
  // Chromium asks the login keychain for its cookie key, which can show a
  // permission prompt. The producer has no UI to show one in.
  cef_string_t name = cef_str("use-mock-keychain");
  cl->append_switch(cl, &name);
  cef_string_clear(&name);
  unref(cl);
}

static cef_browser_process_handler_t *CEF_CALLBACK get_browser_process_handler(cef_app_t *self) {
  return &browser_process_handler;
}

static cef_app_t app = {
    STATIC_BASE(cef_app_t),
    .on_before_command_line_processing = on_before_command_line_processing,
    .get_browser_process_handler = get_browser_process_handler,
};

// CEF needs NSApp to tell it when AppKit is inside sendEvent:.
@interface BowserApplication : NSApplication <CefAppProtocol> {
  BOOL handlingSendEvent;
}
@end
@implementation BowserApplication
- (BOOL)isHandlingSendEvent { return handlingSendEvent; }
- (void)setHandlingSendEvent:(BOOL)value { handlingSendEvent = value; }
- (void)sendEvent:(NSEvent *)event {
  BOOL was = handlingSendEvent;
  handlingSendEvent = YES;
  [super sendEvent:event];
  handlingSendEvent = was;
}
@end

int main(int argc, char **argv) {
  @autoreleasepool {
    bowser_transport_e transport = BOWSER_TRANSPORT_CALAYERHOST;
    NSString *url = nil, *profile = nil;
    int tickets = -1;
    for (int i = 1; i < argc; i++) {
      if (!strcmp(argv[i], "--transport") && i + 1 < argc)
        transport = !strcmp(argv[++i], "iosurface") ? BOWSER_TRANSPORT_IOSURFACE : BOWSER_TRANSPORT_CALAYERHOST;
      else if (!strcmp(argv[i], "--url") && i + 1 < argc)
        url = @(argv[++i]);
      else if (!strcmp(argv[i], "--tickets") && i + 1 < argc)
        tickets = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--profile") && i + 1 < argc)
        profile = @(argv[++i]);
      else if (!strcmp(argv[i], "--mode") && i + 1 < argc) {
        bool windowed;
        if (!parse_mode(@(argv[++i]), &windowed)) {
          fprintf(stderr, "bowser-cef: --mode windowed or osr\n");
          return 2;
        }
        E.osrOnly = !windowed;
      }
    }
    E.control = !url && tickets < 0;
    if (!profile) {
      // $HOME first, so a sandboxed parent with a fake HOME keeps us inside it.
      const char *home = getenv("HOME");
      profile = [(home && *home ? @(home) : NSHomeDirectory())
          stringByAppendingPathComponent:@"Library/Application Support/libbowser/profile"];
    }
    profile = profile.stringByStandardizingPath;
    if (![profile isAbsolutePath])
      profile = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:profile];
    [NSFileManager.defaultManager createDirectoryAtPath:profile withIntermediateDirectories:YES attributes:nil error:nil];

    [BowserApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    windowed_init();

    const char *hash = cef_api_hash(CEF_API_VERSION, 0);
    if (strcmp(hash, CEF_API_HASH_PLATFORM) != 0) {
      fprintf(stderr, "bowser-cef: built for CEF API hash %s, framework has %s\n", CEF_API_HASH_PLATFORM, hash);
      return 1;
    }

    // One profile, on disk, for every tab: cookies, logins, and site zoom
    // persist. Chromium locks it, so one engine at a time can use it.
    cef_settings_t settings = {
        .size = sizeof settings,
        .windowless_rendering_enabled = 1,
        .root_cache_path = cef_str(profile.UTF8String),
        .cache_path = cef_str(profile.UTF8String),
        .persist_session_cookies = 1, // like a browser that restores its tabs
        .log_file = cef_str([profile stringByAppendingPathComponent:@"cef.log"].UTF8String),
        .log_severity = LOGSEVERITY_ERROR,
    };
    cef_main_args_t args = {argc, argv};
    // Before CEF starts: its context can be ready, and make the spare tab,
    // inside cef_initialize.
    E.tabs = [NSMutableDictionary new];
    E.bySurface = [NSMutableDictionary new];
    E.pending = [NSMutableArray new];
    E.menus = [NSMutableDictionary new];
    int ok = cef_initialize(&args, &settings, &app, NULL);
    cef_string_clear(&settings.root_cache_path);
    cef_string_clear(&settings.cache_path);
    cef_string_clear(&settings.log_file);
    if (!ok) {
      fprintf(stderr, "bowser-cef: cef_initialize failed (%d); is another bowser-cef using %s?\n",
              cef_get_exit_code(), profile.UTF8String);
      return 1;
    }

    E.device = MTLCreateSystemDefaultDevice();
    E.queue = [E.device newCommandQueue];

    if (!E.control) {
      NSString *error;
      Tab *t = open_tab(url ?: @"https://example.com", transport, default_windowed(transport), &error);
      if (!t) {
        fprintf(stderr, "bowser-cef: %s\n", error.UTF8String);
        return 1;
      }
      for (int i = 0; i < MAX(tickets, 1); i++) {
        char *ticket = bowser_surface_ticket(t->surface);
        printf("%s\n", ticket);
        bowser_string_free(ticket);
      }
      fflush(stdout);
    }

    dispatch_source_t signals[2];
    int numbers[2] = {SIGTERM, SIGINT};
    for (int i = 0; i < 2; i++) {
      signal(numbers[i], SIG_IGN);
      signals[i] = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, numbers[i], 0, dispatch_get_main_queue());
      dispatch_source_set_event_handler(signals[i], ^{ quit(); });
      dispatch_resume(signals[i]);
    }
    // A controller that dies leaves stdout with no reader. Quit through stdin's
    // EOF rather than die of SIGPIPE.
    signal(SIGPIPE, SIG_IGN);

    cef_run_message_loop();

    for (int i = 0; i < 2; i++) bowser_producer_free(E.producers[i]);
    cef_shutdown();
  }
  return 0;
}
