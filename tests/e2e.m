// End-to-end tests: a real producer process (bowser-test --echo) and real hosts
// in this process, talking over the real socket and Mach channels. Each test
// checks what a caller can see: what the producer receives, what the host is
// told, and what the host layer shows.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include <signal.h>
#include <spawn.h>
#include <unistd.h>

#include "bowser.h"

extern char **environ;

static int failures;
#define CHECK(cond, ...)                                                                                     \
  do {                                                                                                       \
    if (!(cond)) {                                                                                           \
      failures++;                                                                                            \
      fprintf(stderr, "    FAIL %s:%d: ", __FILE__, __LINE__);                                               \
      fprintf(stderr, __VA_ARGS__);                                                                          \
      fprintf(stderr, "\n");                                                                                 \
    }                                                                                                        \
  } while (0)

static NSMutableArray<NSNumber *> *running; // producer pids, killed at exit

static void kill_running(void) {
  for (NSNumber *pid in running) kill(pid.intValue, SIGKILL);
}

static void pump(double seconds) {
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
}

// ---- Producer process ---------------------------------------------------

@interface Producer : NSObject
@property pid_t pid;
@property int out;
@property NSMutableString *buffer;
@property NSMutableArray<NSString *> *lines; // unread echo lines
@property NSMutableArray<NSString *> *tickets;
@end

@implementation Producer

+ (instancetype)start:(NSArray<NSString *> *)args tickets:(int)count {
  Producer *p = [Producer new];
  int fds[2];
  pipe(fds);
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
  posix_spawn_file_actions_addclose(&fa, fds[0]);
  NSMutableArray *all = [@[ @"build/bowser-test", @"--echo" ] mutableCopy];
  [all addObjectsFromArray:args];
  char *argv[16] = {0};
  for (NSUInteger i = 0; i < all.count && i < 15; i++) argv[i] = (char *)[all[i] UTF8String];
  pid_t pid;
  if (posix_spawn(&pid, argv[0], &fa, NULL, argv, environ) != 0) {
    fprintf(stderr, "can't start %s\n", argv[0]);
    exit(1);
  }
  close(fds[1]);
  fcntl(fds[0], F_SETFL, O_NONBLOCK);
  p.pid = pid;
  [running addObject:@(pid)];
  p.out = fds[0];
  p.buffer = [NSMutableString new];
  p.lines = [NSMutableArray new];
  p.tickets = [NSMutableArray new];
  for (int i = 0; i < count; i++) {
    NSString *t = [p nextLine:5];
    if (!t) {
      fprintf(stderr, "producer printed no ticket\n");
      exit(1);
    }
    [p.tickets addObject:t];
  }
  return p;
}

- (void)drain {
  char buf[4096];
  ssize_t n;
  while ((n = read(self.out, buf, sizeof buf)) > 0)
    [self.buffer appendString:[[NSString alloc] initWithBytes:buf length:(NSUInteger)n
                                                     encoding:NSUTF8StringEncoding]];
  NSRange nl;
  while ((nl = [self.buffer rangeOfString:@"\n"]).location != NSNotFound) {
    [self.lines addObject:[self.buffer substringToIndex:nl.location]];
    [self.buffer deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
  }
}

- (NSString *)nextLine:(double)timeout {
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while (true) {
    [self drain];
    if (self.lines.count) {
      NSString *l = self.lines[0];
      [self.lines removeObjectAtIndex:0];
      return l;
    }
    if ([end timeIntervalSinceNow] < 0) return nil;
    pump(0.005);
  }
}

// Wait for an exact line, skipping others. Returns whether it arrived.
- (BOOL)expect:(NSString *)line {
  NSString *l;
  while ((l = [self nextLine:3])) {
    if ([l isEqualToString:line]) return YES;
  }
  return NO;
}

// Read everything that arrives within `seconds`.
- (NSArray<NSString *> *)linesWithin:(double)seconds {
  NSMutableArray *got = [NSMutableArray new];
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while ([end timeIntervalSinceNow] > 0) {
    NSString *l = [self nextLine:0.02];
    if (l) [got addObject:l];
  }
  return got;
}

- (void)kill {
  kill(self.pid, SIGKILL);
  [running removeObject:@(self.pid)];
  waitpid(self.pid, NULL, 0);
  close(self.out);
}
@end

// ---- Host ---------------------------------------------------------------

@interface Host : NSObject
@property bowser_host_t *handle;
@property bowser_result_e detachedWhy;
@property BOOL detached;
@property bowser_rect_s caret;
@property BOOL gotCaret;
@property BOOL composing;
@property bowser_cursor_e cursor;
@end

@implementation Host
@end

static Host *from(void *ud) { return (__bridge Host *)ud; }

static void on_wakeup(void *ud) {
  Host *host = from(ud);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (host.handle) bowser_host_tick(host.handle);
  });
}
static void on_caret(void *ud, bowser_host_t *_, bowser_rect_s caret) {
  from(ud).caret = caret;
  from(ud).gotCaret = YES;
}
static void on_composition(void *ud, bowser_host_t *_, bool active, const bowser_rect_s *r, size_t n) {
  from(ud).composing = active;
}
static void on_cursor(void *ud, bowser_host_t *_, bowser_cursor_e c) { from(ud).cursor = c; }
static void on_detached(void *ud, bowser_host_t *_, bowser_result_e why) {
  from(ud).detached = YES;
  from(ud).detachedWhy = why;
}

