// Windowed mode: zero-copy CEF for CALAYERHOST (docs/perf.md).
//
// Chromium on macOS already splits work the libbowser way: its GPU process
// draws into a CAContext, and the browser process shows that context in its
// NSView with a CALayerHost. So each tab runs CEF *windowed*, in a window the
// user never sees, and a second CALayerHost with the same context ID sits in
// the surface's root layer. The host's CALayerHost shows our context, which
// nests Chromium's: no readback, no blit, Chromium's own frame pacing.
//
// Input becomes synthesized NSEvents sent to Chromium's own view
// (RenderWidgetHostViewCocoa), so Chromium's Mac event code runs unchanged.
// Text from the host's IME is replayed inside that view's keyDown: through a
// stand-in NSTextInputContext, the way AppKit would deliver it.
//
// This file also holds the AppKit hooks that keep every window and menu of
// the process off screen, which OSR tabs rely on too.
#import <objc/runtime.h>

#include "engine.h"
#include "include/capi/cef_browser_capi.h"

// The private CALayerHost API, as declared in src/remote_api.h.
@interface CALayerHost : CALayer
@property uint32_t contextId;
@end

@class HiddenWindow;

@interface Windowed : NSObject {
@public
  HiddenWindow *window;
  CALayerHost *mirror; // ours, in the surface's root layer
  uint32_t display;    // the host's CGDirectDisplayID; 0 until it says
  bool key;            // what the window last told Chromium about isKeyWindow

  // A popup widget (date picker, <datalist>): Chromium's window for it, and
  // its mirror over the page.
  __weak NSWindow *popup;
  CALayerHost *popupMirror;
  CGRect popupRect; // surface points
  id popupObserver;
  bool pressInPopup; // a button went down over the popup: it gets the drag and the release

  // Input
  NSMutableArray *textOps; // host text, waiting to be replayed in keyDown:
  NSEvent *pendingKeyDown; // a press, until its text (if any) has arrived
  bool flushQueued;
  uint32_t heldButtons; // bit per bowser button
  NSInteger eventNumber;
}
@end
@implementation Windowed
@end

static void swizzle(Class cls, SEL sel, IMP imp, IMP *orig) {
  Method m = class_getInstanceMethod(cls, sel);
  if (!m) {
    fprintf(stderr, "bowser-cef: no -[%s %s] to hook\n", class_getName(cls), sel_getName(sel));
    return;
  }
  // The class gets its own method, so a superclass's stays untouched.
  class_addMethod(cls, sel, method_getImplementation(m), method_getTypeEncoding(m));
  IMP old = method_setImplementation(class_getInstanceMethod(cls, sel), imp);
  if (orig) *orig = old;
}

// ---- The window no one sees -----------------------------------------
//
// It must stay "visible" to Chromium, or Chromium stops drawing. It must never
// be visible to the user, take focus, or show up in Mission Control, ⌘Tab,
// screen sharing, or screenshots.
//
// So it is never ordered in, and its frame sits on the host's display:
// Chromium takes the refresh rate it paces frames to, and the scale, from the
// window's screen. (An ordered-in window off every display stops drawing once
// the page idles; docs/perf.md, "Placement".)

@interface HiddenWindow : NSWindow {
@public
  __weak Tab *tab;
}
@end
@implementation HiddenWindow
- (BOOL)canBecomeKeyWindow { return NO; } // never take focus from the user's app
- (BOOL)canBecomeMainWindow { return NO; }
// Chromium marks its widget active (caret blink, focus rings, selection color)
// from the key window. The host's focus stands in for it.
- (BOOL)isKeyWindow { return tab && tab->win->key; }
- (NSRect)constrainFrameRect:(NSRect)r toScreen:(NSScreen *)s { return r; }
// Chromium hides a web page in an occluded window, as for a background tab.
// Its own occlusion checker sets isOccluded (a category on NSWindow) for
// windows on screen; this one never is, so it answers whether a host shows
// the tab instead.
- (BOOL)isOccluded { return !(tab && tab->attached); }
- (NSWindowOcclusionState)occlusionState { return self.isOccluded ? 0 : NSWindowOcclusionStateVisible; }
// CEF closes a windowed browser by closing its top-level window; a borderless
// window has no close button, so performClose: would only beep. The browser
// goes when its view does, so drop the views too.
- (void)performClose:(id)sender {
  [[self.contentView.subviews copy] makeObjectsPerformSelector:@selector(removeFromSuperview)];
  [self close];
}
@end

// Popup windows by the tab they belong to.
static NSMapTable<NSWindow *, Tab *> *popupOwners;

static Tab *tab_for_view(NSView *v) {
  NSWindow *w = v.window;
  return [w isKindOfClass:HiddenWindow.class] ? ((HiddenWindow *)w)->tab : [popupOwners objectForKey:w];
}

