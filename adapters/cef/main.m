// bowser-cef: a producer that shows a CEF browser through libbowser.
//
// CEF renders off screen with shared textures: its GPU process draws each
// frame into an IOSurface from its own pool and lends it to us for the length
// of on_accelerated_paint. We copy it into an IOSurface we own (Metal blit),
// then show that copy with the surface's transport: as layer contents in our
// CAContext on CALAYERHOST, or with bowser_surface_present on IOSURFACE.
//
// Usage: bowser-cef [--transport calayerhost|iosurface] [--url URL] [--tickets N]
// Prints N tickets, one per line, then runs until SIGTERM or SIGINT.
//
// CEF paces frames with its own timer. Driving it from the display link
// (external_begin_frame_enabled) measured no better: frame-interval jitter
// 2-4 ms against 2 ms, so it isn't used.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <stdatomic.h>

#include "bowser.h"
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_command_line_capi.h"
#include "include/capi/cef_context_menu_handler_capi.h"
#include "include/capi/cef_dialog_handler_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_input_event_utils_capi.h"
#include "include/capi/cef_jsdialog_handler_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_render_handler_capi.h"
#include "include/cef_api_hash.h"
#include "include/cef_application_mac.h"

// Copies of CEF frames we keep. The host shows one, the next is in flight, and
// the rest let us skip any the window server still reads.
enum { kPoolMax = 6 };

// ---- CEF plumbing ---------------------------------------------------

// Every handler below is a static object that lives as long as the process,
// so its reference count has nothing to track.
static void CEF_CALLBACK static_add_ref(cef_base_ref_counted_t *self) {}
static int CEF_CALLBACK static_release(cef_base_ref_counted_t *self) { return 0; }
static int CEF_CALLBACK static_has_one_ref(cef_base_ref_counted_t *self) { return 0; }
static int CEF_CALLBACK static_has_ref(cef_base_ref_counted_t *self) { return 1; }
#define STATIC_BASE(type)                                                                                    \
  .base = {.size = sizeof(type), .add_ref = static_add_ref, .release = static_release,                      \
           .has_one_ref = static_has_one_ref, .has_at_least_one_ref = static_has_ref}

// CEF hands each struct argument and return value over with a reference the
// receiver must drop.
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

static struct {
  bowser_producer_t *producer;
  bowser_surface_t *surface;
  bowser_transport_e transport;
  bowser_size_s size;
  const char *url;
  bool attached;

  cef_browser_t *browser;
  cef_browser_host_t *host;

  // Frames
  id<MTLDevice> device;
  id<MTLCommandQueue> queue;
  NSMutableArray<Buffer *> *pool;
  Buffer *last;     // the newest frame, re-shown to a host that attaches
  CALayer *content; // CALAYERHOST: shows `last`
  uint64_t frameNo;
  bool repaintQueued;

  // Input
  bool composing;
  cef_keyboard_input_event_t pendingKey; // the last key press, until its text arrives
  uint32_t heldButtons;                  // CEF_EVENTFLAG_*_MOUSE_BUTTON
  bowser_cursor_e cursor;

  // Stats, printed every 2 s while frames arrive
  CFTimeInterval windowStart, lastPaint, resizeAt;
  int frames, late;
  double maxGapMs, jitter2, copyMs, copyMaxMs, gpuMs, resizeMaxMs;
  NSMutableSet<NSNumber *> *sources;
} g;

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
  return [g.device newTextureWithDescriptor:d iosurface:s plane:0];
}

// A buffer shaped like `src` that no one is reading: neither the window server
// nor the host. Least recently shown first, so a frame the host hasn't picked
// up yet isn't overwritten.
static Buffer *take_buffer(IOSurfaceRef src) {
  size_t w = IOSurfaceGetWidth(src), h = IOSurfaceGetHeight(src);
  OSType format = IOSurfaceGetPixelFormat(src);
  [g.pool filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(Buffer *b, NSDictionary *_) {
            return IOSurfaceGetWidth(b->surface) == w && IOSurfaceGetHeight(b->surface) == h &&
                   IOSurfaceGetPixelFormat(b->surface) == format;
          }]];
  Buffer *best = nil;
  for (Buffer *b in g.pool)
    if (!IOSurfaceIsInUse(b->surface) && b != g.last && (!best || b->shownAt < best->shownAt)) best = b;
  if (best || g.pool.count >= kPoolMax) return best;

  Buffer *b = [Buffer new];
  b->surface = IOSurfaceCreate((__bridge CFDictionaryRef) @{
    (id)kIOSurfaceWidth : @(w),
    (id)kIOSurfaceHeight : @(h),
    (id)kIOSurfaceBytesPerElement : @4,
    (id)kIOSurfacePixelFormat : @(format),
  });
  CFTypeRef cs = IOSurfaceCopyValue(src, kIOSurfaceColorSpace);
  if (cs) {
    IOSurfaceSetValue(b->surface, kIOSurfaceColorSpace, cs);
    CFRelease(cs);
  }
  b->texture = texture_for(b->surface, MTLTextureUsageShaderWrite);
  [g.pool addObject:b];
  return b;
}

