// bowser-cef-probe: a host that measures what a user would see. It mounts a
// surface in a window, captures that window with ScreenCaptureKit, and times
// frames by when the window server displayed them. The method doesn't depend
// on how the producer renders, so it compares OSR with windowed fairly.
//
// Usage: bowser-cef-probe <ticket> --producer PID [steps...]
//   --wait S       idle for S seconds
//   --frames S     record displayed frames for S seconds
//   --scroll S     trackpad-style scrolling (12 pt per display frame), recording frames
//   --resize S     resize the window every display frame, recording frames and gutters
//   --keys N       N key presses; each one recolors the page. Input-to-display latency.
//   --clicks N     the same with mouse down/up
// Each step prints one line: `step <name> key=value ...`. Times are ms.
// The window is invisible but on screen; see main() for why.
//
// Latency: the probe stamps each input with CLOCK_UPTIME_RAW (the ABI's
// timestamp_ns), then finds the first captured frame whose center pixel has
// the color the page sets on that input. ScreenCaptureKit stamps frames with
// the mach time the window server displayed them (SCStreamFrameInfoDisplayTime),
// which is the same clock. So latency = displayTime - input time: input to
// the composited frame, short only of the panel's scanout.
#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <IOKit/IOKitLib.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
#include <sys/sysctl.h>

#include "bowser.h"

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static uint64_t mach_to_ns(uint64_t t) {
  static mach_timebase_info_data_t tb;
  if (!tb.denom) mach_timebase_info(&tb);
  return t * tb.numer / tb.denom;
}

// ---- Process accounting -----------------------------------------------
//
// CPU and energy from proc_pid_rusage, GPU time from the IOKit accelerator
// user clients (what Activity Monitor's GPU column reads), per process kind.

enum { K_BROWSER, K_GPU, K_RENDERER, K_UTILITY, K_HOST, K_WINDOWSERVER, K_COUNT };
static const char *kKindNames[K_COUNT] = {"browser", "gpu", "renderer", "utility", "host", "windowserver"};

typedef struct {
  double cpu_s[K_COUNT], gpu_s[K_COUNT], energy_j[K_COUNT], footprint_mb[K_COUNT];
  uint64_t at_ns;
} usage_s;

static pid_t g_producer;
static pid_t windowserver_pid(void) {
  static pid_t ws = -1;
  if (ws >= 0) return ws;
  FILE *f = popen("pgrep -x WindowServer", "r");
  ws = 0;
  if (f) {
    if (fscanf(f, "%d", &ws) != 1) ws = 0;
    pclose(f);
  }
  return ws;
}

// WindowServer belongs to another user, so proc_pid_rusage can't read it;
// ps is setuid and can. Centisecond resolution.
static double windowserver_cpu_s(void) {
  char cmd[64];
  snprintf(cmd, sizeof cmd, "ps -o time= -p %d", windowserver_pid());
  FILE *f = popen(cmd, "r");
  double m = 0, sec = 0;
  if (f) {
    if (fscanf(f, "%lf:%lf", &m, &sec) != 2) m = sec = 0;
    pclose(f);
  }
  return m * 60 + sec;
}

// Chromium names a child's job in its arguments (--type=gpu-process), not in
// which helper app it starts.
static int kind_of(pid_t pid) {
  if (pid == g_producer) return K_BROWSER;
  if (pid == getpid()) return K_HOST;
  if (pid == windowserver_pid()) return K_WINDOWSERVER;
  static NSMutableDictionary<NSNumber *, NSNumber *> *cache;
  if (!cache) cache = [NSMutableDictionary new];
  if (cache[@(pid)]) return cache[@(pid)].intValue;
  int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
  size_t len = 0;
  if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0 || len == 0) return -1;
  char *buf = malloc(len);
  int kind = K_UTILITY;
  if (sysctl(mib, 3, buf, &len, NULL, 0) == 0) {
    for (size_t i = sizeof(int); i < len; i += strlen(buf + i) + 1) {
      if (!strcmp(buf + i, "--type=gpu-process")) kind = K_GPU;
      if (!strcmp(buf + i, "--type=renderer")) kind = K_RENDERER;
    }
  }
  free(buf);
  cache[@(pid)] = @(kind);
  return kind;
}