static bowser_result_e attach(NSString *ticket, Host **out) {
  Host *h = [Host new];
  bowser_host_config_s cfg = {
      .size = sizeof cfg,
      .userdata = (__bridge void *)h,
      .wakeup_cb = on_wakeup,
      .caret_cb = on_caret,
      .composition_cb = on_composition,
      .cursor_cb = on_cursor,
      .detached_cb = on_detached,
  };
  bowser_host_t *handle = NULL;
  bowser_result_e rc = bowser_host_attach(ticket.UTF8String, &cfg, &handle);
  h.handle = handle;
  if (rc == BOWSER_OK) {
    // Keep the host alive while its callbacks can still fire.
    CFBridgingRetain(h);
  }
  *out = h;
  return rc;
}

static void detach(Host *h) {
  bowser_host_t *handle = h.handle;
  h.handle = NULL;
  bowser_host_detach(handle);
}

static void text(Host *h, bowser_text_kind_e kind, const char *s) {
  bowser_text_s t = {.kind = kind, .text = s, .selected_location = -1, .replacement_location = -1};
  bowser_host_text(h.handle, &t);
}

static BOOL wait_for(BOOL (^cond)(void), double seconds) {
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while (!cond()) {
    if ([end timeIntervalSinceNow] < 0) return NO;
    pump(0.01);
  }
  return YES;
}

// ---- Tests --------------------------------------------------------------

static void test_input_reaches_producer_intact(void) {
  Producer *p = [Producer start:@[] tickets:1];
  Host *h;
  CHECK(attach(p.tickets[0], &h) == BOWSER_OK, "attach: %s", bowser_last_error());
  CHECK([p expect:@"s0 attached"], "producer never saw the host");

  bowser_host_resize(h.handle, (bowser_size_s){640, 400, 2});
  bowser_host_focus(h.handle, true);
  bowser_key_s k = {.action = BOWSER_KEY_PRESS, .keycode = 0, .text = "a"};
  bowser_host_key(h.handle, &k);
  text(h, BOWSER_TEXT_SET_MARKED, "にほ");
  text(h, BOWSER_TEXT_INSERT, "日本");
  bowser_mouse_s m = {.action = BOWSER_MOUSE_DOWN, .x = 12.5, .y = 34, .click_count = 2};
  bowser_host_mouse(h.handle, &m);
  bowser_scroll_s sc = {.dy = -10, .precise = true};
  bowser_host_scroll(h.handle, &sc);

  NSArray *want = @[
    @"s0 resize 640x400@2", @"s0 focus 1", @"s0 key 0 0 a", @"s0 text 1 にほ", @"s0 text 0 日本",
    @"s0 mouse 0 0 12.5 34.0 2", @"s0 scroll 0.0 -10.0 1"
  ];
  NSMutableArray *got = [NSMutableArray new];
  NSString *l;
  while (got.count < want.count && (l = [p nextLine:3])) [got addObject:l];
  CHECK([got isEqualToArray:want], "in order and intact:\n      want %s\n      got  %s",
        [want componentsJoinedByString:@" | "].UTF8String, [got componentsJoinedByString:@" | "].UTF8String);
  detach(h);
  [p kill];
}