// Ask CEF for a fresh frame soon. Used when a frame couldn't reach the host:
// a page that has stopped changing would otherwise never send a newer one.
static void request_repaint(void) {
  if (g.repaintQueued) return;
  g.repaintQueued = true;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    g.repaintQueued = false;
    if (g.host && g.attached) g.host->invalidate(g.host, PET_VIEW);
  });
}

static void show(Buffer *b) {
  double scale = g.size.scale;
  if (g.transport == BOWSER_TRANSPORT_CALAYERHOST) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    g.content.contents = (__bridge id)b->surface;
    g.content.contentsScale = scale;
    // At the frame's own size, so a resize never stretches an old frame.
    g.content.frame = CGRectMake(0, 0, IOSurfaceGetWidth(b->surface) / scale, IOSurfaceGetHeight(b->surface) / scale);
    [CATransaction commit];
  } else if (g.attached) {
    bowser_size_s sz = g.size;
    if (bowser_surface_present(g.surface, b->surface, (bowser_rect_s){0, 0, sz.width, sz.height}) != BOWSER_OK)
      request_repaint();
  }
  b->shownAt = ++g.frameNo;
  g.last = b;
}

static void count_frame(IOSurfaceRef src, double copyMs, double gpuMs) {
  CFTimeInterval now = CACurrentMediaTime();
  double budgetMs = 1000.0 / NSScreen.mainScreen.maximumFramesPerSecond;
  if (g.lastPaint > 0 && now - g.lastPaint < 0.25) { // longer gaps are idle, not late
    double gap = (now - g.lastPaint) * 1000;
    if (gap > budgetMs * 1.5) g.late++;
    g.maxGapMs = fmax(g.maxGapMs, gap);
    g.jitter2 += (gap - budgetMs) * (gap - budgetMs);
  }
  g.lastPaint = now;
  g.frames++;
  g.copyMs += copyMs;
  g.copyMaxMs = fmax(g.copyMaxMs, copyMs);
  g.gpuMs += gpuMs;
  [g.sources addObject:@(IOSurfaceGetID(src))];
  if (g.resizeAt > 0 && IOSurfaceGetWidth(src) == (size_t)lround(g.size.width * g.size.scale) &&
      IOSurfaceGetHeight(src) == (size_t)lround(g.size.height * g.size.scale)) {
    g.resizeMaxMs = fmax(g.resizeMaxMs, (now - g.resizeAt) * 1000);
    g.resizeAt = 0;
  }
  if (g.windowStart == 0) g.windowStart = now;
  if (now - g.windowStart < 2) return;
  fprintf(stderr,
          "%s  %.1f fps  late %d  jitter %.1f ms  max gap %.1f ms  copy %.2f ms avg (gpu %.2f) %.2f max  "
          "resize->frame %.0f ms  %lu cef surfaces\n",
          g.transport == BOWSER_TRANSPORT_CALAYERHOST ? "calayerhost" : "iosurface", g.frames / (now - g.windowStart),
          g.late, sqrt(g.jitter2 / g.frames), g.maxGapMs, g.copyMs / g.frames, g.gpuMs / g.frames, g.copyMaxMs,
          g.resizeMaxMs, (unsigned long)g.sources.count);
  g.windowStart = now;
  g.frames = g.late = 0;
  g.maxGapMs = g.jitter2 = g.copyMs = g.copyMaxMs = g.gpuMs = g.resizeMaxMs = 0;
  [g.sources removeAllObjects];
}

