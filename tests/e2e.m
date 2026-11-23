// End-to-end tests: a real producer process (bowser-test --echo) and real hosts
// in this process, talking over the real socket and Mach channels. Each test
// checks what a caller can see: what the producer receives, what the host is
// told, and what the host layer shows.
#include "harness.h"

// ---- Tests --------------------------------------------------------------

static void test_input_reaches_producer_intact(void) {
  Producer *p = [Producer start:@[] tickets:1];
  Host *h;
  CHECK(attach(p.tickets[0], &h) == BOWSER_OK, "attach: %s", bowser_last_error());
  CHECK([p expect:@"s0 attached"], "producer never saw the host");

  bowser_host_resize(h.handle, (bowser_size_s){640, 400, 2});
  bowser_host_set_display(h.handle, 7);
  bowser_host_focus(h.handle, true);
  bowser_key_s k = {.action = BOWSER_KEY_PRESS, .keycode = 0, .text = "a", .timestamp_ns = 42};
  bowser_host_key(h.handle, &k);
  text(h, BOWSER_TEXT_SET_MARKED, "にほ");
  text(h, BOWSER_TEXT_INSERT, "日本");
  bowser_mouse_s m = {.action = BOWSER_MOUSE_DOWN, .x = 12.5, .y = 34, .click_count = 2};
  bowser_host_mouse(h.handle, &m);
  bowser_scroll_s sc = {.dy = -10, .precise = true};
  bowser_host_scroll(h.handle, &sc);

  NSArray *want = @[
    @"s0 resize 640x400@2", @"s0 display 7", @"s0 focus 1", @"s0 key 0 0 a 42", @"s0 text 1 にほ", @"s0 text 0 日本",
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
  CHECK(attach(@"bowser3:/nonexistent.sock#00", &b) == BOWSER_ERR_TICKET, "a dead producer is a ticket error");
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

// Run work off the main thread, so a send that blocks shows up as a timeout
// instead of a hung test. Returns the seconds it took, or -1 past the limit.
static double timed(double limit, void (^work)(void)) {
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block double took = 0;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    double t0 = CACurrentMediaTime();
    work();
    took = CACurrentMediaTime() - t0;
    dispatch_semaphore_signal(done);
  });
  bool ok = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(limit * NSEC_PER_SEC))) == 0;
  return ok ? took : -1;
}

// Wait for sends that may still be blocked, while draining the producer's
// output so it can't block on it in turn. Kills the producer if they hang.
static BOOL await_sends(dispatch_semaphore_t finished, Producer *p) {
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:5];
  while (dispatch_semaphore_wait(finished, DISPATCH_TIME_NOW) != 0) {
    if ([end timeIntervalSinceNow] < 0) {
      [p kill];
      dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
      return NO;
    }
    [p drain];
    pump(0.01);
  }
  return YES;
}

static void test_stalled_producer_never_blocks_the_host(void) {
  Producer *p = [Producer start:@[] tickets:1];
  Host *h;
  CHECK(attach(p.tickets[0], &h) == BOWSER_OK, "attach");
  CHECK([p expect:@"s0 attached"], "attached");
  kill(p.pid, SIGSTOP);
  bowser_host_t *handle = h.handle;
  __block bool allOk = true;
  dispatch_semaphore_t finished = dispatch_semaphore_create(0);
  double took = timed(2, ^{
    // About 6 MB unmerged: more than a peer may leave unread.
    for (int i = 0; i < 100000; i++) {
      bowser_mouse_s m = {.action = BOWSER_MOUSE_MOVE, .x = i, .y = 1};
      allOk &= bowser_host_mouse(handle, &m) == BOWSER_OK;
    }
    allOk &= text_to(handle, BOWSER_TEXT_INSERT, "after-stall") == BOWSER_OK;
    dispatch_semaphore_signal(finished);
  });
  CHECK(took >= 0 && took < 1, "100k sends to a stopped producer return within 1 s (took %.2f s)", took);
  kill(p.pid, SIGCONT);
  if (!await_sends(finished, p)) return;
  CHECK(allOk, "every send was accepted: moves replace each other, so the queue stays small");
  CHECK([p expect:@"s0 mouse 2 0 99999.0 1.0 0"], "the newest mouse position arrives after the producer resumes");
  CHECK([p expect:@"s0 text 0 after-stall"], "input after the moves arrives, in order");
  CHECK(!h.detached, "the host stays attached");
  detach(h);
  [p kill];
}

