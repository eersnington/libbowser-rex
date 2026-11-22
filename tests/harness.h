// Shared harness for the end-to-end tests: producer processes, hosts in this
// process, and a runner. Include it once, from the test's main file.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <signal.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/un.h>
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
+ (instancetype)start:(NSArray<NSString *> *)args tickets:(int)count;
+ (instancetype)start:(NSArray<NSString *> *)args tickets:(int)count env:(NSDictionary<NSString *, NSString *> *)env;
+ (instancetype)spawn:(NSArray<NSString *> *)all tickets:(int)count;
+ (instancetype)spawn:(NSArray<NSString *> *)all tickets:(int)count env:(NSDictionary<NSString *, NSString *> *)env;
- (void)stop;
@end

@implementation Producer

+ (instancetype)start:(NSArray<NSString *> *)args tickets:(int)count {
  return [self start:args tickets:count env:@{}];
}

// Start bowser-test --echo with extra arguments and environment.
+ (instancetype)start:(NSArray<NSString *> *)args tickets:(int)count env:(NSDictionary<NSString *, NSString *> *)env {
  NSMutableArray *all = [@[ @"build/bowser-test", @"--echo" ] mutableCopy];
  [all addObjectsFromArray:args];
  return [self spawn:all tickets:count env:env];
}

+ (instancetype)spawn:(NSArray<NSString *> *)all tickets:(int)count {
  return [self spawn:all tickets:count env:@{}];
}

// Start any producer: all[0] is its path. It must print `count` tickets.
+ (instancetype)spawn:(NSArray<NSString *> *)all tickets:(int)count env:(NSDictionary<NSString *, NSString *> *)env {

  Producer *p = [Producer new];
  int fds[2];
  pipe(fds);
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
  posix_spawn_file_actions_addclose(&fa, fds[0]);
  char *argv[16] = {0};
  for (NSUInteger i = 0; i < all.count && i < 15; i++) argv[i] = (char *)[all[i] UTF8String];
  NSMutableArray<NSString *> *vars = [NSMutableArray new];
  for (char **e = environ; *e; e++) [vars addObject:@(*e)];
  [env enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
    [vars addObject:[NSString stringWithFormat:@"%@=%@", k, v]];
  }];
  char **envp = calloc(vars.count + 1, sizeof *envp);
  for (NSUInteger i = 0; i < vars.count; i++) envp[i] = (char *)vars[i].UTF8String;
  pid_t pid;
  int spawned = posix_spawn(&pid, argv[0], &fa, NULL, argv, envp);
  free(envp);
  if (spawned != 0) {
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
    NSString *t = [p nextLine:10]; // CEF takes a few seconds to start
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
  return [self expect:line within:3];
}

- (BOOL)expect:(NSString *)line within:(double)seconds {
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
  NSString *l;
  while ([end timeIntervalSinceNow] > 0 && (l = [self nextLine:[end timeIntervalSinceNow]])) {
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

// Ask the producer to exit so it can clean up; kill it after 5 s.
- (void)stop {
  kill(self.pid, SIGTERM);
  for (int i = 0; i < 500; i++) {
    if (waitpid(self.pid, NULL, WNOHANG) == self.pid) {
      [running removeObject:@(self.pid)];
      close(self.out);
      return;
    }
    pump(0.01);
  }
  [self kill];
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
@property BOOL manual; // wakeups only count; the test ticks by hand
@property int wakeups;
@property BOOL detachInCaret;
@property int callbacksAfterDetach;
@end

@implementation Host
@end

static Host *from(void *ud) { return (__bridge Host *)ud; }

static void detach(Host *h);

static void on_wakeup(void *ud) {
  Host *host = from(ud);
  host.wakeups++;
  if (host.manual) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (host.handle) bowser_host_tick(host.handle);
  });
}
static void on_caret(void *ud, bowser_host_t *_, bowser_rect_s caret) {
  from(ud).caret = caret;
  from(ud).gotCaret = YES;
  if (from(ud).detachInCaret) detach(from(ud));
}
static void on_composition(void *ud, bowser_host_t *_, bool active, const bowser_rect_s *r, size_t n) {
  if (!from(ud).handle) from(ud).callbacksAfterDetach++;
  from(ud).composing = active;
}
static void on_cursor(void *ud, bowser_host_t *_, bowser_cursor_e c) {
  if (!from(ud).handle) from(ud).callbacksAfterDetach++;
  from(ud).cursor = c;
}
static void on_detached(void *ud, bowser_host_t *_, bowser_result_e why) {
  from(ud).detached = YES;
  from(ud).detachedWhy = why;
}

static bowser_result_e attach_host(NSString *ticket, Host *h);

static bowser_result_e attach(NSString *ticket, Host **out) {
  *out = [Host new];
  return attach_host(ticket, *out);
}

static bowser_result_e attach_host(NSString *ticket, Host *h) {
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
  return rc;
}

static void detach(Host *h) {
  bowser_host_t *handle = h.handle;
  h.handle = NULL;
  bowser_host_detach(handle);
}

static bowser_result_e text_to(bowser_host_t *h, bowser_text_kind_e kind, const char *s) {
  bowser_text_s t = {.kind = kind, .text = s, .selected_location = -1, .replacement_location = -1};
  return bowser_host_text(h, &t);
}

static bowser_result_e text(Host *h, bowser_text_kind_e kind, const char *s) { return text_to(h.handle, kind, s); }

static BOOL wait_for(BOOL (^cond)(void), double seconds) {
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while (!cond()) {
    if ([end timeIntervalSinceNow] < 0) return NO;
    pump(0.01);
  }
  return YES;
}

// ---- Runner -------------------------------------------------------------

typedef struct {
  const char *name;
  void (*fn)(void);
} test_case;

static int run_tests(const test_case *tests, size_t count) {
  [NSApplication sharedApplication];
  running = [NSMutableArray new];
  atexit(kill_running);
  int failed = 0;
  for (size_t i = 0; i < count; i++) {
    int before = failures;
    tests[i].fn();
    bool ok = failures == before;
    failed += !ok;
    printf("%s %s\n", ok ? "ok  " : "FAIL", tests[i].name);
  }
  printf("\n%d passed, %d failed\n", (int)count - failed, failed);
  return failed ? 1 : 0;
}