static NSScreen *screen_for(uint32_t display) {
  for (NSScreen *s in NSScreen.screens)
    if ([s.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == display) return s;
  return NSScreen.screens.firstObject; // the menu bar's display
}

// At the display's top-left corner: Chromium keeps popups on the window's
// screen, so a list below a field has the room it would usually have.
static NSRect window_frame(Tab *t) {
  NSRect screen = screen_for(t->win->display).frame;
  return NSMakeRect(NSMinX(screen), NSMaxY(screen) - t->size.height, t->size.width, t->size.height);
}

NSView *windowed_open(Tab *t) {
  if (t->win) return t->win->window.contentView;
  Windowed *w = [Windowed new];
  t->win = w;
  w->textOps = [NSMutableArray new];
  HiddenWindow *win = [[HiddenWindow alloc] initWithContentRect:window_frame(t)
                                                      styleMask:NSWindowStyleMaskBorderless
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
  win->tab = t;
  win.releasedWhenClosed = NO;
  win.ignoresMouseEvents = YES;
  win.hasShadow = NO;
  win.excludedFromWindowsMenu = YES;
  win.sharingType = NSWindowSharingNone;
  win.animationBehavior = NSWindowAnimationBehaviorNone;
  win.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                           NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorFullScreenAuxiliary |
                           NSWindowCollectionBehaviorTransient;
  win.backgroundColor = NSColor.whiteColor;
  win.contentView.wantsLayer = YES;
  w->window = win;

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  w->mirror = [CALayerHost layer];
  w->mirror.anchorPoint = CGPointZero;
  [bowser_surface_root_layer(t->surface) addSublayer:w->mirror];
  [CATransaction commit];
  return win.contentView;
}

// ---- Popup widgets ----------------------------------------------------
//
// Date and time pickers, <datalist> suggestions, and other popup widgets are
// windows of their own (RenderWidgetPopupWindow), with their own GPU layers,
// placed over the page in screen coordinates. They are never ordered in;
// their layers are mirrored over the page instead, and input over them goes
// to them, as OSR composites and routes its popup paint. Chromium opens a
// popup from the user's input, so it belongs to the tab that last had some.

static __weak Tab *lastInputTab;

static void mirror_layer_host(CALayerHost *host);

static CALayerHost *find_layer_host(CALayer *l) {
  if (object_getClass(l) == NSClassFromString(@"CALayerHost")) return (CALayerHost *)l;
  for (CALayer *sub in l.sublayers) {
    CALayerHost *found = find_layer_host(sub);
    if (found) return found;
  }
  return nil;
}

static void place_popup(Tab *t) {
  Windowed *w = t->win;
  NSRect page = w->window.frame, popup = w->popup.frame;
  // Inside the surface, as OSR keeps its popups: one near the bottom opens upward.
  CGRect r = CGRectMake(NSMinX(popup) - NSMinX(page), NSMaxY(page) - NSMaxY(popup), NSWidth(popup), NSHeight(popup));
  r.origin.x = fmax(0, fmin(r.origin.x, t->size.width - r.size.width));
  r.origin.y = fmax(0, fmin(r.origin.y, t->size.height - r.size.height));
  w->popupRect = r;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  w->popupMirror.position = w->popupRect.origin;
  [CATransaction commit];
}

static void drop_popup(Tab *t, NSWindow *popup) {
  Windowed *w = t->win;
  if (!w || (w->popup && w->popup != popup)) return;
  ENGINE_LOG("%s: popup closed\n", t->sid.UTF8String);
  [NSNotificationCenter.defaultCenter removeObserver:w->popupObserver];
  w->popupObserver = nil;
  w->popup = nil;
  w->pressInPopup = false;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  w->popupMirror.hidden = YES;
  w->popupMirror.contextId = 0;
  [CATransaction commit];
}

// A window Chromium wants on screen: if it is a popup widget, show it in its tab.
static void adopt_popup(NSWindow *popup) {
  static Class cls;
  if (!cls) cls = NSClassFromString(@"RenderWidgetPopupWindow");
  Tab *t = lastInputTab;
  if (!cls || ![popup isKindOfClass:cls] || !t || !t->win || [popupOwners objectForKey:popup]) return;
  Windowed *w = t->win;
  if (w->popup) drop_popup(t, w->popup);
  ENGINE_LOG("%s: popup %s\n", t->sid.UTF8String, NSStringFromRect(popup.frame).UTF8String);
  [popupOwners setObject:t forKey:popup];
  w->popup = popup;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (!w->popupMirror) {
    w->popupMirror = [CALayerHost layer];
    w->popupMirror.anchorPoint = CGPointZero;
    [bowser_surface_root_layer(t->surface) addSublayer:w->popupMirror];
  }
  w->popupMirror.hidden = NO;
  [CATransaction commit];
  place_popup(t);
  CALayerHost *host = find_layer_host(popup.contentView.layer);
  if (host) mirror_layer_host(host);
  __weak NSWindow *weakPopup = popup;
  __weak Tab *weakTab = t;
  w->popupObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification
                                                                     object:popup
                                                                      queue:nil
                                                                 usingBlock:^(NSNotification *n) {
                                                                   Tab *owner = weakTab;
                                                                   if (owner) drop_popup(owner, weakPopup);
                                                                 }];
}

static IMP orig_setFrameDisplay;
static void hooked_setFrameDisplay(NSWindow *self, SEL _cmd, NSRect frame, BOOL display) {
  ((void (*)(id, SEL, NSRect, BOOL))orig_setFrameDisplay)(self, _cmd, frame, display);
  Tab *t = [popupOwners objectForKey:self];
  if (t && t->win && t->win->popup == self) place_popup(t);
}

// ---- Keeping windows and menus off screen ---------------------------
//
// Chromium shows some UI as windows and menus of this process: <select>
// lists, popup widgets, the color panel. Each would land on whatever screen
// the user is looking at, at the hidden window's position. Menus go to the
// host instead (see Menus below); nothing else is ever ordered in.

static IMP orig_doOrderWindow;
static void *hooked_doOrderWindow(NSWindow *self, SEL _cmd, id options) {
  // A visible window may go away (or move); nothing may come on screen.
  if (!self.isVisible) {
    ENGINE_LOG("kept %s off screen\n", object_getClassName(self));
    adopt_popup(self);
    return NULL;
  }
  return ((void *(*)(id, SEL, id))orig_doOrderWindow)(self, _cmd, options);
}

// The public ways in, in case AppKit ever stops funneling them through
// _doOrderWindow:.
static void refuse_order(NSWindow *self, SEL _cmd, id sender) {
  ENGINE_LOG("refused %s for %s\n", sel_getName(_cmd), object_getClassName(self));
  adopt_popup(self);
}
static void refuse_order_regardless(NSWindow *self, SEL _cmd) { refuse_order(self, _cmd, nil); }
static IMP orig_orderWindow;
static void hooked_orderWindow(NSWindow *self, SEL _cmd, NSWindowOrderingMode mode, NSInteger other) {
  if (mode != NSWindowOut) return refuse_order(self, _cmd, nil);
  ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))orig_orderWindow)(self, _cmd, mode, other);
}
static IMP orig_setIsVisible;
static void hooked_setIsVisible(NSWindow *self, SEL _cmd, BOOL visible) {
  if (visible) return refuse_order(self, _cmd, nil);
  ((void (*)(id, SEL, BOOL))orig_setIsVisible)(self, _cmd, visible);
}
// A child window comes on screen with its parent; the hidden window never
// does, but keep the child out of it either way.
static void refuse_child(NSWindow *self, SEL _cmd, NSWindow *child, NSWindowOrderingMode mode) {
  ENGINE_LOG("refused a child %s\n", object_getClassName(child));
}