static void test_host_drops_a_producer_that_stops_reading(void) {
  Producer *p = [Producer start:@[] tickets:1];
  Host *h;
  CHECK(attach(p.tickets[0], &h) == BOWSER_OK, "attach");
  CHECK([p expect:@"s0 attached"], "attached");
  kill(p.pid, SIGSTOP);
  bowser_host_t *handle = h.handle;
  __block bowser_result_e failure = BOWSER_OK;
  dispatch_semaphore_t finished = dispatch_semaphore_create(0);
  double took = timed(2, ^{
    char *big = malloc(100000);
    memset(big, 'x', 99999);
    big[99999] = 0;
    // Text must all arrive, so it can't be merged; 10 MB overflows the queue.
    for (int i = 0; i < 100 && !failure; i++) failure = text_to(handle, BOWSER_TEXT_INSERT, big);
    free(big);
    dispatch_semaphore_signal(finished);
  });
  CHECK(took >= 0 && took < 1, "sends return within 1 s (took %.2f s)", took);
  kill(p.pid, SIGCONT);
  if (!await_sends(finished, p)) return;
  CHECK(failure == BOWSER_ERR_STALLED, "the send that overflows returns STALLED, got %d", failure);
  CHECK(wait_for(^{ return h.detached; }, 1), "the host is told it was dropped");
  CHECK(h.detachedWhy == BOWSER_ERR_STALLED, "reason is STALLED, got %d", h.detachedWhy);
  CHECK([p expect:@"s0 detached" within:5], "the producer sees the host go once it resumes");
  detach(h);
  [p kill];
}

static void test_failed_attach_leaves_the_current_host(void) {
  Producer *p = [Producer start:@[ @"--tickets", @"2" ] tickets:2];
  Host *a, *b;
  CHECK(attach(p.tickets[0], &a) == BOWSER_OK, "attach a");
  CHECK([p expect:@"s0 attached"], "a attached");
  kill(p.pid, SIGSTOP);
  double t0 = CACurrentMediaTime();
  bowser_result_e rc = attach(p.tickets[1], &b);
  double took = CACurrentMediaTime() - t0;
  CHECK(rc == BOWSER_ERR_DISCONNECTED, "attaching to a stopped producer fails, got %d", rc);
  CHECK(took < 3.5, "within the 3 s attach deadline (took %.2f s)", took);
  kill(p.pid, SIGCONT); // now the producer answers b, which is gone
  pump(0.5);
  CHECK(!a.detached, "the failed host didn't replace the current one");
  text(a, BOWSER_TEXT_INSERT, "still-a");
  CHECK([p expect:@"s0 text 0 still-a"], "the current host's input still arrives");
  detach(a);
  [p kill];
}

static pid_t spawn_sleeper(void) {
  pid_t pid;
  char *argv[] = {"/bin/sleep", "5", NULL};
  posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);
  return pid;
}

static void reap(pid_t pid) {
  kill(pid, SIGKILL);
  waitpid(pid, NULL, 0);
}

static void test_host_children_dont_keep_it_attached(void) {
  Producer *p = [Producer start:@[] tickets:1];
  Host *h;
  CHECK(attach(p.tickets[0], &h) == BOWSER_OK, "attach");
  CHECK([p expect:@"s0 attached"], "attached");
  pid_t child = spawn_sleeper(); // like a host starting a shell
  detach(h);
  CHECK([p expect:@"s0 detached" within:1], "the producer sees the detach within 1 s, while the child lives");
  reap(child);
  [p kill];
}

static void test_producer_children_dont_hide_its_death(void) {
  Producer *p = [Producer start:@[ @"--spawn" ] tickets:1];
  Host *h;
  CHECK(attach(p.tickets[0], &h) == BOWSER_OK, "attach");
  CHECK([p expect:@"s0 attached"], "attached, and the producer started a child");
  [p kill];
  CHECK(wait_for(^{ return h.detached; }, 1), "the host learns the producer died within 1 s, while its child lives");
  detach(h);
}