static NSArray<NSNumber *> *watched_pids(void) {
  NSMutableArray *out = [NSMutableArray arrayWithObjects:@(g_producer), @(getpid()), nil];
  if (windowserver_pid()) [out addObject:@(windowserver_pid())];
  pid_t kids[256];
  int n = proc_listchildpids(g_producer, kids, sizeof kids);
  for (int i = 0; i < n && i < 256; i++) [out addObject:@(kids[i])];
  return out;
}

// Accumulated GPU nanoseconds per pid.
static NSDictionary<NSNumber *, NSNumber *> *gpu_times(void) {
  NSMutableDictionary *out = [NSMutableDictionary new];
  io_iterator_t it;
  if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS)
    return out;
  io_object_t accel;
  while ((accel = IOIteratorNext(it))) {
    io_iterator_t kids;
    if (IORegistryEntryGetChildIterator(accel, kIOServicePlane, &kids) == KERN_SUCCESS) {
      io_object_t c;
      while ((c = IOIteratorNext(kids))) {
        NSString *creator = CFBridgingRelease(IORegistryEntryCreateCFProperty(c, CFSTR("IOUserClientCreator"), NULL, 0));
        NSArray *usage = CFBridgingRelease(IORegistryEntryCreateCFProperty(c, CFSTR("AppUsage"), NULL, 0));
        int pid = 0;
        if (creator && sscanf(creator.UTF8String, "pid %d", &pid) == 1 && [usage isKindOfClass:NSArray.class]) {
          double sum = [out[@(pid)] doubleValue];
          for (NSDictionary *u in usage) sum += [u[@"accumulatedGPUTime"] doubleValue];
          out[@(pid)] = @(sum);
        }
        IOObjectRelease(c);
      }
      IOObjectRelease(kids);
    }
    IOObjectRelease(accel);
  }
  IOObjectRelease(it);
  return out;
}

static usage_s sample_usage(void) {
  usage_s u = {.at_ns = now_ns()};
  NSDictionary *gpu = gpu_times();
  for (NSNumber *p in watched_pids()) {
    pid_t pid = p.intValue;
    int k = kind_of(pid);
    if (k < 0) continue;
    struct rusage_info_v6 ri;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ri) == 0) {
      u.cpu_s[k] += mach_to_ns(ri.ri_user_time + ri.ri_system_time) / 1e9;
      u.energy_j[k] += ri.ri_energy_nj / 1e9;
      u.footprint_mb[k] += ri.ri_phys_footprint / 1048576.0;
    }
    u.gpu_s[k] += [gpu[p] doubleValue] / 1e9;
  }
  u.cpu_s[K_WINDOWSERVER] = windowserver_cpu_s();
  return u;
}

static void print_usage(usage_s a, usage_s b) {
  double wall = (b.at_ns - a.at_ns) / 1e9;
  for (int k = 0; k < K_COUNT; k++) {
    printf(" %s_cpu=%.1f %s_gpu=%.1f %s_mw=%.0f %s_mb=%.0f", kKindNames[k], (b.cpu_s[k] - a.cpu_s[k]) / wall * 100,
           kKindNames[k], (b.gpu_s[k] - a.gpu_s[k]) / wall * 100, kKindNames[k],
           (b.energy_j[k] - a.energy_j[k]) / wall * 1000, kKindNames[k], b.footprint_mb[k]);
  }
}

// ---- Stats -------------------------------------------------------------

static double percentile(NSArray<NSNumber *> *xs, double p) {
  if (!xs.count) return NAN;
  NSArray *s = [xs sortedArrayUsingSelector:@selector(compare:)];
  NSUInteger i = (NSUInteger)fmin(s.count - 1, floor(p * s.count));
  return [s[i] doubleValue];
}

// ---- Capture -------------------------------------------------------------

typedef struct { uint8_t r, g, b; } rgb;

