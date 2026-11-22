// bowser-cef-bench: a host that drives a producer with scripted input, for
// measuring the CEF adapter. It mounts the surface in a window like any host,
// then runs its steps in order and exits.
//
// Usage: bowser-cef-bench <ticket> [--wait S] [--scroll S] [--resize S] ...
//   --wait S    send nothing for S seconds
//   --scroll S  trackpad-style scrolling, 12 pt per frame, reversing every 3 s
//   --resize S  resize the window every frame, between 800x600 and 1100x800
// Prints "window=<id>", then "<step> begin" and "<step> end" lines with
// CACurrentMediaTime() stamps, so a script can sample CPU around each step.
// Set BOWSER_SPACE=<n> to put the window on Mission Control Space n.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include "bowser.h"

// Private CGS calls, as in the Swift host, to keep the window off the
// Spaces the user works in.
extern int CGSMainConnectionID(void);
extern CFArrayRef CGSCopyManagedDisplaySpaces(int cid);
extern void CGSAddWindowsToSpaces(int cid, CFArrayRef windows, CFArrayRef spaces);

static void move_to_space(NSWindow *w, int index) {
  NSArray *displays = CFBridgingRelease(CGSCopyManagedDisplaySpaces(CGSMainConnectionID()));
  NSMutableArray *spaces = [NSMutableArray new];
  for (NSDictionary *d in displays) [spaces addObjectsFromArray:d[@"Spaces"]];
  if (index < 1 || index > (int)spaces.count) return;
  CGSAddWindowsToSpaces(CGSMainConnectionID(), (__bridge CFArrayRef) @[ @(w.windowNumber) ],
                        (__bridge CFArrayRef) @[ spaces[index - 1][@"ManagedSpaceID"] ]);
}

@interface Bench : NSObject
@property bowser_host_t *host;
@property NSWindow *window;
@property NSMutableArray<NSArray *> *steps; // @[name, seconds]
@property CFTimeInterval stepStart;
@property CFTimeInterval scrollFlip;
@property double scrollDir;
@property BOOL scrolling;
@end

@implementation Bench

- (void)layout {
  NSView *v = self.window.contentView;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  bowser_host_layer(self.host).frame = v.bounds;
  [CATransaction commit];
  bowser_host_resize(self.host, (bowser_size_s){v.bounds.size.width, v.bounds.size.height,
                                                self.window.backingScaleFactor});
}

- (void)scroll:(int32_t)phase {
  bowser_scroll_s s = {.dy = 12 * self.scrollDir, .precise = true, .phase = phase, .x = 400, .y = 300};
  if (phase == NSEventPhaseEnded) s.dy = 0;
  bowser_host_scroll(self.host, &s);
}

- (void)frame:(CADisplayLink *)link {
  CFTimeInterval now = CACurrentMediaTime();
  if (self.stepStart == 0) {
    if (self.steps.count == 0) exit(0);
    self.stepStart = now;
    printf("%s begin %.3f\n", [self.steps[0][0] UTF8String], now);
    fflush(stdout);
  }
  NSString *step = self.steps[0][0];
  double t = now - self.stepStart;
  if (t >= [self.steps[0][1] doubleValue]) {
    if (self.scrolling) [self scroll:NSEventPhaseEnded];
    self.scrolling = NO;
    printf("%s end %.3f\n", step.UTF8String, now);
    fflush(stdout);
    [self.steps removeObjectAtIndex:0];
    self.stepStart = 0;
    return;
  }
  if ([step isEqualToString:@"scroll"]) {
    if (!self.scrolling || now - self.scrollFlip >= 3) {
      if (self.scrolling) [self scroll:NSEventPhaseEnded];
      self.scrollDir = self.scrolling ? -self.scrollDir : -1; // start by scrolling down
      self.scrollFlip = now;
      self.scrolling = YES;
      [self scroll:NSEventPhaseBegan];
    } else {
      [self scroll:NSEventPhaseChanged];
    }
  } else if ([step isEqualToString:@"resize"]) {
    double k = (1 - cos(t * M_PI)) / 2; // 0 -> 1 -> 0, once a second each way
    NSRect f = self.window.frame;
    NSRect r = [self.window frameRectForContentRect:NSMakeRect(0, 0, 800 + 300 * k, 600 + 200 * k)];
    r.origin = NSMakePoint(f.origin.x, NSMaxY(f) - r.size.height); // keep the top-left corner
    [self.window setFrame:r display:YES];
    [self layout];
  }
}

@end

static Bench *bench;

static void on_wakeup(void *ud) {
  dispatch_async(dispatch_get_main_queue(), ^{ bowser_host_tick(bench.host); });
}
static void on_detached(void *ud, bowser_host_t *h, bowser_result_e why) {
  fprintf(stderr, "bench: detached (%d)\n", why);
  exit(1);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) {
      fprintf(stderr, "usage: bowser-cef-bench <ticket> [--wait S] [--scroll S] [--resize S] ...\n");
      return 2;
    }
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    bench = [Bench new];
    bench.steps = [NSMutableArray new];
    for (int i = 2; i + 1 < argc; i += 2)
      [bench.steps addObject:@[ @(argv[i] + 2), @(atof(argv[i + 1])) ]];

    bowser_host_config_s cfg = {.size = sizeof cfg, .wakeup_cb = on_wakeup, .detached_cb = on_detached};
    bowser_host_t *host;
    if (bowser_host_attach(argv[1], &cfg, &host) != BOWSER_OK) {
      fprintf(stderr, "bench: attach: %s\n", bowser_last_error());
      return 1;
    }
    bench.host = host;

    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    view.wantsLayer = YES;
    [view.layer addSublayer:bowser_host_layer(host)];
    bench.window = [[NSWindow alloc] initWithContentRect:view.frame
                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    bench.window.title = @"bowser-cef-bench";
    bench.window.contentView = view;
    [bench.window center];
    const char *space = getenv("BOWSER_SPACE");
    if (space) move_to_space(bench.window, atoi(space));
    [bench.window orderFrontRegardless]; // never activate: that switches Spaces
    [bench layout];
    bowser_host_focus(host, true);
    printf("window=%ld\n", (long)bench.window.windowNumber);
    fflush(stdout);

    CADisplayLink *link = [view displayLinkWithTarget:bench selector:@selector(frame:)];
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [NSApp run];
  }
  return 0;
}