static void test_expired_ticket_is_refused(void) {
  Producer *p = [Producer start:@[ @"--tickets", @"2" ] tickets:2 env:@{@"BOWSER_TICKET_TTL_MS" : @"500"}];
  Host *a, *b;
  CHECK(attach(p.tickets[0], &a) == BOWSER_OK, "a ticket works within its lifetime: %s", bowser_last_error());
  pump(0.8);
  CHECK(attach(p.tickets[1], &b) == BOWSER_ERR_TICKET, "an expired ticket is refused");
  pump(0.2);
  CHECK(!a.detached, "and doesn't take the surface from the current host");
  detach(a);
  [p kill];
}

static void test_oversize_text_is_refused_not_fatal(void) {
  Producer *p = [Producer start:@[] tickets:1];
  Host *h;
  CHECK(attach(p.tickets[0], &h) == BOWSER_OK, "attach");
  size_t n = 3 << 19; // 1.5 MB
  char *big = malloc(n + 1);
  memset(big, 'x', n);
  big[n] = 0;
  CHECK(text(h, BOWSER_TEXT_INSERT, big) == BOWSER_ERR_INVALID, "a message over 1 MiB is refused at the call");
  free(big);
  text(h, BOWSER_TEXT_INSERT, "after-big");
  CHECK([p expect:@"s0 text 0 after-big"], "the connection still carries input");
  CHECK(!h.detached, "the host stays attached");
  detach(h);
  [p kill];
}

static void test_detach_in_a_callback_ends_callbacks(void) {
  Producer *p = [Producer start:@[] tickets:1];
  Host *h = [Host new];
  h.manual = YES;
  h.detachInCaret = YES;
  CHECK(attach_host(p.tickets[0], h) == BOWSER_OK, "attach");
  bowser_mouse_s over = {.action = BOWSER_MOUSE_MOVE, .x = 100, .y = 60};
  bowser_host_mouse(h.handle, &over); // the producer answers with a cursor
  CHECK([p expect:@"s0 mouse 2 0 100.0 60.0 0"], "producer got the move");
  pump(0.2); // caret, composition, and cursor are now waiting for one tick
  bowser_host_tick(h.handle);
  CHECK(h.gotCaret && !h.handle, "the caret callback ran and detached the host");
  CHECK(h.callbacksAfterDetach == 0, "no callback runs after the detach, got %d", h.callbacksAfterDetach);
  [p kill];
}

// ---- Messages -----------------------------------------------------------

static BOOL host_got(Host *h, NSString *message) {
  return wait_for(^{ return [h.messages containsObject:message]; }, 3);
}

static void test_messages_keep_their_place_among_input(void) {
  Producer *p = [Producer start:@[] tickets:1];
  Host *h;
  CHECK(attach(p.tickets[0], &h) == BOWSER_OK, "attach");
  CHECK([p expect:@"s0 attached"], "attached");
  // Stopped, so everything below queues up in the host, where latest-wins
  // input merges. Messages must neither merge nor move.
  kill(p.pid, SIGSTOP);
  bowser_mouse_s m = {.action = BOWSER_MOUSE_MOVE, .x = 1, .y = 1};
  bowser_host_mouse(h.handle, &m);
  text(h, BOWSER_TEXT_INSERT, "a");
  bowser_host_send(h.handle, "navigate", "{\"url\":\"x\"}");
  bowser_host_mouse(h.handle, &m);
  bowser_host_send(h.handle, "back", NULL);
  bowser_host_send(h.handle, "back", NULL);
  m.x = 2;
  bowser_host_mouse(h.handle, &m);
  text(h, BOWSER_TEXT_INSERT, "b");
  bowser_host_send(h.handle, "ping", "1");
  kill(p.pid, SIGCONT);

  NSArray *want = @[
    @"s0 text 0 a", @"s0 message navigate {\"url\":\"x\"}", @"s0 message back (null)", @"s0 message back (null)",
    @"s0 text 0 b", @"s0 message ping 1"
  ];
  NSMutableArray *got = [NSMutableArray new];
  NSString *l;
  while (got.count < want.count && (l = [p nextLine:3]))
    if (![l hasPrefix:@"s0 mouse"]) [got addObject:l];
  CHECK([got isEqualToArray:want], "in order, none merged:\n      want %s\n      got  %s",
        [want componentsJoinedByString:@" | "].UTF8String, [got componentsJoinedByString:@" | "].UTF8String);
  CHECK(host_got(h, @"pong 1"), "the producer's answer reaches the host: %s",
        [h.messages componentsJoinedByString:@" | "].UTF8String);
  detach(h);
  [p kill];
}