// Dragging out of a page would show a drag image on the user's screen. OSR
// refuses drags (no start_dragging handler); so does this: the drag begins
// and ends at once, with nothing dropped, the way AppKit tells its source.
static NSDraggingSession *refuse_drag(NSView *self, SEL _cmd, NSArray *items, NSEvent *event,
                                      id<NSDraggingSource> source) {
  ENGINE_LOG("refused a drag from %s\n", object_getClassName(self));
  dispatch_async(dispatch_get_main_queue(), ^{
    id s = source;
    NSDraggingSession *none = nil; // there was no session
    if ([s respondsToSelector:@selector(draggingSession:willBeginAtPoint:)])
      [s draggingSession:none willBeginAtPoint:NSZeroPoint];
    if ([s respondsToSelector:@selector(draggingSession:endedAtPoint:operation:)])
      [s draggingSession:none endedAtPoint:NSZeroPoint operation:NSDragOperationNone];
  });
  return nil;
}

// ---- Menus ----------------------------------------------------------
//
// AppKit's entry points, not Chromium's: a <select> runs WebMenuRunner, which
// shows an NSPopUpButtonCell's menu (performClickWithFrame:inView:); older
// and other paths use popUpMenuPositioningItem: or popUpContextMenu:. All of
// them block until the menu closes, so the hooks ask the host synchronously,
// then act as the real menu would: select the item and send its action.
// A menu of a view that isn't a tab's is dismissed, never shown.

// The menu's items for `menu`, and the NSMenuItem of each flattened index.
static NSArray *ns_menu_items(NSMenu *menu, NSMutableArray<NSMenuItem *> *refs) {
  NSMutableArray *items = [NSMutableArray new];
  for (NSMenuItem *item in menu.itemArray) {
    if (item.hidden) continue;
    [refs addObject:item];
    NSArray *children = item.submenu ? ns_menu_items(item.submenu, refs) : nil;
    [items addObject:menu_item(item.title, item.enabled, item.state == NSControlStateValueOn, item.separatorItem,
                               children)];
  }
  return items;
}

// Runs the host's menu. Returns the chosen item, or nil.
static NSMenuItem *run_menu(NSView *view, NSMenu *menu, NSString *kind, NSPoint inWindow, NSMenuItem *selected) {
  Tab *t = tab_for_view(view);
  if (!t) {
    ENGINE_LOG("dismissed a menu outside any tab\n");
    return nil;
  }
  NSMutableArray<NSMenuItem *> *refs = [NSMutableArray new];
  NSArray *items = ns_menu_items(menu, refs);
  NSUInteger sel = selected ? [refs indexOfObject:selected] : NSNotFound;
  CGPoint at = {inWindow.x, t->size.height - inWindow.y};
  int index = menu_show_sync(t, kind, at, sel == NSNotFound ? -1 : (int)sel, items);
  if (index < 0 || index >= (int)refs.count) return nil;
  NSMenuItem *item = refs[index];
  return item.enabled && !item.separatorItem && !item.submenu ? item : nil;
}

static void perform(NSMenuItem *item) {
  [item.menu performActionForItemAtIndex:[item.menu indexOfItem:item]];
}

static void hooked_performClick(NSPopUpButtonCell *self, SEL _cmd, NSRect frame, NSView *view) {
  // The control's top-left corner: the host puts the selected item there.
  NSRect r = [view convertRect:frame toView:nil];
  NSMenuItem *item = run_menu(view, self.menu, @"select", NSMakePoint(NSMinX(r), NSMaxY(r)), self.selectedItem);
  if (!item) return;
  [self selectItem:item];
  perform(item);
}