// The latency page flips between red and blue. Captures come color-managed,
// so classify by the dominant channel, not exact values.
typedef enum { C_OTHER, C_RED, C_BLUE } flip_e;
// Captures come premultiplied by the window's alpha (see main), so a red page
// reads about (2, 0, 0). Compare channels, not levels.
static flip_e classify(rgb c) {
  if (c.r >= 2 && c.r > c.b + 1 && c.r > c.g + 1) return C_RED;
  if (c.b >= 2 && c.b > c.r + 1 && c.b > c.g + 1) return C_BLUE;
  return C_OTHER;
}
static BOOL magenta(rgb c) { return c.r >= 2 && c.b >= 2 && abs(c.r - c.b) <= 1 && c.g * 2 < c.r; }

@interface Probe : NSObject <SCStreamOutput, SCStreamDelegate>
@property bowser_host_t *host;
@property NSWindow *window;
@property NSView *view;
@property SCStream *stream;
@property NSMutableArray<NSArray *> *steps; // @[name, value]
@property CFTimeInterval stepStart;
@property usage_s usageStart;
// Recording, written on the capture queue and read on main after the step.
@property NSMutableArray<NSNumber *> *displayTimes; // ns of complete frames
@property int gutterFrames;
@property double scrollDir;
@property CFTimeInterval scrollFlip;
@property BOOL scrolling;
// Latency probe
@property int trial, trials;
@property BOOL waiting;        // for the frame that shows trial `trial`
@property uint64_t inputNs;
@property NSMutableArray<NSNumber *> *latencies;
@property int misses;
@property flip_e shown;  // the latest captured color
@property flip_e before; // the color when the trial's input was sent
@property uint64_t lastSignature;
@property int stepNumber;
@end

static Probe *probe;
// The captured area: the window's top-left corner and the largest size the
// resize step makes. view_w/h: the window's current size, for the capture queue.
static const double kCaptureW = 1100, kCaptureH = 800;
static _Atomic double view_w = 800, view_h = 600;
static dispatch_queue_t capture_queue;
static volatile bool recording;


static rgb pixel_at(uint8_t *base, size_t stride, size_t x, size_t y) {
  uint8_t *p = base + y * stride + x * 4; // BGRA
  return (rgb){p[2], p[1], p[0]};
}

@implementation Probe

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
  if (type != SCStreamOutputTypeScreen) return;
  CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
  if (!atts || CFArrayGetCount(atts) == 0) return;
  NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(atts, 0);
  if ([info[SCStreamFrameInfoStatus] integerValue] != SCFrameStatusComplete) return;
  uint64_t shown = mach_to_ns([info[SCStreamFrameInfoDisplayTime] unsignedLongLongValue]);
  CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
  if (!pb) return;
  CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  uint8_t *base = CVPixelBufferGetBaseAddress(pb);
  size_t stride = CVPixelBufferGetBytesPerRow(pb), w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
  rgb center = pixel_at(base, stride, w / 2, h / 2);
  // A cheap signature of a 48x48 grid: a frame whose signature changed is new
  // content, not the capture repeating an unchanged window.
  uint64_t sig = 1469598103934665603ull;
  for (size_t y = 0; y < 48; y++)
    for (size_t x = 0; x < 48; x++) {
      uint8_t *p = base + (h * (2 * y + 1) / 96) * stride + (w * (2 * x + 1) / 96) * 4;
      sig = (sig ^ (p[0] | p[1] << 8 | p[2] << 16)) * 1099511628211ull;
    }
  // A gutter: the window's magenta background shows at the right or bottom
  // edge, where the producer's frame doesn't reach yet.
  // The capture covers the largest size the resize step reaches; the window
  // keeps its top-left corner, so its edges are at the current size.
  BOOL gutter = NO;
  size_t ex = (size_t)fmin(w - 1, view_w * w / kCaptureW) - 2, ey = (size_t)fmin(h - 1, view_h * h / kCaptureH) - 2;
  for (size_t y = ey / 8; y < ey; y += ey / 8) gutter |= magenta(pixel_at(base, stride, ex, y));
  for (size_t x = ex / 8; x < ex; x += ex / 8) gutter |= magenta(pixel_at(base, stride, x, ey));
  CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);

  dispatch_async(dispatch_get_main_queue(), ^{
    BOOL changed = sig != self.lastSignature;
    self.lastSignature = sig;
    flip_e color = classify(center);
    if (changed && getenv("BOWSER_PROBE_DEBUG")) fprintf(stderr, "frame %llu center %d,%d,%d\n", shown, center.r, center.g, center.b);
    if (recording && changed) {
      [self.displayTimes addObject:@(shown)];
      if (gutter) self.gutterFrames++;
    }
    if (!self.waiting) self.shown = color;
    if (self.waiting && shown > self.inputNs && color != C_OTHER && color != self.before) {
      self.shown = color;
      self.waiting = NO;
      [self.latencies addObject:@((shown - self.inputNs) / 1e6)];
      [self scheduleTrial];
    }
  });
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
  fprintf(stderr, "probe: capture stopped: %s\n", error.localizedDescription.UTF8String);
  exit(1);
}