static void test_a_later_host_gets_no_old_messages(void) {
  Producer *p = [Producer start:@[ @"--tickets", @"2" ] tickets:2];
  Host *a, *b;
  CHECK(attach(p.tickets[0], &a) == BOWSER_OK, "attach a");
  CHECK(host_got(a, @"hello (null)"), "a gets the producer's attach message");
  detach(a);
  CHECK([p expect:@"s0 send missed failed 4"], "a send with no host attached fails with DISCONNECTED");
  CHECK(attach(p.tickets[1], &b) == BOWSER_OK, "attach b");
  CHECK(host_got(b, @"hello (null)"), "b gets the message sent on its attach");
  pump(0.3);
  CHECK([b.messages isEqualToArray:@[ @"hello (null)" ]], "and nothing sent before it attached: %s",
        [b.messages componentsJoinedByString:@" | "].UTF8String);
  detach(b);
  [p kill];
}

static void test_bad_messages_are_refused_not_fatal(void) {
  Producer *p = [Producer start:@[] tickets:1];
  Host *h;
  CHECK(attach(p.tickets[0], &h) == BOWSER_OK, "attach");
  char *big = malloc(BOWSER_MESSAGE_MAX + 2);
  memset(big, 'x', BOWSER_MESSAGE_MAX + 1);
  big[BOWSER_MESSAGE_MAX + 1] = 0;
  CHECK(bowser_host_send(h.handle, "big", big) == BOWSER_ERR_INVALID, "a body over BOWSER_MESSAGE_MAX is refused");
  big[BOWSER_MESSAGE_MAX] = 0;
  CHECK(bowser_host_send(h.handle, "max", big) == BOWSER_OK, "a body of exactly BOWSER_MESSAGE_MAX is sent");
  free(big);
  CHECK(bowser_host_send(h.handle, "two words", NULL) == BOWSER_ERR_INVALID, "a name that isn't an identifier is refused");
  CHECK(bowser_host_send(h.handle, "", NULL) == BOWSER_ERR_INVALID, "an empty name is refused");

  bowser_host_send(h.handle, "grow", @(BOWSER_MESSAGE_MAX + 1).stringValue.UTF8String);
  CHECK([p expect:@"s0 send grown failed 1"], "the producer's oversize send is refused at its call");
  bowser_host_send(h.handle, "grow", @(BOWSER_MESSAGE_MAX).stringValue.UTF8String);
  CHECK(wait_for(^{
          for (NSString *m in h.messages)
            if ([m hasPrefix:@"grown "] && m.length == 6 + BOWSER_MESSAGE_MAX) return YES;
          return NO;
        }, 3),
        "a full-size message reaches the host whole");
  bowser_host_send(h.handle, "ping", "after");
  CHECK(host_got(h, @"pong after"), "both directions still work");
  CHECK(!h.detached, "the host stays attached");
  detach(h);
  [p kill];
}