static void CEF_CALLBACK on_accelerated_paint(cef_render_handler_t *self, cef_browser_t *browser,
                                              cef_paint_element_type_t type, size_t dirtyCount,
                                              const cef_rect_t *dirty, const cef_accelerated_paint_info_t *info) {
  unref(browser);
  IOSurfaceRef src = info->shared_texture_io_surface;
  if (type != PET_VIEW || !src) return; // popups (<select>) aren't composited yet
  if (metal_format(IOSurfaceGetPixelFormat(src)) == MTLPixelFormatInvalid) {
    fprintf(stderr, "bowser-cef: unsupported pixel format %#x\n", (unsigned)IOSurfaceGetPixelFormat(src));
    return;
  }
  CFTimeInterval start = CACurrentMediaTime();
  Buffer *b = take_buffer(src);
  if (!b) {
    request_repaint(); // every copy is still on screen; try again next frame
    return;
  }
  // CEF reclaims `src` when this callback returns, so the copy must be
  // finished, not just queued, before we return.
  id<MTLCommandBuffer> cb = [g.queue commandBuffer];
  id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
  [blit copyFromTexture:texture_for(src, MTLTextureUsageShaderRead) toTexture:b->texture];
  [blit endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
  double copyMs = (CACurrentMediaTime() - start) * 1000;
  show(b);
  count_frame(src, copyMs, (cb.GPUEndTime - cb.GPUStartTime) * 1000);
}

// ---- Geometry -------------------------------------------------------

static void CEF_CALLBACK get_view_rect(cef_render_handler_t *self, cef_browser_t *browser, cef_rect_t *rect) {
  unref(browser);
  *rect = (cef_rect_t){0, 0, (int)fmax(1, lround(g.size.width)), (int)fmax(1, lround(g.size.height))};
}

static int CEF_CALLBACK get_screen_info(cef_render_handler_t *self, cef_browser_t *browser, cef_screen_info_t *info) {
  unref(browser);
  info->device_scale_factor = (float)g.size.scale;
  info->depth = 24;
  info->depth_per_component = 8;
  return 1;
}

static void on_resize(void *ud, bowser_surface_t *s, bowser_size_s size) {
  bool rescaled = size.scale != g.size.scale;
  g.size = size;
  if (!g.host) return;
  if (g.last) g.resizeAt = CACurrentMediaTime(); // the first frame is a page load, not a resize
  if (rescaled) g.host->notify_screen_info_changed(g.host);
  g.host->was_resized(g.host);
}

// ---- Text input state -----------------------------------------------

static bowser_rect_s view_rect(cef_rect_t r) { return (bowser_rect_s){r.x, r.y, r.width, r.height}; }

static void CEF_CALLBACK on_ime_composition_range_changed(cef_render_handler_t *self, cef_browser_t *browser,
                                                          const cef_range_t *range, size_t count,
                                                          const cef_rect_t *bounds) {
  unref(browser);
  if (count == 0) return;
  cef_rect_t end = bounds[count - 1];
  bowser_surface_set_caret(g.surface, (bowser_rect_s){end.x + end.width, end.y, 2, end.height});
  if (!g.composing) return;
  bowser_rect_s rects[count];
  for (size_t i = 0; i < count; i++) rects[i] = view_rect(bounds[i]);
  bowser_surface_set_composition(g.surface, true, rects, count);
}

static int CEF_CALLBACK on_cursor_change(cef_display_handler_t *self, cef_browser_t *browser, cef_cursor_handle_t h,
                                         cef_cursor_type_t type, const cef_cursor_info_t *custom) {
  unref(browser);
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
  if (c != g.cursor) {
    g.cursor = c;
    bowser_surface_set_cursor(g.surface, c);
  }
  return 1;
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
  if (!g.host) return;
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
    g.heldButtons |= held[b];
    e.type = CEF_MOUSE_EVENT_DOWN;
    e.button = buttons[b];
    e.click_count = m->click_count;
    break;
  case BOWSER_MOUSE_UP:
    g.heldButtons &= ~held[b];
    e.type = CEF_MOUSE_EVENT_UP;
    e.button = buttons[b];
    e.click_count = m->click_count;
    break;
  case BOWSER_MOUSE_MOVE:
  case BOWSER_MOUSE_DRAG:
    e.type = CEF_MOUSE_EVENT_MOVE;
    for (int i = 0; i < 3; i++)
      if (g.heldButtons & held[i]) e.button = buttons[i];
    break;
  case BOWSER_MOUSE_EXIT: e.type = CEF_MOUSE_EVENT_LEAVE; break;
  }
  e.modifiers = cef_modifiers(m->mods) | g.heldButtons;
  g.host->send_mouse_event(g.host, &e);
}