- (void)startCapture {
  [SCShareableContent
      getShareableContentExcludingDesktopWindows:NO
                             onScreenWindowsOnly:NO
                               completionHandler:^(SCShareableContent *content, NSError *error) {
                                 SCWindow *mine = nil;
                                 for (SCWindow *w in content.windows)
                                   if (w.windowID == (CGWindowID)self.window.windowNumber) mine = w;
                                 if (!mine) {
                                   fprintf(stderr, "probe: can't capture: %s\n",
                                           error ? error.localizedDescription.UTF8String : "window not listed");
                                   exit(1);
                                 }
                                 // Display capture, limited to this window: the
                                 // pixels the display composited. (A window
                                 // capture is rendered on its own schedule.)
                                 SCDisplay *display = content.displays.firstObject;
                                 for (SCDisplay *d in content.displays)
                                   if (CGRectContainsRect(d.frame, mine.frame)) display = d;
                                 SCContentFilter *f = [[SCContentFilter alloc] initWithDisplay:display
                                                                             includingWindows:@[ mine ]];
                                 SCStreamConfiguration *c = [SCStreamConfiguration new];
                                 CGRect r = CGRectMake(mine.frame.origin.x, mine.frame.origin.y, kCaptureW, kCaptureH);
                                 c.sourceRect = CGRectOffset(r, -display.frame.origin.x, -display.frame.origin.y);
                                 // Small: only a few pixels are read, and capture
                                 // costs the window server the same in both modes.
                                 c.width = (size_t)kCaptureW / 2;
                                 c.height = (size_t)kCaptureH / 2;
                                 c.minimumFrameInterval = CMTimeMake(1, 240);
                                 c.queueDepth = 8;
                                 c.pixelFormat = kCVPixelFormatType_32BGRA;
                                 c.showsCursor = NO;
                                 c.ignoreShadowsSingleWindow = YES;
                                 self.stream = [[SCStream alloc] initWithFilter:f configuration:c delegate:self];
                                 NSError *e = nil;
                                 [self.stream addStreamOutput:self
                                                         type:SCStreamOutputTypeScreen
                                           sampleHandlerQueue:capture_queue
                                                        error:&e];
                                 [self.stream startCaptureWithCompletionHandler:^(NSError *err) {
                                   if (err) {
                                     fprintf(stderr, "probe: capture: %s\n", err.localizedDescription.UTF8String);
                                     exit(1);
                                   }
                                   dispatch_async(dispatch_get_main_queue(), ^{ [self startLink]; });
                                 }];
                               }];
}

- (void)startLink {
  CADisplayLink *link = [self.view displayLinkWithTarget:self selector:@selector(frame:)];
  [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)layout {
  view_w = self.view.bounds.size.width;
  view_h = self.view.bounds.size.height;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  bowser_host_layer(self.host).frame = self.view.bounds;
  [CATransaction commit];
  bowser_host_resize(self.host, (bowser_size_s){self.view.bounds.size.width, self.view.bounds.size.height,
                                                self.window.backingScaleFactor});
}

- (void)scroll:(int32_t)phase {
  bowser_scroll_s s = {.dy = 12 * self.scrollDir, .precise = true, .phase = phase, .x = 400, .y = 300,
                       .timestamp_ns = now_ns()};
  if (phase == NSEventPhaseEnded) s.dy = 0;
  bowser_host_scroll(self.host, &s);
}

- (void)scheduleTrial {
  if (self.trial >= self.trials) return;
  // A random gap, so inputs land at every phase of the display's refresh.
  double gap = 0.12 + arc4random_uniform(100) / 1000.0;
  int step = self.stepNumber; // a trial must not leak into the next step
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gap * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (self.stepNumber == step) [self sendTrial];
  });
}