static BOOL hooked_popUpPositioning(NSMenu *self, SEL _cmd, NSMenuItem *positioned, NSPoint location, NSView *view) {
  NSPoint p = view ? [view convertPoint:location toView:nil] : location;
  NSMenuItem *item = run_menu(view, self, @"select", p, positioned);
  if (item) perform(item);
  return item != nil;
}

static void hooked_popUpContext(id cls, SEL _cmd, NSMenu *menu, NSEvent *event, NSView *view) {
  NSMenuItem *item = run_menu(view, menu, @"context", event.locationInWindow, nil);
  if (item) perform(item);
}
static void hooked_popUpContextFont(id cls, SEL _cmd, NSMenu *menu, NSEvent *event, NSView *view, NSFont *font) {
  hooked_popUpContext(cls, _cmd, menu, event, view);
}

// ---- Mirroring Chromium's CALayerHost --------------------------------
//
// Chromium makes a new CALayerHost (or sets a new context ID on one) when the
// GPU process's context changes: a cross-site navigation, a GPU process
// restart, a recycled compositor. It sets the ID, then adds the layer to its
// view's layer. Hooking both learns of it inside Chromium's own
// CATransaction, so the mirror changes in the same commit. The layer's view
// leads to its window, which leads to its tab.

static Class layerHostClass;

static NSView *view_for_layer(CALayer *l) {
  for (; l; l = l.superlayer)
    if ([l.delegate isKindOfClass:NSView.class]) return (NSView *)l.delegate;
  return nil;
}

static void mirror_layer_host(CALayerHost *host) {
  NSView *view = view_for_layer(host);
  Tab *t = tab_for_view(view);
  if (!t || !t->win) return;
  CALayerHost *mirror = view.window == t->win->popup ? t->win->popupMirror : t->win->mirror;
  uint32_t cid = host.contextId;
  if (!cid || host == mirror || mirror.contextId == cid) return;
  ENGINE_LOG("%s: chromium %s context %u -> %u\n", t->sid.UTF8String, mirror == t->win->mirror ? "page" : "popup",
             mirror.contextId, cid);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  mirror.contextId = cid;
  [CATransaction commit];
}

static IMP orig_setContextId;
static void hooked_setContextId(CALayerHost *self, SEL _cmd, uint32_t cid) {
  ((void (*)(id, SEL, uint32_t))orig_setContextId)(self, _cmd, cid);
  mirror_layer_host(self); // no tab yet if it isn't in a view: then addSublayer: finds it
}

static IMP orig_addSublayer;
static void hooked_addSublayer(CALayer *self, SEL _cmd, CALayer *layer) {
  ((void (*)(id, SEL, CALayer *))orig_addSublayer)(self, _cmd, layer);
  if (object_getClass(layer) == layerHostClass) mirror_layer_host((CALayerHost *)layer);
}

void windowed_init(void) {
  layerHostClass = NSClassFromString(@"CALayerHost");
  popupOwners = [NSMapTable weakToWeakObjectsMapTable];
  swizzle(layerHostClass, @selector(setContextId:), (IMP)hooked_setContextId, &orig_setContextId);
  swizzle(CALayer.class, @selector(addSublayer:), (IMP)hooked_addSublayer, &orig_addSublayer);

  Class window = NSWindow.class;
  if (class_getInstanceMethod(window, NSSelectorFromString(@"_doOrderWindow:")))
    swizzle(window, NSSelectorFromString(@"_doOrderWindow:"), (IMP)hooked_doOrderWindow, &orig_doOrderWindow);
  swizzle(window, @selector(orderWindow:relativeTo:), (IMP)hooked_orderWindow, &orig_orderWindow);
  swizzle(window, @selector(setIsVisible:), (IMP)hooked_setIsVisible, &orig_setIsVisible);
  swizzle(window, @selector(orderFront:), (IMP)refuse_order, NULL);
  swizzle(window, @selector(orderBack:), (IMP)refuse_order, NULL);
  swizzle(window, @selector(makeKeyAndOrderFront:), (IMP)refuse_order, NULL);
  swizzle(window, @selector(orderFrontRegardless), (IMP)refuse_order_regardless, NULL);
  swizzle(window, @selector(addChildWindow:ordered:), (IMP)refuse_child, NULL);
  swizzle(window, @selector(setFrame:display:), (IMP)hooked_setFrameDisplay, &orig_setFrameDisplay);
  swizzle(NSView.class, @selector(beginDraggingSessionWithItems:event:source:), (IMP)refuse_drag, NULL);

  swizzle(NSPopUpButtonCell.class, @selector(performClickWithFrame:inView:), (IMP)hooked_performClick, NULL);
  swizzle(NSMenu.class, @selector(popUpMenuPositioningItem:atLocation:inView:), (IMP)hooked_popUpPositioning, NULL);
  Class menuMeta = object_getClass(NSMenu.class);
  swizzle(menuMeta, @selector(popUpContextMenu:withEvent:forView:), (IMP)hooked_popUpContext, NULL);
  swizzle(menuMeta, @selector(popUpContextMenu:withEvent:forView:withFont:), (IMP)hooked_popUpContextFont, NULL);
}

// ---- Chromium's view ------------------------------------------------