static void test_a_host_built_before_messages_still_works(void) {
  Producer *p = [Producer start:@[] tickets:1];
  Host *h = [Host new];
  // An older caller's struct ends at detached_cb. Whatever follows it in
  // memory must never be read as message_cb.
  bowser_host_config_s old = {
      .size = BOWSER_HOST_CONFIG_MIN_SIZE,
      .userdata = (__bridge void *)h,
      .wakeup_cb = on_wakeup,
      .detached_cb = on_detached,
      .message_cb = (void *)(uintptr_t)0xdead,
  };
  bowser_host_t *handle = NULL;
  CHECK(bowser_host_attach(p.tickets[0].UTF8String, &old, &handle) == BOWSER_OK, "attach with the old size: %s",
        bowser_last_error());
  if (!handle) {
    [p kill];
    return;
  }
  h.handle = handle;
  CFBridgingRetain(h);
  bowser_host_send(handle, "ping", "old");
  CHECK([p expect:@"s0 message ping old"], "its messages reach the producer");
  pump(0.3); // the producer's hello and pong arrive and are dropped
  [p kill];
  CHECK(wait_for(^{ return h.detached; }, 3), "and it still hears that the producer died");
  detach(h);
}

// ---- In-process producer, for checks only the producer side can see -----

@interface Local : NSObject
@property bowser_producer_t *producer;
@property bowser_surface_t *surface;
@property int attaches;
@end

@implementation Local
@end

static void local_wakeup(void *ud) {
  Local *l = (__bridge Local *)ud;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (l.producer) bowser_producer_tick(l.producer);
  });
}
static void local_attach(void *ud, bowser_surface_t *s, bool attached) {
  if (attached) ((__bridge Local *)ud).attaches++;
}

static Local *local_start(void) {
  Local *l = [Local new];
  bowser_producer_config_s cfg = {
      .size = sizeof cfg,
      .transport = BOWSER_TRANSPORT_IOSURFACE,
      .userdata = (__bridge void *)l,
      .wakeup_cb = local_wakeup,
      .attach_cb = local_attach,
  };
  bowser_producer_t *producer;
  bowser_surface_t *surface;
  if (bowser_producer_new(&cfg, &producer) != BOWSER_OK ||
      bowser_surface_new(producer, (bowser_size_s){64, 64, 1}, &surface) != BOWSER_OK) {
    fprintf(stderr, "in-process producer: %s\n", bowser_last_error());
    exit(1);
  }
  l.producer = producer;
  l.surface = surface;
  CFBridgingRetain(l);
  return l;
}

static void local_free(Local *l) {
  bowser_surface_free(l.surface);
  bowser_producer_t *producer = l.producer;
  l.producer = NULL;
  bowser_producer_free(producer);
}

static NSString *local_ticket(Local *l) {
  char *t = bowser_surface_ticket(l.surface);
  NSString *s = @(t);
  bowser_string_free(t);
  return s;
}

static IOSurfaceRef make_iosurface(void) {
  return IOSurfaceCreate((__bridge CFDictionaryRef) @{
    (id)kIOSurfaceWidth : @64,
    (id)kIOSurfaceHeight : @64,
    (id)kIOSurfaceBytesPerElement : @4,
    (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA'),
  });
}

// Present until a subscribed host takes it, then wait for the host to have it.
static BOOL deliver(Local *l, Host *h, IOSurfaceRef frame) {
  int before = h.wakeups;
  bowser_rect_s all = {0, 0, 64, 64};
  return wait_for(^{ return (BOOL)(bowser_surface_present(l.surface, frame, all) == BOWSER_OK); }, 2) &&
         wait_for(^{ return (BOOL)(h.wakeups > before); }, 2);
}

static void test_host_keeps_its_frames_in_use(void) {
  Local *l = local_start();
  Host *h = [Host new];
  h.manual = YES;
  CHECK(attach_host(local_ticket(l), h) == BOWSER_OK, "attach: %s", bowser_last_error());
  CHECK(wait_for(^{ return (BOOL)(l.attaches == 1); }, 2), "producer sees the host");
  IOSurfaceRef a = make_iosurface(), b = make_iosurface();

  CHECK(deliver(l, h, a), "host gets frame a");
  CHECK(IOSurfaceIsInUse(a), "a frame the host holds but hasn't shown is in use, so the producer won't draw into it");
  bowser_host_tick(h.handle);
  CHECK(IOSurfaceIsInUse(a), "the frame on screen is in use");
  CHECK(deliver(l, h, b), "host gets frame b");
  bowser_host_tick(h.handle);
  CHECK(!IOSurfaceIsInUse(a), "a replaced frame is free to draw into again");
  CHECK(IOSurfaceIsInUse(b), "the new frame is in use");
  detach(h);
  CHECK(!IOSurfaceIsInUse(b), "a detached host frees its frames");
  CFRelease(a);
  CFRelease(b);
  local_free(l);
}

// Do the handshake by hand to learn the producer's Mach frame service name.
static NSString *frame_service(NSString *ticket) {
  NSString *rest = [ticket substringFromIndex:strlen("bowser3:")];
  NSRange hash = [rest rangeOfString:@"#" options:NSBackwardsSearch];
  NSString *path = [rest substringToIndex:hash.location], *token = [rest substringFromIndex:hash.location + 1];
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un addr = {.sun_family = AF_UNIX};
  strlcpy(addr.sun_path, path.UTF8String, sizeof addr.sun_path);
  if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) return nil;
  uint32_t n = (uint32_t)token.length, len = 4 + n;
  uint16_t type = 1; // HELLO
  NSMutableData *hello = [NSMutableData new];
  [hello appendBytes:&len length:4];
  [hello appendBytes:&type length:2];
  [hello appendBytes:&n length:4];
  [hello appendBytes:token.UTF8String length:n];
  write(fd, hello.bytes, hello.length);
  uint8_t buf[512];
  ssize_t got = read(fd, buf, sizeof buf); // WELCOME: u32 transport, u32 context, 3 f64, str service, u64
  close(fd);
  size_t at = 6 + 4 + 4 + 24;
  if (got < (ssize_t)(at + 4)) return nil;
  memcpy(&n, buf + at, 4);
  if (at + 4 + n > (size_t)got) return nil;
  return [[NSString alloc] initWithBytes:buf + at + 4 length:n encoding:NSUTF8StringEncoding];
}

