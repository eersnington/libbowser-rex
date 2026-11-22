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

static void trace(const char *fmt, ...) {
  const char *path = getenv("BOWSER_REX_TRACE");
  if (!path) return;
  FILE *f = fopen(path, "a");
  if (!f) return;
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
  if (space && mode != NSWindowOut && self.windowNumber > 0)
    CGSAddWindowsToSpaces(CGSMainConnectionID(), (__bridge CFArrayRef) @[ @(self.windowNumber) ],
                          (__bridge CFArrayRef) @[ space ]);
  ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))orig_orderWindow)(self, _cmd, mode, other);
}

static IMP orig_activate, orig_activateIgnoring;
static void bowser_noop(id self, SEL _cmd) {}
static void bowser_noop_bool(id self, SEL _cmd, BOOL flag) {}

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

static void dump_all(void) {
  const char *path = getenv("BOWSER_REX_DUMP");
  if (!path) return;
  NSMutableString *out = [NSMutableString new];
  for (NSWindow *w in NSApp.windows) {
    [out appendFormat:@"== window %ld %@ %@ visible=%d\n", (long)w.windowNumber, NSStringFromClass(w.class),
                      w.title, w.visible];
    if (w.contentView) dump(w.contentView.superview ?: w.contentView, 1, out);
  }
  [out writeToFile:@(path) atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

__attribute__((constructor)) static void bowser_rex_init(void) {
  trace("loaded pid=%d", getpid());
  // Rex's classes are ready once the main run loop starts.
  dispatch_async(dispatch_get_main_queue(), ^{ rex_bowser_install(); });
  if (getenv("BOWSER_SPACE")) {
    swizzle(NSWindow.class, @selector(orderWindow:relativeTo:), (IMP)bowser_orderWindow, &orig_orderWindow);
    swizzle(NSApplication.class, @selector(activate), (IMP)bowser_noop, &orig_activate);
    swizzle(NSApplication.class, @selector(activateIgnoringOtherApps:), (IMP)bowser_noop_bool,
            &orig_activateIgnoring);
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