static NSView *find_chromium_view(NSView *root) {
  static Class cls;
  if (!cls) cls = NSClassFromString(@"RenderWidgetHostViewCocoa");
  if (!root || !cls) return nil;
  NSMutableArray<NSView *> *queue = [NSMutableArray arrayWithObject:root];
  while (queue.count) {
    NSView *v = queue.firstObject;
    [queue removeObjectAtIndex:0];
    if ([v isKindOfClass:cls]) return v;
    [queue addObjectsFromArray:v.subviews];
  }
  return nil;
}

static NSView *chromium_view(Tab *t) { return t->win ? find_chromium_view(t->win->window.contentView) : nil; }

// The browser's own view: CEF's, holding Chromium's.
static NSView *browser_view(Tab *t) {
  return t->host ? (__bridge NSView *)t->host->get_window_handle(t->host) : nil;
}

// bowser points (top-left origin) to window coordinates (bottom-left).
static NSPoint window_point(Tab *t, double x, double y) { return NSMakePoint(x, t->size.height - y); }

static NSTimeInterval event_time(uint64_t ns) { return ns ? ns / 1e9 : NSProcessInfo.processInfo.systemUptime; }

// Where pointer input at (x, y) goes: the open popup when it is over it, or
// when `popup` says so, else the page.
typedef struct {
  NSView *view;
  NSWindow *window;
  NSPoint at; // window coordinates
} target_s;

static target_s target(Tab *t, double x, double y, bool popup) {
  Windowed *w = t->win;
  CGRect r = w->popupRect;
  if (w->popup && (popup || CGRectContainsPoint(r, CGPointMake(x, y)))) {
    NSView *v = find_chromium_view(w->popup.contentView);
    if (v) return (target_s){v, w->popup, NSMakePoint(x - r.origin.x, r.size.height - (y - r.origin.y))};
  }
  return (target_s){chromium_view(t), w->window, window_point(t, x, y)};
}

// ---- Text input -------------------------------------------------------
//
// AppKit calls insertText:/setMarkedText: on the view from inside keyDown:, by
// way of the input context. Chromium depends on that: text inserted during
// keyDown: becomes the key's keypress. The host ran the real IME already and
// sent its results, so the view's input context is swapped for one that
// replays them instead of running an IME in this process.

typedef enum { OP_INSERT, OP_MARK, OP_UNMARK } op_kind_e;

@interface TextOp : NSObject {
@public
  op_kind_e kind;
  NSString *text;
  NSRange selected, replacement;
}
@end
@implementation TextOp
@end

static NSRange ns_range(int64_t location, int64_t length) {
  return location < 0 ? NSMakeRange(NSNotFound, 0) : NSMakeRange((NSUInteger)location, (NSUInteger)length);
}

static void push_caret(Tab *t);

static void replay(Tab *t, NSView<NSTextInputClient> *client) {
  NSArray *ops = [t->win->textOps copy];
  [t->win->textOps removeAllObjects];
  for (TextOp *op in ops) {
    switch (op->kind) {
    case OP_INSERT: [client insertText:op->text replacementRange:op->replacement]; break;
    case OP_MARK: [client setMarkedText:op->text selectedRange:op->selected replacementRange:op->replacement]; break;
    case OP_UNMARK: [client unmarkText]; break;
    }
  }
}

static void interpret_keys(NSView<NSTextInputClient> *view, NSEvent *e);

@interface ReplayInputContext : NSTextInputContext
@end
@implementation ReplayInputContext
- (BOOL)handleEvent:(NSEvent *)event {
  Tab *t = tab_for_view((NSView *)self.client);
  if (event.type != NSEventTypeKeyDown || !t) return NO;
  if (t->win->textOps.count) {
    replay(t, (NSView<NSTextInputClient> *)self.client);
    return YES;
  }
  // No text from the host: Return, arrows, Delete, chords. AppKit's key
  // bindings turn them into commands (insertNewline:, deleteBackward:...),
  // which need no IME.
  interpret_keys((NSView<NSTextInputClient> *)self.client, event);
  return YES;
}
- (void)discardMarkedText {}
// Chromium calls this when the renderer's caret or composition bounds
// arrive, before it stores them: read them once it has.
- (void)invalidateCharacterCoordinates {
  Tab *t = tab_for_view((NSView *)self.client);
  if (t) dispatch_async(dispatch_get_main_queue(), ^{
      if (t->surface) push_caret(t);
    });
}
@end

// NSResponder's interpretKeyEvents: without the input context: straight to
// the key bindings.
static void interpret_keys(NSView<NSTextInputClient> *view, NSEvent *e) {
  // Characters with no command binding are text, as AppKit would insert.
  NSString *chars = e.characters;
  unichar c = chars.length ? [chars characterAtIndex:0] : 0;
  bool command = e.modifierFlags & (NSEventModifierFlagControl | NSEventModifierFlagCommand);
  bool shift = e.modifierFlags & NSEventModifierFlagShift, option = e.modifierFlags & NSEventModifierFlagOption;
  SEL sel = NULL;
  switch (e.keyCode) {
  case 36: case 76: sel = @selector(insertNewline:); break;
  case 48: sel = shift ? @selector(insertBacktab:) : @selector(insertTab:); break;
  case 51: sel = option ? @selector(deleteWordBackward:) : @selector(deleteBackward:); break;
  case 117: sel = @selector(deleteForward:); break;
  case 53: sel = @selector(cancelOperation:); break;
  case 123: sel = @selector(moveLeft:); break;
  case 124: sel = @selector(moveRight:); break;
  case 125: sel = @selector(moveDown:); break;
  case 126: sel = @selector(moveUp:); break;
  case 115: sel = @selector(moveToBeginningOfLine:); break;
  case 119: sel = @selector(moveToEndOfLine:); break;
  case 116: sel = @selector(scrollPageUp:); break;
  case 121: sel = @selector(scrollPageDown:); break;
  }
  if (sel) [view doCommandBySelector:sel];
  else if (!command && c >= 0x20 && (c < 0xF700 || c > 0xF8FF))
    [view insertText:chars replacementRange:NSMakeRange(NSNotFound, 0)];
}