typedef struct {
  mach_msg_header_t header;
  mach_msg_body_t body;
  mach_msg_port_descriptor_t port;
  uint64_t value;
} sub_msg;

static int dead_names(void) {
  mach_port_name_array_t names;
  mach_port_type_array_t types;
  mach_msg_type_number_t n, tn;
  mach_port_names(mach_task_self(), &names, &n, &types, &tn);
  int dead = 0;
  for (mach_msg_type_number_t i = 0; i < tn; i++) dead += (types[i] & MACH_PORT_TYPE_DEAD_NAME) != 0;
  vm_deallocate(mach_task_self(), (vm_address_t)names, n * sizeof *names);
  vm_deallocate(mach_task_self(), (vm_address_t)types, tn * sizeof *types);
  return dead;
}

static void test_frame_service_survives_hostile_messages(void) {
  Local *l = local_start();
  NSString *service = frame_service(local_ticket(l));
  CHECK(service != nil, "learned the frame service");
  mach_port_t server = MACH_PORT_NULL;
  CHECK(bootstrap_look_up(bootstrap_port, service.UTF8String, &server) == KERN_SUCCESS, "look up the service");

  // Each message carries rights to a fresh port of ours. The producer runs in
  // this task, so any right it keeps lingers as a dead name once we destroy
  // the port.
  int deadBefore = dead_names();
  enum { ROUNDS = 40 };
  NSMutableArray<NSNumber *> *ports = [NSMutableArray new];
  for (int i = 0; i < ROUNDS * 5; i++) {
    mach_port_t mine;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &mine);
    [ports addObject:@(mine)];
    sub_msg m = {0};
    m.header.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE, 0, 0);
    m.header.msgh_size = sizeof m;
    m.header.msgh_remote_port = server;
    m.header.msgh_local_port = mine; // a reply right the producer must release
    m.header.msgh_id = 0x626f7701;   // SUBSCRIBE
    m.value = arc4random();          // no such nonce
    switch (i % 5) {
    case 0: // well formed, unknown nonce
    case 1: // wrong id
    case 2: // the right is send-once, not send
      m.header.msgh_bits |= MACH_MSGH_BITS_COMPLEX;
      m.body.msgh_descriptor_count = 1;
      m.port.name = mine;
      m.port.disposition = i % 5 == 2 ? MACH_MSG_TYPE_MAKE_SEND_ONCE : MACH_MSG_TYPE_MAKE_SEND;
      m.port.type = MACH_MSG_PORT_DESCRIPTOR;
      if (i % 5 == 1) m.header.msgh_id = 0x626f7702;
      break;
    case 3: // not complex at all
      break;
    case 4: { // memory where a port should be
      mach_msg_ool_descriptor_t *ool = (mach_msg_ool_descriptor_t *)&m.port;
      static char page[4096];
      m.header.msgh_bits |= MACH_MSGH_BITS_COMPLEX;
      m.body.msgh_descriptor_count = 1;
      ool->address = page;
      ool->size = sizeof page;
      ool->copy = MACH_MSG_VIRTUAL_COPY;
      ool->type = MACH_MSG_OOL_DESCRIPTOR;
      break;
    }
    }
    mach_msg(&m.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
  }
  // The producer handles messages in order. When it releases the reply right
  // of the last one, the kernel tells that port, so all have been handled.
  mach_port_t last = (mach_port_t)ports.lastObject.unsignedIntValue;
  struct {
    mach_msg_header_t header;
    mach_msg_max_trailer_t trailer;
  } note;
  kern_return_t kr = mach_msg(&note.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_LARGE, 0, sizeof note, last,
                              2000, MACH_PORT_NULL);
  CHECK(kr == KERN_SUCCESS || kr == MACH_RCV_TOO_LARGE, "producer handled the messages and released their replies");
  if (kr == KERN_SUCCESS) mach_msg_destroy(&note.header);

  for (NSNumber *n in ports) mach_port_mod_refs(mach_task_self(), n.unsignedIntValue, MACH_PORT_RIGHT_RECEIVE, -1);
  int leaked = dead_names() - deadBefore;
  CHECK(leaked <= 0, "the producer keeps no rights from bad messages, kept %d of %d", leaked, ROUNDS * 5);
  mach_port_deallocate(mach_task_self(), server);

  Host *h = [Host new];
  h.manual = YES;
  CHECK(attach_host(local_ticket(l), h) == BOWSER_OK, "a real host still attaches");
  IOSurfaceRef frame = make_iosurface();
  CHECK(deliver(l, h, frame), "and still gets frames");
  detach(h);
  CFRelease(frame);
  local_free(l);
}

