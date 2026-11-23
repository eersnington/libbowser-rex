// What main.m (the engine) and windowed.m (windowed mode) share.
#ifndef BOWSER_CEF_ENGINE_H
#define BOWSER_CEF_ENGINE_H

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include "bowser.h"
#include "include/capi/cef_browser_capi.h"

@class Buffer, Windowed;

@interface Tab : NSObject {
@public
  NSString *sid;
  bowser_transport_e transport;
  bool windowed; // zero copy (windowed.m); otherwise off-screen rendering
  bowser_surface_t *surface; // NULL once closed
  bowser_size_s size;
  bool attached, focused;
  NSString *startURL;
  bool started; // CEF is making, or has made, the browser

  cef_browser_t *browser;
  cef_browser_host_t *host;

  Windowed *win; // windowed mode's state

  // OSR frames
  NSMutableArray<Buffer *> *pool;
  Buffer *last;     // the newest frame, re-shown to a host that attaches
  CALayer *content; // CALAYERHOST: shows `last`
  uint64_t frameNo;
  bool repaintQueued;

  // OSR <select> and other popup widgets: a separate paint, composited over the view
  NSMutableArray<Buffer *> *popupPool;
  Buffer *popup; // newest popup paint, while shown
  bool popupShown;
  cef_rect_t popupRect; // view coordinates, inside the view
  CALayer *popupLayer;  // CALAYERHOST: shows `popup`

  // OSR input
  bool composing;
  cef_keyboard_input_event_t pendingKey; // the last key press, until its text arrives
  uint32_t heldButtons;                  // CEF_EVENTFLAG_*_MOUSE_BUTTON
  bowser_cursor_e cursor;

  // Navigation state, sent to the host and the controller
  NSString *url, *title;
  bool loading, canGoBack, canGoForward;
  double progress;
  CFTimeInterval stateSentAt;
  bool stateQueued;
  NSString *findText;
  int findCount, findActive;

  // Stats, printed every 2 s while frames arrive
  CFTimeInterval windowStart, lastPaint, resizeAt;
  int frames, late;
  double maxGapMs, jitter2, copyMs, copyMaxMs, gpuMs, resizeMaxMs;
  NSMutableSet<NSNumber *> *sources;
}
@end

bool engine_log_enabled(void);
#define ENGINE_LOG(...)                                                                                      \
  do {                                                                                                       \
    if (engine_log_enabled()) fprintf(stderr, "bowser-cef: " __VA_ARGS__);                                   \
  } while (0)

// ---- Menus (main.m) ---------------------------------------------------
//
// The `menu` and `menu_result` messages (README.md): the host shows the menu.

// One entry of a menu's `items`.
NSDictionary *menu_item(NSString *label, bool enabled, bool checked, bool separator, NSArray *children);
// Shows a menu on the tab's host. `done` runs once, with the chosen index in
// the flattened items, or -1: dismissed, no host, no answer in time, the host
// left, or the tab closed. `at` is in surface points, top-left origin.
void menu_show(Tab *t, NSString *kind, CGPoint at, int selected, NSArray *items, void (^done)(int index));
// The same for Chromium's synchronous menus: runs a nested run loop until the
// answer, as a real menu does.
int menu_show_sync(Tab *t, NSString *kind, CGPoint at, int selected, NSArray *items);

// ---- Windowed mode (windowed.m) ---------------------------------------

// Once, before CEF starts: the AppKit hooks that keep this process's windows
// and menus off screen, in every mode.
void windowed_init(void);
// Makes the tab's hidden window and its layer mirror, once. Returns the view
// CEF parents the browser in.
NSView *windowed_open(Tab *t);
void windowed_created(Tab *t); // CEF made the browser
void windowed_closed(Tab *t);  // CEF closed it
void windowed_key(Tab *t, const bowser_key_s *k);
void windowed_mouse(Tab *t, const bowser_mouse_s *m);
void windowed_scroll(Tab *t, const bowser_scroll_s *s);
void windowed_text(Tab *t, const bowser_text_s *text);
void windowed_resize(Tab *t);
void windowed_focus(Tab *t, bool focused);
void windowed_attach(Tab *t, bool attached);
void windowed_display(Tab *t, uint32_t display);

#endif