static IMP orig_inputContext;
static const void *kReplayContext = &kReplayContext;

static NSTextInputContext *hooked_inputContext(NSView *self, SEL _cmd) {
  NSTextInputContext *real = ((id(*)(id, SEL))orig_inputContext)(self, _cmd);
  if (!real) return nil; // Chromium has text input off here
  ReplayInputContext *ours = objc_getAssociatedObject(self, kReplayContext);
  if (!ours) {
    ours = [[ReplayInputContext alloc] initWithClient:(id<NSTextInputClient>)self];
    objc_setAssociatedObject(self, kReplayContext, ours, OBJC_ASSOCIATION_RETAIN);
  }
  return ours;
}

static NSRect window_rect(Tab *t, NSView *v, NSRange r) {
  return [t->win->window convertRectFromScreen:[(id<NSTextInputClient>)v firstRectForCharacterRange:r
                                                                                       actualRange:NULL]];
}
static bowser_rect_s surface_rect(Tab *t, NSRect r) {
  return (bowser_rect_s){NSMinX(r), t->size.height - NSMaxY(r), NSWidth(r), NSHeight(r)};
}

// The caret and each composed character, from Chromium's own
// NSTextInputClient answers, so the host's IME window lands next to the text.
static void push_caret(Tab *t) {
  NSView<NSTextInputClient> *v = (NSView<NSTextInputClient> *)chromium_view(t);
  if (!v || !t->attached) return;
  NSRange sel = [v selectedRange], marked = [v markedRange];
  NSRange r = marked.location != NSNotFound ? marked : sel;
  if (r.location == NSNotFound) return;
  bowser_rect_s caret = surface_rect(t, window_rect(t, v, NSMakeRange(r.location + r.length, 0)));
  caret.width = fmax(2, caret.width);
  bowser_surface_set_caret(t->surface, caret);
  if (marked.location == NSNotFound || !marked.length) {
    bowser_surface_set_composition(t->surface, false, NULL, 0);
    return;
  }
  // One range per character: a range of several answers with the first
  // line's rect only. Chromium in a windowed CEF has no per-character bounds
  // from the renderer and answers every range with the caret (measured); then
  // the host gets that one rect, as for a whole-composition rect.
  bowser_rect_s rects[marked.length];
  size_t count = 0;
  for (NSUInteger i = 0; i < marked.length; i++)
    rects[count++] = surface_rect(t, window_rect(t, v, NSMakeRange(marked.location + i, 1)));
  if (count > 1 && !memcmp(&rects[0], &rects[count - 1], sizeof rects[0])) count = 1;
  bowser_surface_set_composition(t->surface, true, rects, count);
}

// ---- Input from the host --------------------------------------------

static void flush_key(Tab *t) {
  Windowed *w = t->win;
  w->flushQueued = false;
  NSView *v = chromium_view(t);
  NSEvent *down = w->pendingKeyDown;
  w->pendingKeyDown = nil;
  if (!v) return;
  if (down) [v keyDown:down];
  else if (w->textOps.count) replay(t, (NSView<NSTextInputClient> *)v); // emoji picker, dictation, a commit by mouse
  push_caret(t);
  // The renderer reports the new caret and composition bounds a moment later.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    if (t->surface) push_caret(t);
  });
}

// Callbacks run inside bowser_producer_tick, which delivers a press and the
// text it produced back to back. Wait for the tick to end before sending the
// press, so its text can be replayed inside keyDown:.
static void queue_flush(Tab *t) {
  if (t->win->flushQueued) return;
  t->win->flushQueued = true;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (t->win) flush_key(t);
  });
}

void windowed_key(Tab *t, const bowser_key_s *k) {
  lastInputTab = t;
  // A second press, or this press's release: the first press goes now, with
  // whatever text arrived for it.
  if (t->win->pendingKeyDown) flush_key(t);
  NSEvent *e = [NSEvent keyEventWithType:k->action == BOWSER_KEY_RELEASE ? NSEventTypeKeyUp : NSEventTypeKeyDown
                                location:NSZeroPoint
                           modifierFlags:(NSEventModifierFlags)k->mods
                               timestamp:event_time(k->timestamp_ns)
                            windowNumber:t->win->window.windowNumber
                                 context:nil
                              characters:@(k->text ? k->text : "")
             charactersIgnoringModifiers:@(k->unmodified_text ? k->unmodified_text : "")
                               isARepeat:k->action == BOWSER_KEY_REPEAT
                                 keyCode:k->keycode];
  if (!e) return;
  if (k->action == BOWSER_KEY_RELEASE) {
    [chromium_view(t) keyUp:e];
    return;
  }
  t->win->pendingKeyDown = e;
  queue_flush(t);
}

