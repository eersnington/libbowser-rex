// Injected into a dev copy of the Rex client (DYLD_INSERT_LIBRARIES).
//
// 1. Redirects the client's connection to the user's Rex server socket to a
//    dev server (BOWSER_REX_SOCKET), so the dev client never touches the
//    user's sessions. A sandbox profile backs this up at the kernel level.
// 2. Keeps the dev client off the user's Spaces: every window goes to
//    Mission Control Space BOWSER_SPACE before it is ordered in, and the app
//    never activates (activation would switch the user to that Space).
// 3. Mounts libbowser surfaces in panes of dev.libbowser blocks
//    (RexBowser.swift).
// 4. Dumps the view tree to BOWSER_REX_DUMP on SIGUSR1, to find where Rex
//    draws blocks.
#include <sys/time.h>
#import <AppKit/AppKit.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdarg.h>
#include <objc/runtime.h>
#include <sys/socket.h>
#include <sys/un.h>

// From mirror.swift.
char *bowser_mirror_describe(id object, long limit);
char *bowser_mirror_field(id object, const char *name);
char *bowser_mirror_tree(id object, long depth);
// From RexBowser.swift.
void rex_bowser_install(void);
BOOL rex_bowser_handle_key(NSEvent *event);
NSWindow *rex_bowser_typing_window(void);
void rex_bowser_trace_c(const char *line);

static void trace(const char *fmt, ...) {
  const char *path = getenv("BOWSER_REX_TRACE");
  if (!path) return;
  FILE *f = fopen(path, "a");
  if (!f) return;
  struct timeval tv;
  gettimeofday(&tv, NULL);
  fprintf(f, "%ld.%06d ", (long)tv.tv_sec, (int)tv.tv_usec);
  va_list ap;
  va_start(ap, fmt);
  vfprintf(f, fmt, ap);
  va_end(ap);
  fputc('\n', f);
  fclose(f);
}

static int bowser_connect(int fd, const struct sockaddr *addr, socklen_t len) {
  const char *target = getenv("BOWSER_REX_SOCKET");
  if (addr && addr->sa_family == AF_UNIX) trace("connect %s", ((const struct sockaddr_un *)addr)->sun_path);
  if (target && addr && addr->sa_family == AF_UNIX) {
    const struct sockaddr_un *un = (const struct sockaddr_un *)addr;
    if (strstr(un->sun_path, "Application Support/rex/server.sock")) {
      struct sockaddr_un redirected = {.sun_family = AF_UNIX};
      strlcpy(redirected.sun_path, target, sizeof redirected.sun_path);
      return connect(fd, (struct sockaddr *)&redirected, sizeof redirected);
    }
  }
  return connect(fd, addr, len);
}

// Tracing only, to see how the client finds its server.
static int bowser_open(const char *path, int flags, ...) {
  va_list ap;
  va_start(ap, flags);
  int mode = va_arg(ap, int);
  va_end(ap);
  if (path && (strstr(path, "/rex") || strstr(path, "superlogical"))) trace("open %s", path);
  return open(path, flags, mode);
}

static int bowser_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa,
                              const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
  char args[1024] = "";
  for (int i = 0; argv && argv[i] && strlen(args) < 900; i++) {
    strlcat(args, " ", sizeof args);
    strlcat(args, argv[i], sizeof args);
  }
  trace("spawn%s", args);
  return posix_spawn(pid, path, fa, attr, argv, envp);
}

static int bowser_connectx(int fd, const sa_endpoints_t *ep, sae_associd_t aid, unsigned int flags,
                           const struct iovec *iov, unsigned int iovcnt, size_t *len, sae_connid_t *cid) {
  trace("connectx family=%d", ep && ep->sae_dstaddr ? ep->sae_dstaddr->sa_family : -1);
  return connectx(fd, ep, aid, flags, iov, iovcnt, len, cid);
}

__attribute__((used)) static struct {
  const void *replacement, *original;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)bowser_connect, (const void *)connect},
    {(const void *)bowser_open, (const void *)open},
    {(const void *)bowser_posix_spawn, (const void *)posix_spawn},
    {(const void *)bowser_connectx, (const void *)connectx},
};

// ---- Spaces and activation ------------------------------------------------