int main(void) {
  @autoreleasepool {
    static const test_case tests[] = {
        {"input reaches the producer intact and in order", test_input_reaches_producer_intact},
        {"a ticket works once", test_ticket_works_once},
        {"a new host takes over and the old one is told", test_new_host_takes_over},
        {"two surfaces stay isolated", test_surfaces_are_isolated},
        {"a surface accepts a new host after a detach", test_reattach_after_detach},
        {"the host learns when the producer dies", test_host_learns_producer_died},
        {"the caret and cursor follow the producer", test_caret_follows_text},
        {"an IOSURFACE host shows the producer's pixels", test_iosurface_host_shows_producer_pixels},
        {"a stopped producer never blocks the host", test_stalled_producer_never_blocks_the_host},
        {"a failed attach leaves the current host attached", test_failed_attach_leaves_the_current_host},
        {"the host drops a producer that stops reading", test_host_drops_a_producer_that_stops_reading},
        {"a host's child process doesn't keep it attached", test_host_children_dont_keep_it_attached},
        {"a producer's child process doesn't hide its death", test_producer_children_dont_hide_its_death},
        {"an expired ticket is refused", test_expired_ticket_is_refused},
        {"oversize text is refused, not fatal", test_oversize_text_is_refused_not_fatal},
        {"detaching in a callback ends the callbacks", test_detach_in_a_callback_ends_callbacks},
        {"messages keep their place among input", test_messages_keep_their_place_among_input},
        {"a host that attaches later gets no old messages", test_a_later_host_gets_no_old_messages},
        {"bad messages are refused, not fatal", test_bad_messages_are_refused_not_fatal},
        {"a host built before messages still works", test_a_host_built_before_messages_still_works},
        {"a host keeps its frames in use until replaced", test_host_keeps_its_frames_in_use},
        {"the frame service survives hostile messages", test_frame_service_survives_hostile_messages},
    };
    return run_tests(tests, sizeof tests / sizeof *tests);
  }
}