void windowed_text(Tab *t, const bowser_text_s *in) {
  TextOp *op = [TextOp new];
  op->kind = in->kind == BOWSER_TEXT_INSERT ? OP_INSERT : in->kind == BOWSER_TEXT_SET_MARKED ? OP_MARK : OP_UNMARK;
  op->text = @(in->text ? in->text : "");
  op->selected = ns_range(in->selected_location, in->selected_length);
  op->replacement = ns_range(in->replacement_location, in->replacement_length);
  if (op->kind == OP_MARK && op->selected.location == NSNotFound) op->selected = NSMakeRange(op->text.length, 0);
  [t->win->textOps addObject:op];
  queue_flush(t);
}

void windowed_mouse(Tab *t, const bowser_mouse_s *m) {
  Windowed *w = t->win;
  if (m->action == BOWSER_MOUSE_DOWN) {
    lastInputTab = t;
    if (!w->heldButtons) w->pressInPopup = w->popup && CGRectContainsPoint(w->popupRect, CGPointMake(m->x, m->y));
  }
  // A press, its drags, and its release go to where it started.
  target_s to = target(t, m->x, m->y, w->heldButtons || m->action == BOWSER_MOUSE_DOWN ? w->pressInPopup : false);
  if (m->action == BOWSER_MOUSE_EXIT) to = target(t, -1, -1, false);
  NSView *v = to.view;
  if (!v) return;
  int b = m->button >= 0 && m->button < 3 ? m->button : 0;
  static const NSEventType downs[] = {NSEventTypeLeftMouseDown, NSEventTypeRightMouseDown, NSEventTypeOtherMouseDown};
  static const NSEventType ups[] = {NSEventTypeLeftMouseUp, NSEventTypeRightMouseUp, NSEventTypeOtherMouseUp};
  static const NSEventType drags[] = {NSEventTypeLeftMouseDragged, NSEventTypeRightMouseDragged,
                                      NSEventTypeOtherMouseDragged};
  int held = w->heldButtons & 1 ? 0 : w->heldButtons & 2 ? 1 : 2;
  NSEventType type;
  switch (m->action) {
  case BOWSER_MOUSE_DOWN:
    type = downs[b];
    w->heldButtons |= 1u << b;
    break;
  case BOWSER_MOUSE_UP:
    type = ups[b];
    w->heldButtons &= ~(1u << b);
    break;
  case BOWSER_MOUSE_DRAG: type = drags[held]; break;
  case BOWSER_MOUSE_MOVE: type = w->heldButtons ? drags[held] : NSEventTypeMouseMoved; break;
  case BOWSER_MOUSE_EXIT: {
    NSEvent *e = [NSEvent enterExitEventWithType:NSEventTypeMouseExited
                                        location:window_point(t, m->x, m->y)
                                   modifierFlags:(NSEventModifierFlags)m->mods
                                       timestamp:event_time(m->timestamp_ns)
                                    windowNumber:w->window.windowNumber
                                         context:nil
                                     eventNumber:++w->eventNumber
                                  trackingNumber:0
                                        userData:NULL];
    [v mouseExited:e];
    return;
  }
  }
  NSEvent *e = [NSEvent mouseEventWithType:type
                                  location:to.at
                             modifierFlags:(NSEventModifierFlags)m->mods
                                 timestamp:event_time(m->timestamp_ns)
                              windowNumber:to.window.windowNumber
                                   context:nil
                               eventNumber:++w->eventNumber
                                clickCount:m->click_count
                                  pressure:m->action == BOWSER_MOUSE_DOWN ? 1 : 0];
  switch (type) {
  case NSEventTypeLeftMouseDown: [v mouseDown:e]; break;
  case NSEventTypeLeftMouseUp: [v mouseUp:e]; break;
  case NSEventTypeRightMouseDown: [v rightMouseDown:e]; break;
  case NSEventTypeRightMouseUp: [v rightMouseUp:e]; break;
  case NSEventTypeOtherMouseDown: [v otherMouseDown:e]; break;
  case NSEventTypeOtherMouseUp: [v otherMouseUp:e]; break;
  case NSEventTypeLeftMouseDragged: [v mouseDragged:e]; break;
  case NSEventTypeRightMouseDragged: [v rightMouseDragged:e]; break;
  case NSEventTypeOtherMouseDragged: [v otherMouseDragged:e]; break;
  default: [v mouseMoved:e]; break;
  }
  if (!w->heldButtons) w->pressInPopup = false;
}

// bowser carries NSEventPhase; CGEvent fields number the phases differently.
static int64_t cg_scroll_phase(int32_t p) {
  if (p & NSEventPhaseMayBegin) return kCGScrollPhaseMayBegin;
  if (p & NSEventPhaseBegan) return kCGScrollPhaseBegan;
  if (p & (NSEventPhaseChanged | NSEventPhaseStationary)) return kCGScrollPhaseChanged;
  if (p & NSEventPhaseEnded) return kCGScrollPhaseEnded;
  if (p & NSEventPhaseCancelled) return kCGScrollPhaseCancelled;
  return 0;
}
static int64_t cg_momentum_phase(int32_t p) {
  if (p & NSEventPhaseBegan) return kCGMomentumScrollPhaseBegin;
  if (p & (NSEventPhaseChanged | NSEventPhaseStationary)) return kCGMomentumScrollPhaseContinue;
  if (p & (NSEventPhaseEnded | NSEventPhaseCancelled)) return kCGMomentumScrollPhaseEnd;
  return kCGMomentumScrollPhaseNone;
}