typedef int CGSConnectionID;
CGSConnectionID CGSMainConnectionID(void);
CFArrayRef CGSCopyManagedDisplaySpaces(CGSConnectionID);
void CGSAddWindowsToSpaces(CGSConnectionID, CFArrayRef windows, CFArrayRef spaces);
void CGSRemoveWindowsFromSpaces(CGSConnectionID, CFArrayRef windows, CFArrayRef spaces);

static NSArray<NSNumber *> *other_spaces; // every Space but the target

static NSNumber *target_space(void) {
  static NSNumber *space;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    const char *want = getenv("BOWSER_SPACE");
    if (!want) return;
    NSArray *displays = CFBridgingRelease(CGSCopyManagedDisplaySpaces(CGSMainConnectionID()));
    NSMutableArray *spaces = [NSMutableArray new];
    for (NSDictionary *d in displays) [spaces addObjectsFromArray:d[@"Spaces"]];
    long i = atol(want);
    if (i >= 1 && i <= (long)spaces.count) space = spaces[i - 1][@"ManagedSpaceID"];
    NSMutableArray *others = [NSMutableArray new];
    for (NSDictionary *sp in spaces)
      if (![sp[@"ManagedSpaceID"] isEqual:space]) [others addObject:sp[@"ManagedSpaceID"]];
    other_spaces = others;
  });
  return space;
}

static void swizzle(Class c, SEL sel, IMP imp, IMP *original) {
  Method m = class_getInstanceMethod(c, sel);
  if (m) *original = method_setImplementation(m, imp);
}

static IMP orig_orderWindow;
static void bowser_orderWindow(NSWindow *self, SEL _cmd, NSWindowOrderingMode mode, NSInteger other) {
  NSNumber *space = target_space();
  if (space && mode != NSWindowOut && self.windowNumber > 0) {
    // Only on the target: a window made on the Space you look at stays
    // there too unless it is taken off.
    CFArrayRef w = (__bridge CFArrayRef) @[ @(self.windowNumber) ];
    self.collectionBehavior &= ~(NSWindowCollectionBehaviorMoveToActiveSpace | NSWindowCollectionBehaviorCanJoinAllSpaces);
    CGSAddWindowsToSpaces(CGSMainConnectionID(), w, (__bridge CFArrayRef) @[ space ]);
    CGSRemoveWindowsFromSpaces(CGSMainConnectionID(), w, (__bridge CFArrayRef)other_spaces);
    trace("window %ld: Space %s only", (long)self.windowNumber, getenv("BOWSER_SPACE"));
  }
  ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))orig_orderWindow)(self, _cmd, mode, other);
}

// Browser panes see ⌘ keys before Rex does (RexBowser.swift decides which).
static IMP orig_sendEvent;
static void bowser_sendEvent(NSApplication *self, SEL _cmd, NSEvent *event) {
  if (event.type == NSEventTypeKeyDown && rex_bowser_handle_key(event)) return;
  ((void (*)(id, SEL, NSEvent *))orig_sendEvent)(self, _cmd, event);
}

static IMP orig_activate, orig_activateIgnoring, orig_runningActivate, orig_activateFrom;
static void bowser_noop(id self, SEL _cmd) {}
static void bowser_noop_bool(id self, SEL _cmd, BOOL flag) {}
static BOOL bowser_no_activation(id self, SEL _cmd, NSUInteger options) { return NO; }
static BOOL bowser_no_activation_from(id self, SEL _cmd, id from, NSUInteger options) { return NO; }

// ---- View tree dump --------------------------------------------------------

static void dump(NSView *v, int depth, NSMutableString *out) {
  NSRect f = [v convertRect:v.bounds toView:nil];
  [out appendFormat:@"%*s%@ frame=(%.0f,%.0f %.0fx%.0f)", depth * 2, "", NSStringFromClass(v.class), f.origin.x,
                    f.origin.y, f.size.width, f.size.height];
  NSString *ident = v.accessibilityIdentifier;
  if (ident.length) [out appendFormat:@" id=%@", ident];
  id label = [v accessibilityLabel];
  if ([label isKindOfClass:NSString.class] && [label length]) [out appendFormat:@" label=%@", label];
  if (v.layer) [out appendFormat:@" layer=%@", NSStringFromClass(v.layer.class)];
  if (v.hidden) [out appendString:@" hidden"];
  [out appendString:@"\n"];
  if ([NSStringFromClass(v.class) hasSuffix:@"NativePaneView"]) {
    char *desc = bowser_mirror_tree(v, 4);
    for (NSString *line in [@(desc) componentsSeparatedByString:@"\n"])
      [out appendFormat:@"%*s  . %@\n", depth * 2, "", line];
    free(desc);
  }
  for (NSView *s in v.subviews) dump(s, depth + 1, out);
}