static void on_scroll(void *ud, bowser_surface_t *s, const bowser_scroll_s *sc) {
  if (!g.host) return;
  // AppKit's line deltas become pixels the way Chromium's own Mac event
  // builder does it: 40 px per line.
  const float kPixelsPerLine = 40;
  float scale = sc->precise ? 1 : kPixelsPerLine;
  // NSEventPhase and cef_wheel_event_phase_t share bit values.
  const int kPhases = CEF_WHEEL_PHASE_BEGAN | CEF_WHEEL_PHASE_STATIONARY | CEF_WHEEL_PHASE_CHANGED |
                      CEF_WHEEL_PHASE_ENDED | CEF_WHEEL_PHASE_CANCELLED | CEF_WHEEL_PHASE_MAY_BEGIN;
  cef_wheel_input_event_t w = {
      .size = sizeof w,
      .modifiers = cef_modifiers(sc->mods) | g.heldButtons,
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
  g.host->send_wheel_event(g.host, &w);
}

static void send_char(cef_keyboard_input_event_t e, char16_t c) {
  e.type = CEF_KEY_EVENT_CHAR;
  memset(e.text, 0, sizeof e.text);
  e.text[0] = c;
  g.host->send_keyboard_event(g.host, &e);
}

// Text arrives in two parts, like AppKit's: key events here, and the text they
// insert through on_text (NSTextInputClient). Chromium wants a RAWKEYDOWN per
// press and a CHAR per inserted character, so a press waits in pendingKey for
// its text. Keys that AppKit turns into commands instead of text (Return, Tab,
// Escape, Control and Command chords) get their CHAR right away, as Chromium's
// own Mac view does.
static void on_key(void *ud, bowser_surface_t *s, const bowser_key_s *k) {
  if (!g.host) return;
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
  g.host->send_keyboard_event(g.host, &e);
  if (k->action == BOWSER_KEY_RELEASE) {
    g.pendingKey.size = 0;
    return;
  }
  bool chord = k->mods & (NSEventModifierFlagControl | NSEventModifierFlagCommand);
  if (!g.composing && e.text[0] && (e.text[0] < 0x20 || chord)) {
    send_char(e, e.text[0]);
    g.pendingKey.size = 0;
  } else {
    g.pendingKey = e;
  }
}

static cef_range_t cef_range(int64_t location, int64_t length) {
  if (location < 0) return (cef_range_t){UINT32_MAX, UINT32_MAX}; // NSNotFound: no range
  return (cef_range_t){(uint32_t)location, (uint32_t)(location + length)};
}

static void end_composition(void) {
  if (!g.composing) return;
  g.composing = false;
  bowser_surface_set_composition(g.surface, false, NULL, 0);
}

static void on_text(void *ud, bowser_surface_t *s, const bowser_text_s *t) {
  if (!g.host) return;
  NSString *text = @(t->text ? t->text : "");
  cef_string_t str = cef_str(text.UTF8String);
  cef_range_t replacement = cef_range(t->replacement_location, t->replacement_length);
  switch (t->kind) {
  case BOWSER_TEXT_INSERT:
    // One character typed with a key goes in as that key's CHAR, so pages see
    // keypress. Anything else (IME commits, emoji, dictation) is a commit.
    if (!g.composing && g.pendingKey.size && text.length == 1) {
      send_char(g.pendingKey, [text characterAtIndex:0]);
    } else {
      g.host->ime_commit_text(g.host, &str, &replacement, 0);
    }
    g.pendingKey.size = 0;
    end_composition();
    break;
  case BOWSER_TEXT_SET_MARKED:
    if (text.length == 0) {
      g.host->ime_cancel_composition(g.host);
      end_composition();
      break;
    }
    cef_composition_underline_t underline = {
        .size = sizeof underline,
        .range = {0, (uint32_t)text.length},
        .color = 0xFF000000,
        .style = CEF_CUS_SOLID,
    };
    cef_range_t selection = t->selected_location < 0 ? cef_range((int64_t)text.length, 0)
                                                      : cef_range(t->selected_location, t->selected_length);
    g.composing = true;
    g.pendingKey.size = 0;
    g.host->ime_set_composition(g.host, &str, 1, &underline, &replacement, &selection);
    break;
  case BOWSER_TEXT_UNMARK:
    g.host->ime_finish_composing_text(g.host, 0);
    end_composition();
    break;
  }
  cef_string_clear(&str);
}

static void on_focus(void *ud, bowser_surface_t *s, bool focused) {
  if (g.host) g.host->set_focus(g.host, focused);
}

static void on_attach(void *ud, bowser_surface_t *s, bool attached) {
  g.attached = attached;
  if (!g.host) return;
  // A tab no one shows is hidden: Chromium stops painting and throttles it.
  g.host->was_hidden(g.host, !attached);
  // A page that isn't changing paints nothing new, so give a new host the
  // frame we already have.
  if (attached && g.last) show(g.last);
}

static void on_wakeup(void *ud) {
  dispatch_async(dispatch_get_main_queue(), ^{ bowser_producer_tick(g.producer); });
}

// ---- Browser lifetime -----------------------------------------------

static void CEF_CALLBACK on_after_created(cef_life_span_handler_t *self, cef_browser_t *browser) {
  g.browser = browser; // keep the reference we were given
  g.host = browser->get_host(browser);
  g.host->was_resized(g.host); // the host may have resized us before now
  g.host->was_hidden(g.host, !g.attached);
}

static void CEF_CALLBACK on_before_close(cef_life_span_handler_t *self, cef_browser_t *browser) {
  unref(browser);
  unref(g.host);
  unref(g.browser);
  g.host = NULL;
  g.browser = NULL;
  cef_quit_message_loop();
}

static void quit(void) {
  if (g.host) g.host->close_browser(g.host, 1);
  else cef_quit_message_loop();
}

// ---- Native UI the producer must never show -------------------------
//
// The producer has no window, so CEF would put menus, alerts, and file panels
// on whatever screen the user is looking at. Suppress them until the ABI can
// hand them to the host.

// Open links that target a new window in this browser instead.
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

static void CEF_CALLBACK on_before_context_menu(cef_context_menu_handler_t *self, cef_browser_t *browser,
                                                cef_frame_t *frame, cef_context_menu_params_t *params,
                                                cef_menu_model_t *model) {
  model->clear(model); // an empty menu isn't shown
  unref(model);
  unref(params);
  unref(frame);
  unref(browser);
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
    .on_accelerated_paint = on_accelerated_paint,
    .on_ime_composition_range_changed = on_ime_composition_range_changed,
};
static cef_display_handler_t display_handler = {
    STATIC_BASE(cef_display_handler_t),
    .on_cursor_change = on_cursor_change,
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
GETTER(get_life_span_handler, cef_life_span_handler_t, life_span_handler)
GETTER(get_context_menu_handler, cef_context_menu_handler_t, context_menu_handler)
GETTER(get_jsdialog_handler, cef_jsdialog_handler_t, jsdialog_handler)
GETTER(get_dialog_handler, cef_dialog_handler_t, dialog_handler)

static cef_client_t client = {
    STATIC_BASE(cef_client_t),
    .get_render_handler = get_render_handler,
    .get_display_handler = get_display_handler,
    .get_life_span_handler = get_life_span_handler,
    .get_context_menu_handler = get_context_menu_handler,
    .get_jsdialog_handler = get_jsdialog_handler,
    .get_dialog_handler = get_dialog_handler,
};

static void CEF_CALLBACK on_context_initialized(cef_browser_process_handler_t *self) {
  cef_window_info_t wi = {
      .size = sizeof wi,
      .windowless_rendering_enabled = 1,
      .shared_texture_enabled = 1,
  };
  cef_browser_settings_t bs = {
      .size = sizeof bs,
      .windowless_frame_rate = (int)NSScreen.mainScreen.maximumFramesPerSecond,
      .background_color = 0xFFFFFFFF, // opaque, like a browser tab
  };
  cef_string_t url = cef_str(g.url);
  cef_browser_host_create_browser(&wi, &client, &url, &bs, NULL, NULL);
  cef_string_clear(&url);
}

static cef_browser_process_handler_t browser_process_handler = {
    STATIC_BASE(cef_browser_process_handler_t),
    .on_context_initialized = on_context_initialized,
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

// ---- Main -----------------------------------------------------------

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
    g.transport = BOWSER_TRANSPORT_CALAYERHOST;
    g.url = "https://example.com";
    int tickets = 1;
    for (int i = 1; i < argc; i++) {
      if (!strcmp(argv[i], "--transport") && i + 1 < argc)
        g.transport = !strcmp(argv[++i], "iosurface") ? BOWSER_TRANSPORT_IOSURFACE : BOWSER_TRANSPORT_CALAYERHOST;
      else if (!strcmp(argv[i], "--url") && i + 1 < argc)
        g.url = argv[++i];
      else if (!strcmp(argv[i], "--tickets") && i + 1 < argc)
        tickets = atoi(argv[++i]);
    }

    [BowserApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

    const char *hash = cef_api_hash(CEF_API_VERSION, 0);
    if (strcmp(hash, CEF_API_HASH_PLATFORM) != 0) {
      fprintf(stderr, "bowser-cef: built for CEF API hash %s, framework has %s\n", CEF_API_HASH_PLATFORM, hash);
      return 1;
    }

    // A profile per process: two producers can't share one, and nothing in
    // it needs to outlive the producer yet.
    NSString *profile = [NSTemporaryDirectory() stringByAppendingFormat:@"bowser-cef.%d", getpid()];
    cef_settings_t settings = {
        .size = sizeof settings,
        .windowless_rendering_enabled = 1,
        .root_cache_path = cef_str(profile.UTF8String),
        .log_file = cef_str([profile stringByAppendingPathComponent:@"cef.log"].UTF8String),
        .log_severity = LOGSEVERITY_ERROR,
    };
    cef_main_args_t args = {argc, argv};
    int ok = cef_initialize(&args, &settings, &app, NULL);
    cef_string_clear(&settings.root_cache_path);
    cef_string_clear(&settings.log_file);
    if (!ok) {
      fprintf(stderr, "bowser-cef: cef_initialize failed (%d)\n", cef_get_exit_code());
      return 1;
    }

    g.device = MTLCreateSystemDefaultDevice();
    g.queue = [g.device newCommandQueue];
    g.pool = [NSMutableArray new];
    g.sources = [NSMutableSet new];
    g.size = (bowser_size_s){800, 500, NSScreen.mainScreen.backingScaleFactor};
    bowser_producer_config_s cfg = {
        .size = sizeof cfg,
        .transport = g.transport,
        .wakeup_cb = on_wakeup,
        .key_cb = on_key,
        .mouse_cb = on_mouse,
        .scroll_cb = on_scroll,
        .text_cb = on_text,
        .resize_cb = on_resize,
        .focus_cb = on_focus,
        .attach_cb = on_attach,
    };
    if (bowser_producer_new(&cfg, &g.producer) != BOWSER_OK ||
        bowser_surface_new(g.producer, g.size, &g.surface) != BOWSER_OK) {
      fprintf(stderr, "bowser-cef: %s\n", bowser_last_error());
      return 1;
    }
    CALayer *root = bowser_surface_root_layer(g.surface);
    if (root) {
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      g.content = [CALayer layer];
      g.content.anchorPoint = CGPointZero;
      g.content.opaque = YES;
      [root addSublayer:g.content];
      [CATransaction commit];
    }
    for (int i = 0; i < tickets; i++) {
      char *t = bowser_surface_ticket(g.surface);
      printf("%s\n", t);
      bowser_string_free(t);
    }
    fflush(stdout);

    dispatch_source_t signals[2];
    int numbers[2] = {SIGTERM, SIGINT};
    for (int i = 0; i < 2; i++) {
      signal(numbers[i], SIG_IGN);
      signals[i] = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, numbers[i], 0, dispatch_get_main_queue());
      dispatch_source_set_event_handler(signals[i], ^{ quit(); });
      dispatch_resume(signals[i]);
    }

    cef_run_message_loop();

    g.last = nil;
    [g.pool removeAllObjects];
    bowser_surface_free(g.surface);
    bowser_producer_free(g.producer);
    cef_shutdown();
    [NSFileManager.defaultManager removeItemAtPath:profile error:nil];
  }
  return 0;
}