- (void)sendTrial {
  if (self.trial >= self.trials) return;
  self.trial++;
  BOOL keys = [self.steps[0][0] isEqualToString:@"keys"];
  uint64_t t = now_ns();
  self.inputNs = t;
  self.before = self.shown;
  self.waiting = YES;
  if (keys) {
    bowser_key_s k = {.action = BOWSER_KEY_PRESS, .keycode = 0, .text = "a", .unmodified_text = "a",
                      .timestamp_ns = t};
    bowser_host_key(self.host, &k);
    bowser_text_s txt = {.kind = BOWSER_TEXT_INSERT, .text = "a", .selected_location = -1, .replacement_location = -1};
    bowser_host_text(self.host, &txt);
    k.action = BOWSER_KEY_RELEASE;
    k.timestamp_ns = now_ns();
    bowser_host_key(self.host, &k);
  } else {
    bowser_mouse_s m = {.action = BOWSER_MOUSE_DOWN, .x = 100, .y = 100, .click_count = 1, .timestamp_ns = t};
    bowser_host_mouse(self.host, &m);
    m.action = BOWSER_MOUSE_UP;
    m.timestamp_ns = now_ns();
    bowser_host_mouse(self.host, &m);
  }
  // A frame that never shows counts as a miss, not as a latency.
  int trial = self.trial;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (self.waiting && self.trial == trial) {
      self.waiting = NO;
      self.misses++;
      [self scheduleTrial];
    }
  });
}

- (void)beginStep {
  NSString *name = self.steps[0][0];
  self.stepNumber++;
  self.stepStart = CACurrentMediaTime();
  self.displayTimes = [NSMutableArray new];
  self.gutterFrames = 0;
  self.usageStart = sample_usage();
  recording = ![name isEqualToString:@"wait"];
  if ([name isEqualToString:@"keys"] || [name isEqualToString:@"clicks"]) {
    self.trial = 0;
    self.trials = [self.steps[0][1] intValue];
    self.latencies = [NSMutableArray new];
    self.misses = 0;
    [self scheduleTrial];
  }
}

- (BOOL)stepDone:(CFTimeInterval)now {
  NSString *name = self.steps[0][0];
  if ([name isEqualToString:@"keys"] || [name isEqualToString:@"clicks"])
    return self.trial >= self.trials && !self.waiting;
  return now - self.stepStart >= [self.steps[0][1] doubleValue];
}

- (void)endStep {
  NSString *name = self.steps[0][0];
  recording = false;
  usage_s end = sample_usage();
  printf("step %s", name.UTF8String);
  NSMutableArray *gaps = [NSMutableArray new];
  for (NSUInteger i = 1; i < self.displayTimes.count; i++)
    [gaps addObject:@(([self.displayTimes[i] doubleValue] - [self.displayTimes[i - 1] doubleValue]) / 1e6)];
  double wall = (end.at_ns - self.usageStart.at_ns) / 1e9;
  if (![name isEqualToString:@"wait"]) {
    printf(" fps=%.1f frame_p50=%.2f frame_p99=%.2f frame_max=%.2f frames=%lu", self.displayTimes.count / wall,
           percentile(gaps, 0.5), percentile(gaps, 0.99), percentile(gaps, 1), (unsigned long)self.displayTimes.count);
  }
  if ([name isEqualToString:@"resize"])
    printf(" gutter_frames=%d gutter_pct=%.1f", self.gutterFrames,
           self.displayTimes.count ? 100.0 * self.gutterFrames / self.displayTimes.count : 0);
  if (self.latencies) {
    printf(" lat_p50=%.1f lat_p99=%.1f lat_min=%.1f lat_max=%.1f n=%lu misses=%d", percentile(self.latencies, 0.5),
           percentile(self.latencies, 0.99), percentile(self.latencies, 0), percentile(self.latencies, 1),
           (unsigned long)self.latencies.count, self.misses);
    self.latencies = nil;
  }
  print_usage(self.usageStart, end);
  printf("\n");
  fflush(stdout);
  [self.steps removeObjectAtIndex:0];
  self.stepStart = 0;
}