static void dump_menu(NSMenu *menu, NSString *path, NSMutableString *out) {
  for (NSMenuItem *item in menu.itemArray) {
    NSString *here = path.length ? [NSString stringWithFormat:@"%@ > %@", path, item.title] : item.title;
    if (item.keyEquivalent.length) {
      NSEventModifierFlags m = item.keyEquivalentModifierMask;
      [out appendFormat:@"menu %@%@%@%@%@  %@  action=%@\n", m & NSEventModifierFlagControl ? @"⌃" : @"",
                        m & NSEventModifierFlagOption ? @"⌥" : @"", m & NSEventModifierFlagShift ? @"⇧" : @"",
                        m & NSEventModifierFlagCommand ? @"⌘" : @"", item.keyEquivalent, here,
                        item.action ? NSStringFromSelector(item.action) : @"-"];
    }
    if (item.submenu) dump_menu(item.submenu, here, out);
  }
}

static void dump_all(void) {
  const char *path = getenv("BOWSER_REX_DUMP");
  if (!path) return;
  NSMutableString *out = [NSMutableString new];
  dump_menu(NSApp.mainMenu, @"", out);
  for (NSWindow *w in NSApp.windows) {
    [out appendFormat:@"== window %ld %@ %@ visible=%d\n", (long)w.windowNumber, NSStringFromClass(w.class),
                      w.title, w.visible];
    if (w.contentView) dump(w.contentView.superview ?: w.contentView, 1, out);
  }
  [out writeToFile:@(path) atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// ---- Synthetic keys (dev hook) ---------------------------------------------
// SIGINFO: send each line of BOWSER_REX_KEYS through NSApp.sendEvent, the same
// path real keys take (key equivalents, menus, the responder chain).
// Lines: "cmd+l", "cmd+shift+g", "ctrl+opt+cmd+j", "enter", "esc", "tab", "type:some text".

static void send_key(NSWindow *w, NSString *chars, unsigned short code, NSEventModifierFlags mods) {
  NSEventType types[] = {NSEventTypeKeyDown, NSEventTypeKeyUp};
  for (int i = 0; i < 2; i++) {
    NSEventType t = types[i];
    NSEvent *e = [NSEvent keyEventWithType:t
                                  location:NSZeroPoint
                             modifierFlags:mods
                                 timestamp:NSProcessInfo.processInfo.systemUptime
                              windowNumber:w.windowNumber
                                   context:nil
                                characters:chars
               charactersIgnoringModifiers:chars
                                 isARepeat:NO
                                   keyCode:code];
    [NSApp sendEvent:e];
  }
}

static void play_keys(void) {
  const char *path = getenv("BOWSER_REX_KEYS");
  // Only into a browser pane that has the keyboard, never a terminal.
  NSWindow *w = rex_bowser_typing_window();
  if (!path) return;
  if (!w) {
    rex_bowser_trace_c("keys: no browser pane has the keyboard; dropped");
    return;
  }
  // US layout key codes, so pages see the key a keyboard would send.
  NSDictionary *codes = @{
    @"a" : @0,  @"s" : @1,  @"d" : @2,  @"f" : @3,  @"h" : @4,  @"g" : @5,  @"z" : @6,  @"x" : @7,  @"c" : @8,
    @"v" : @9,  @"b" : @11, @"q" : @12, @"w" : @13, @"e" : @14, @"r" : @15, @"y" : @16, @"t" : @17, @"1" : @18,
    @"2" : @19, @"3" : @20, @"4" : @21, @"6" : @22, @"5" : @23, @"=" : @24, @"9" : @25, @"7" : @26, @"-" : @27,
    @"8" : @28, @"0" : @29, @"o" : @31, @"u" : @32, @"i" : @34, @"p" : @35, @"l" : @37, @"j" : @38, @"k" : @40,
    @"n" : @45, @"m" : @46, @"." : @47, @"/" : @44, @" " : @49, @"," : @43, @";" : @41, @"'" : @39};
  NSString *all = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:nil];
  for (NSString *line in [all componentsSeparatedByString:@"\n"]) {
    if (!line.length) continue;
    trace("key %s", line.UTF8String);
    if ([line hasPrefix:@"type:"]) {
      NSString *text = [line substringFromIndex:5];
      for (NSUInteger i = 0; i < text.length; i++) {
        NSString *ch = [text substringWithRange:NSMakeRange(i, 1)];
        send_key(w, ch, [codes[ch.lowercaseString] unsignedShortValue], 0);
      }
    } else if ([line isEqualToString:@"enter"]) {
      send_key(w, @"\r", 36, 0);
    } else if ([line isEqualToString:@"esc"]) {
      send_key(w, @"\x1b", 53, 0);
    } else if ([line isEqualToString:@"tab"]) {
      send_key(w, @"\t", 48, 0);
    } else {
      NSArray *parts = [line componentsSeparatedByString:@"+"];
      NSEventModifierFlags mods = 0;
      for (NSString *p in parts) {
        if ([p isEqualToString:@"cmd"]) mods |= NSEventModifierFlagCommand;
        if ([p isEqualToString:@"shift"]) mods |= NSEventModifierFlagShift;
        if ([p isEqualToString:@"opt"]) mods |= NSEventModifierFlagOption;
        if ([p isEqualToString:@"ctrl"]) mods |= NSEventModifierFlagControl;
      }
      NSString *k = parts.lastObject;
      send_key(w, k, [codes[k] unsignedShortValue], mods);
    }
  }
}

__attribute__((constructor)) static void bowser_rex_init(void) {
  signal(SIGINFO, SIG_IGN);
  static dispatch_source_t keys;
  keys = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINFO, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(keys, ^{ play_keys(); });
  dispatch_resume(keys);
  trace("loaded pid=%d", getpid());
  swizzle(NSApplication.class, @selector(sendEvent:), (IMP)bowser_sendEvent, &orig_sendEvent);
  // Rex's classes are ready once the main run loop starts.
  dispatch_async(dispatch_get_main_queue(), ^{ rex_bowser_install(); });
  if (getenv("BOWSER_SPACE")) {
    swizzle(NSWindow.class, @selector(orderWindow:relativeTo:), (IMP)bowser_orderWindow, &orig_orderWindow);
    swizzle(NSApplication.class, @selector(activate), (IMP)bowser_noop, &orig_activate);
    swizzle(NSApplication.class, @selector(activateIgnoringOtherApps:), (IMP)bowser_noop_bool,
            &orig_activateIgnoring);
    // Newer Rex activates through NSRunningApplication; only this process
    // uses it here, so no app is ever brought to the front.
    swizzle(NSRunningApplication.class, @selector(activateWithOptions:), (IMP)bowser_no_activation,
            &orig_runningActivate);
    swizzle(NSRunningApplication.class, @selector(activateFromApplication:options:), (IMP)bowser_no_activation_from,
            &orig_activateFrom);
  }
  // SIGUSR2: ask the app to open its window as if its Dock icon was clicked,
  // without activating it.
  signal(SIGUSR2, SIG_IGN);
  static dispatch_source_t reopen;
  reopen = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR2, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(reopen, ^{
    // A real reopen Apple Event, sent to ourselves: SwiftUI opens its window
    // from AppKit's reopen handling, not from the delegate method alone.
    NSAppleEventDescriptor *ev =
        [NSAppleEventDescriptor appleEventWithEventClass:kCoreEventClass
                                                 eventID:kAEReopenApplication
                                        targetDescriptor:[NSAppleEventDescriptor currentProcessDescriptor]
                                                returnID:kAutoGenerateReturnID
                                           transactionID:kAnyTransactionID];
    OSStatus err = AESendMessage(ev.aeDesc, NULL, kAENoReply, kAEDefaultTimeout);
    trace("reopen sent err=%d", (int)err);
  });
  dispatch_resume(reopen);
  signal(SIGUSR1, SIG_IGN);
  static dispatch_source_t src;
  src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(src, ^{ dump_all(); });
  dispatch_resume(src);
}