// AppKit has no public constructor for scroll events with phases, so build a
// CGEvent with every field Chromium reads and convert it.
void windowed_scroll(Tab *t, const bowser_scroll_s *sc) {
  target_s to = target(t, sc->x, sc->y, false);
  NSView *v = to.view;
  if (!v) return;
  CGEventRef cg = CGEventCreateScrollWheelEvent2(NULL, sc->precise ? kCGScrollEventUnitPixel : kCGScrollEventUnitLine,
                                                 2, (int32_t)lround(sc->dy), (int32_t)lround(sc->dx), 0);
  if (!cg) return;
  CGEventSetIntegerValueField(cg, kCGScrollWheelEventIsContinuous, sc->precise);
  if (sc->precise) {
    CGEventSetDoubleValueField(cg, kCGScrollWheelEventPointDeltaAxis1, sc->dy);
    CGEventSetDoubleValueField(cg, kCGScrollWheelEventPointDeltaAxis2, sc->dx);
  }
  CGEventSetDoubleValueField(cg, kCGScrollWheelEventFixedPtDeltaAxis1, sc->dy);
  CGEventSetDoubleValueField(cg, kCGScrollWheelEventFixedPtDeltaAxis2, sc->dx);
  CGEventSetIntegerValueField(cg, kCGScrollWheelEventScrollPhase, cg_scroll_phase(sc->phase));
  CGEventSetIntegerValueField(cg, kCGScrollWheelEventMomentumPhase, cg_momentum_phase(sc->momentum_phase));
  CGEventSetFlags(cg, (CGEventFlags)sc->mods);
  if (sc->timestamp_ns) CGEventSetTimestamp(cg, sc->timestamp_ns);
  // Global (top-left) screen position of the point, and the target window, so
  // NSEvent derives locationInWindow.
  NSWindow *win = to.window;
  NSPoint wp = to.at;
  CGFloat primaryHeight = NSScreen.screens.firstObject.frame.size.height;
  CGEventSetLocation(cg, CGPointMake(NSMinX(win.frame) + wp.x, primaryHeight - (NSMinY(win.frame) + wp.y)));
  CGEventSetIntegerValueField(cg, kCGMouseEventWindowUnderMousePointer, win.windowNumber);
  CGEventSetIntegerValueField(cg, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, win.windowNumber);
  NSEvent *e = [NSEvent eventWithCGEvent:cg];
  CFRelease(cg);
  [v scrollWheel:e];
}

// ---- Size, display, focus, and attachment -------------------------------

void windowed_resize(Tab *t) {
  // The window takes the size; Chromium's view follows its superview.
  [t->win->window setFrame:window_frame(t) display:NO];
}

void windowed_display(Tab *t, uint32_t display) {
  NSScreen *before = t->win->window.screen;
  t->win->display = display;
  windowed_resize(t);
  if (t->win->window.screen == before) return;
  ENGINE_LOG("%s: on display %u\n", t->sid.UTF8String, display);
  // An unordered window gets no screen notifications of its own; Chromium
  // rereads its display and refresh rate from these.
  [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidChangeScreenNotification
                                                    object:t->win->window];
  [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidChangeBackingPropertiesNotification
                                                    object:t->win->window];
}

static void set_key(Tab *t, bool key) {
  if (t->win->key == key) return;
  t->win->key = key;
  // HiddenWindow answers isKeyWindow from it; tell Chromium it changed.
  [NSNotificationCenter.defaultCenter
      postNotificationName:key ? NSWindowDidBecomeKeyNotification : NSWindowDidResignKeyNotification
                    object:t->win->window];
}

void windowed_focus(Tab *t, bool focused) {
  set_key(t, focused);
  if (!t->host) return;
  t->host->set_focus(t->host, focused);
  NSView *v = chromium_view(t);
  if (!focused || !v) return;
  [t->win->window makeFirstResponder:v];
}

void windowed_attach(Tab *t, bool attached) {
  if (!attached) set_key(t, false);
  // A tab no one shows is hidden (see occlusionState): Chromium stops drawing
  // and throttles it. Hiding its view instead leaves it unable to take focus.
  // Chromium only heeds the notification from its occlusion checker.
  [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidChangeOcclusionStateNotification
                                                    object:t->win->window
                                                  userInfo:@{@"WebContentsOcclusionCheckerMac" : @YES}];
}

void windowed_created(Tab *t) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{ // the class exists once the first view does
    Class cls = NSClassFromString(@"RenderWidgetHostViewCocoa");
    if (cls) swizzle(cls, @selector(inputContext), (IMP)hooked_inputContext, &orig_inputContext);
  });
  // The browser view fills the window and follows its size.
  NSView *bv = browser_view(t);
  bv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  bv.frame = t->win->window.contentView.bounds;
  windowed_attach(t, t->attached);
  if (t->focused) windowed_focus(t, true);
}

void windowed_closed(Tab *t) {
  if (t->win->popup) drop_popup(t, t->win->popup);
  [t->win->window close];
  t->win->window->tab = nil;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [t->win->mirror removeFromSuperlayer];
  [CATransaction commit];
  t->win = nil;
}