- (void)frame:(CADisplayLink *)link {
  CFTimeInterval now = CACurrentMediaTime();
  if (self.stepStart == 0) {
    if (self.steps.count == 0) {
      [self.stream stopCaptureWithCompletionHandler:^(NSError *e) { exit(0); }];
      self.steps = nil;
      return;
    }
    if (!self.steps) return;
    [self beginStep];
  }
  NSString *step = self.steps[0][0];
  if ([self stepDone:now]) {
    if (self.scrolling) [self scroll:NSEventPhaseEnded];
    self.scrolling = NO;
    [self endStep];
    return;
  }
  double t = now - self.stepStart;
  if ([step isEqualToString:@"scroll"]) {
    if (!self.scrolling || now - self.scrollFlip >= 3) {
      if (self.scrolling) [self scroll:NSEventPhaseEnded];
      self.scrollDir = self.scrolling ? -self.scrollDir : -1;
      self.scrollFlip = now;
      self.scrolling = YES;
      [self scroll:NSEventPhaseBegan];
    } else {
      [self scroll:NSEventPhaseChanged];
    }
  } else if ([step isEqualToString:@"resize"]) {
    double k = (1 - cos(t * M_PI)) / 2;
    NSRect f = self.window.frame;
    NSRect r = [self.window frameRectForContentRect:NSMakeRect(0, 0, 800 + 300 * k, 600 + 200 * k)];
    r.origin = NSMakePoint(f.origin.x, NSMaxY(f) - r.size.height);
    [self.window setFrame:r display:YES];
    [self layout];
  }
}

@end

static void on_wakeup(void *ud) {
  dispatch_async(dispatch_get_main_queue(), ^{ bowser_host_tick(probe.host); });
}
static void on_detached(void *ud, bowser_host_t *h, bowser_result_e why) {
  fprintf(stderr, "probe: detached (%d)\n", why);
  exit(1);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) {
      fprintf(stderr, "usage: bowser-cef-probe <ticket> --producer PID [--frames S] [--keys N] ...\n");
      return 2;
    }
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    capture_queue = dispatch_queue_create("probe.capture", DISPATCH_QUEUE_SERIAL);
    probe = [Probe new];
    probe.steps = [NSMutableArray new];
    for (int i = 2; i + 1 < argc; i += 2) {
      if (!strcmp(argv[i], "--producer")) g_producer = atoi(argv[i + 1]);
      else [probe.steps addObject:@[ @(argv[i] + 2), @(atof(argv[i + 1])) ]];
    }

    bowser_host_config_s cfg = {.size = sizeof cfg, .wakeup_cb = on_wakeup, .detached_cb = on_detached};
    bowser_host_t *host;
    if (bowser_host_attach(argv[1], &cfg, &host) != BOWSER_OK) {
      fprintf(stderr, "probe: attach: %s\n", bowser_last_error());
      return 1;
    }
    probe.host = host;

    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    view.wantsLayer = YES;
    view.layer.backgroundColor = CGColorCreateSRGB(1, 0, 1, 1); // magenta: a gutter
    [view.layer addSublayer:bowser_host_layer(host)];
    probe.view = view;
    // Where the window goes matters to the numbers. A window on an inactive
    // Space isn't on the display, and a fully hidden one (below the desktop,
    // or alpha 0) the window server doesn't composite at all. So the window
    // sits on the current Space at alpha 0.01: composited at the display's
    // rate, yet at most 2.5/255 of a color step, which no one sees. Captures
    // come premultiplied by that alpha, so a red page reads about (2, 0, 0).
    // It ignores the mouse and never activates.
    probe.window = [[NSWindow alloc] initWithContentRect:view.frame
                                               styleMask:NSWindowStyleMaskBorderless
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    probe.window.contentView = view;
    probe.window.alphaValue = 0.01;
    probe.window.ignoresMouseEvents = YES;
    probe.window.hasShadow = NO;
    probe.window.collectionBehavior = NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
    [probe.window center];
    [probe.window orderFrontRegardless];
    [probe layout];
    bowser_host_focus(host, true);
    printf("window=%ld\n", (long)probe.window.windowNumber);
    fflush(stdout);
    [probe startCapture];
    [NSApp run];
  }
  return 0;
}