static void test_ticket_works_once(void) {
  Producer *p = [Producer start:@[] tickets:1];
  Host *a, *b;
  CHECK(attach(p.tickets[0], &a) == BOWSER_OK, "first use: %s", bowser_last_error());
  CHECK(attach(p.tickets[0], &b) == BOWSER_ERR_TICKET, "second use must fail with a ticket error");
  CHECK(attach(@"bowser1:/nonexistent.sock#00", &b) == BOWSER_ERR_TICKET, "a dead producer is a ticket error");
  detach(a);
  [p kill];
}

static void test_new_host_takes_over(void) {
  Producer *p = [Producer start:@[ @"--tickets", @"2" ] tickets:2];
  Host *a, *b;
  CHECK(attach(p.tickets[0], &a) == BOWSER_OK, "attach a");
  CHECK([p expect:@"s0 attached"], "a attached");
  CHECK(attach(p.tickets[1], &b) == BOWSER_OK, "attach b");
  CHECK(wait_for(^{ return a.detached; }, 3), "old host is told it was detached");
  CHECK(a.detachedWhy == BOWSER_ERR_REPLACED, "reason is REPLACED, got %d", a.detachedWhy);
  CHECK(!b.detached, "new host stays attached");

  text(a, BOWSER_TEXT_INSERT, "from-a");
  text(b, BOWSER_TEXT_INSERT, "from-b");
  NSArray *lines = [p linesWithin:0.5];
  CHECK([lines containsObject:@"s0 text 0 from-b"], "new host's input arrives");
  CHECK(![lines containsObject:@"s0 text 0 from-a"], "old host's input is dropped");
  CHECK(![lines containsObject:@"s0 detached"], "takeover is not a detach: %s",
        [lines componentsJoinedByString:@" | "].UTF8String);
  detach(a);
  detach(b);
  [p kill];
}

static void test_surfaces_are_isolated(void) {
  Producer *p = [Producer start:@[ @"--surfaces", @"2" ] tickets:2];
  Host *a, *b;
  CHECK(attach(p.tickets[0], &a) == BOWSER_OK, "attach to surface 0");
  CHECK(attach(p.tickets[1], &b) == BOWSER_OK, "attach to surface 1");
  text(a, BOWSER_TEXT_INSERT, "for-0");
  text(b, BOWSER_TEXT_INSERT, "for-1");
  detach(b);
  NSArray *lines = [p linesWithin:0.5];
  CHECK([lines containsObject:@"s0 text 0 for-0"] && [lines containsObject:@"s1 text 0 for-1"],
        "each surface gets its own input: %s", [lines componentsJoinedByString:@" | "].UTF8String);
  CHECK(![lines containsObject:@"s0 text 0 for-1"] && ![lines containsObject:@"s1 text 0 for-0"],
        "no input crosses surfaces");
  CHECK([lines containsObject:@"s1 detached"] && ![lines containsObject:@"s0 detached"],
        "detaching one host leaves the other attached");
  CHECK(!a.detached, "host 0 is not told about host 1's detach");
  detach(a);
  [p kill];
}

static void test_reattach_after_detach(void) {
  Producer *p = [Producer start:@[ @"--tickets", @"2" ] tickets:2];
  Host *a, *b;
  CHECK(attach(p.tickets[0], &a) == BOWSER_OK, "attach");
  detach(a);
  CHECK([p expect:@"s0 detached"], "producer sees the detach");
  CHECK(attach(p.tickets[1], &b) == BOWSER_OK, "reattach with a fresh ticket");
  CHECK([p expect:@"s0 attached"], "producer sees the new host");
  detach(b);
  [p kill];
}

static void test_host_learns_producer_died(void) {
  Producer *p = [Producer start:@[] tickets:1];
  Host *h;
  CHECK(attach(p.tickets[0], &h) == BOWSER_OK, "attach");
  [p kill];
  CHECK(wait_for(^{ return h.detached; }, 3), "host is told within 3 s");
  CHECK(h.detachedWhy == BOWSER_ERR_DISCONNECTED, "reason is DISCONNECTED, got %d", h.detachedWhy);
  // Input after the producer is gone must not crash or block.
  text(h, BOWSER_TEXT_INSERT, "late");
  detach(h);
}

static void test_caret_follows_text(void) {
  Producer *p = [Producer start:@[] tickets:1];
  Host *h;
  CHECK(attach(p.tickets[0], &h) == BOWSER_OK, "attach");
  CHECK(wait_for(^{ return h.gotCaret; }, 3), "new host gets the caret");
  double before = h.caret.x;
  text(h, BOWSER_TEXT_SET_MARKED, "かな");
  CHECK(wait_for(^{ return h.composing; }, 3), "host is told a composition started");
  text(h, BOWSER_TEXT_INSERT, "仮名");
  CHECK(wait_for(^{ return (BOOL)(h.caret.x > before + 10 && !h.composing); }, 3),
        "caret moves right and composition ends (x %.1f -> %.1f)", before, h.caret.x);

  bowser_mouse_s over = {.action = BOWSER_MOUSE_MOVE, .x = 100, .y = 60};
  bowser_host_mouse(h.handle, &over);
  CHECK(wait_for(^{ return (BOOL)(h.cursor == BOWSER_CURSOR_IBEAM); }, 3), "cursor is an I-beam over the field");
  detach(h);
  [p kill];
}

// Read the host layer's pixels the way a screenshot of the host would.
static BOOL host_shows_scene_background(Host *h) {
  CALayer *layer = bowser_host_layer(h.handle);
  size_t w = 64, hgt = 64;
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(NULL, w, hgt, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(cs);
  [layer renderInContext:ctx];
  uint8_t *px = CGBitmapContextGetData(ctx);
  uint8_t r = px[0], g = px[1], b = px[2];
  CGContextRelease(ctx);
  // The scene background is a dark blue (about 0.12, 0.12, 0.22).
  return b > 30 && b > r + 10 && b > g + 10 && r < 80;
}

static void test_iosurface_host_shows_producer_pixels(void) {
  Producer *p = [Producer start:@[ @"--transport", @"iosurface" ] tickets:1];
  Host *h;
  CHECK(attach(p.tickets[0], &h) == BOWSER_OK, "attach");
  CHECK(bowser_host_transport(h.handle) == BOWSER_TRANSPORT_IOSURFACE, "host uses the IOSURFACE transport");
  CALayer *layer = bowser_host_layer(h.handle);
  layer.frame = CGRectMake(0, 0, 64, 64);
  bowser_host_resize(h.handle, (bowser_size_s){64, 64, 1});
  CHECK(wait_for(^{ return host_shows_scene_background(h); }, 3), "host layer shows the producer's frame");
  detach(h);
  [p kill];
}

int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    running = [NSMutableArray new];
    atexit(kill_running);
    struct {
      const char *name;
      void (*fn)(void);
    } tests[] = {
        {"input reaches the producer intact and in order", test_input_reaches_producer_intact},
        {"a ticket works once", test_ticket_works_once},
        {"a new host takes over and the old one is told", test_new_host_takes_over},
        {"two surfaces stay isolated", test_surfaces_are_isolated},
        {"a surface accepts a new host after a detach", test_reattach_after_detach},
        {"the host learns when the producer dies", test_host_learns_producer_died},
        {"the caret and cursor follow the producer", test_caret_follows_text},
        {"an IOSURFACE host shows the producer's pixels", test_iosurface_host_shows_producer_pixels},
    };
    int failed = 0;
    for (size_t i = 0; i < sizeof tests / sizeof *tests; i++) {
      int before = failures;
      tests[i].fn();
      bool ok = failures == before;
      failed += !ok;
      printf("%s %s\n", ok ? "ok  " : "FAIL", tests[i].name);
    }
    printf("\n%d passed, %d failed\n", (int)(sizeof tests / sizeof *tests) - failed, failed);
    return failed ? 1 : 0;
  }
}
