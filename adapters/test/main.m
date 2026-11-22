// bowser-test: a producer with a scene that exercises the pipe.
//
// - A box moves with wall-clock time, so dropped frames show as jumps.
// - A text field takes text input, including IME marked text, and reports
//   its caret and composition rects.
// - Clicks leave dots; scrolling moves a striped column.
//
// Usage: bowser-test [--transport calayerhost|iosurface] [--tickets N]
//                    [--surfaces N] [--echo] [--spawn]
// Prints N tickets per surface, one per line, surface by surface, then runs
// until killed. --surfaces adds scene-less surfaces; --echo prints events;
// --spawn starts `sleep 5` on each attach, like an engine starting a helper.
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <spawn.h>

#include "bowser.h"

extern char **environ;

static const double kFieldX = 40, kFieldY = 40, kFieldH = 44, kPad = 10;

@interface Scene : NSObject
@property bowser_producer_t *producer;
@property bowser_surface_t *surface;
@property bowser_transport_e transport;
@property CALayer *root;
@property CALayer *box;
@property CATextLayer *stats;
@property CALayer *field;
@property CATextLayer *fieldText;
@property CALayer *stripes;
@property NSMutableString *committed;
@property NSString *marked;
@property double scrollY;
@property bowser_size_s size;
@property bowser_cursor_e cursor;
// frame pacing
@property CFTimeInterval lastFrame;
@property int frames;
@property int dropped;
@property double maxGapMs;
@property CFTimeInterval windowStart;
// IOSURFACE rendering
@property id<MTLDevice> device;
@property id<MTLCommandQueue> queue;
@property NSMutableArray *pool; // of @[IOSurface, CARenderer]
@property CALayer *renderRoot;  // scales the scene to pixels for CARenderer
@end

@implementation Scene

- (CATextLayer *)textLayer:(CGFloat)fontSize {
  CATextLayer *t = [CATextLayer layer];
  t.font = (__bridge CFTypeRef)[NSFont monospacedSystemFontOfSize:fontSize weight:NSFontWeightRegular];
  t.fontSize = fontSize;
  t.foregroundColor = CGColorCreateGenericRGB(0.9, 0.9, 0.95, 1);
  t.anchorPoint = CGPointZero;
  return t;
}

- (void)build {
  self.committed = [NSMutableString new];
  self.marked = @"";
  self.root = [CALayer layer]; // top-left origin comes from its parent
  self.root.anchorPoint = CGPointZero;
  self.root.backgroundColor = CGColorCreateGenericRGB(0.12, 0.12, 0.22, 1);

  self.stripes = [CALayer layer];
  self.stripes.anchorPoint = CGPointZero;
  for (int i = 0; i < 60; i++) {
    CALayer *s = [CALayer layer];
    s.frame = CGRectMake(0, i * 40, 24, 20);
    s.backgroundColor = CGColorCreateGenericRGB(0.3, 0.5 + (i % 5) * 0.1, 0.9, 1);
    [self.stripes addSublayer:s];
  }
  [self.root addSublayer:self.stripes];

  self.field = [CALayer layer];
  self.field.anchorPoint = CGPointZero;
  self.field.backgroundColor = CGColorCreateGenericRGB(0.05, 0.05, 0.1, 1);
  self.field.borderColor = CGColorCreateGenericRGB(0.5, 0.5, 0.7, 1);
  self.field.borderWidth = 1;
  self.field.cornerRadius = 6;
  [self.root addSublayer:self.field];
  self.fieldText = [self textLayer:18];
  [self.field addSublayer:self.fieldText];

  self.box = [CALayer layer];
  self.box.bounds = CGRectMake(0, 0, 48, 48);
  self.box.backgroundColor = CGColorCreateGenericRGB(1, 0.45, 0.2, 1);
  self.box.cornerRadius = 8;
  [self.root addSublayer:self.box];

  self.stats = [self textLayer:13];
  [self.root addSublayer:self.stats];
}

- (void)layout {
  bowser_size_s sz = self.size;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  self.root.frame = CGRectMake(0, 0, sz.width, sz.height);
  self.field.frame = CGRectMake(kFieldX, kFieldY, sz.width - 2 * kFieldX, kFieldH);
  self.fieldText.frame = CGRectMake(kPad, 10, sz.width - 2 * kFieldX - 2 * kPad, 26);
  self.stats.frame = CGRectMake(kFieldX, sz.height - 30, sz.width - 2 * kFieldX, 20);
  self.stripes.frame = CGRectMake(sz.width - 40, 0, 24, 2400);
  for (CATextLayer *t in @[ self.fieldText, self.stats ]) t.contentsScale = sz.scale;
  [CATransaction commit];
  [self renderText];
}

// ---- Text field -----------------------------------------------------

- (double)widthOf:(NSString *)s {
  if (s.length == 0) return 0;
  NSFont *font = [NSFont monospacedSystemFontOfSize:18 weight:NSFontWeightRegular];
  NSAttributedString *a = [[NSAttributedString alloc] initWithString:s attributes:@{NSFontAttributeName : font}];
  CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)a);
  double w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
  CFRelease(line);
  return w;
}

- (void)renderText {
  NSFont *font = [NSFont monospacedSystemFontOfSize:18 weight:NSFontWeightRegular];
  NSMutableAttributedString *s = [[NSMutableAttributedString alloc]
      initWithString:self.committed
          attributes:@{NSFontAttributeName : font, NSForegroundColorAttributeName : NSColor.whiteColor}];
  [s appendAttributedString:[[NSAttributedString alloc]
                                initWithString:self.marked
                                    attributes:@{
                                      NSFontAttributeName : font,
                                      NSForegroundColorAttributeName : NSColor.systemYellowColor,
                                    }]];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  self.fieldText.string = s;
  [CATransaction commit];

  double textX = kFieldX + kPad, textY = kFieldY + 10;
  double committedW = [self widthOf:self.committed];
  double markedW = [self widthOf:self.marked];
  bowser_surface_set_caret(self.surface,
                           (bowser_rect_s){textX + committedW + markedW, textY, 2, 24});
  if (self.marked.length) {
    bowser_rect_s r = {textX + committedW, textY, markedW, 24};
    bowser_surface_set_composition(self.surface, true, &r, 1);
  } else {
    bowser_surface_set_composition(self.surface, false, NULL, 0);
  }
}

- (void)text:(const bowser_text_s *)t {
  NSString *str = t->text ? @(t->text) : @"";
  switch (t->kind) {
  case BOWSER_TEXT_INSERT:
    [self.committed appendString:str];
    self.marked = @"";
    break;
  case BOWSER_TEXT_SET_MARKED:
    self.marked = str;
    break;
  case BOWSER_TEXT_UNMARK:
    [self.committed appendString:self.marked];
    self.marked = @"";
    break;
  }
  [self renderText];
}

- (void)key:(const bowser_key_s *)k {
  if (k->action == BOWSER_KEY_RELEASE || self.marked.length) return;
  if (k->keycode == 51 && self.committed.length) { // delete
    NSRange last = [self.committed rangeOfComposedCharacterSequenceAtIndex:self.committed.length - 1];
    [self.committed deleteCharactersInRange:last];
    [self renderText];
  }
}

// ---- Mouse and scroll -----------------------------------------------

- (void)mouse:(const bowser_mouse_s *)m {
  bool overField = m->x >= kFieldX && m->x <= self.size.width - kFieldX && m->y >= kFieldY &&
                   m->y <= kFieldY + kFieldH;
  bowser_cursor_e want = overField ? BOWSER_CURSOR_IBEAM : BOWSER_CURSOR_ARROW;
  if (want != self.cursor) {
    self.cursor = want;
    bowser_surface_set_cursor(self.surface, want);
  }
  if (m->action != BOWSER_MOUSE_DOWN) return;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  CALayer *dot = [CALayer layer];
  dot.bounds = CGRectMake(0, 0, 12, 12);
  dot.cornerRadius = 6;
  dot.position = CGPointMake(m->x, m->y);
  dot.backgroundColor = CGColorCreateGenericRGB(0.3, 1, 0.5, 1);
  [self.root addSublayer:dot];
  [CATransaction commit];
}

- (void)scroll:(const bowser_scroll_s *)s {
  self.scrollY = fmin(0, fmax(-2000, self.scrollY + s->dy));
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  CGRect f = self.stripes.frame;
  f.origin.y = self.scrollY;
  self.stripes.frame = f;
  [CATransaction commit];
}

// ---- Frames ---------------------------------------------------------

- (void)frame:(CADisplayLink *)link {
  CFTimeInterval now = CACurrentMediaTime();
  if (self.lastFrame > 0) {
    double gap = (now - self.lastFrame) * 1000;
    double expected = (link.targetTimestamp - link.timestamp) * 1000;
    if (gap > expected * 1.5) self.dropped++;
    self.maxGapMs = fmax(self.maxGapMs, gap);
  }
  self.lastFrame = now;
  self.frames++;
  if (self.windowStart == 0) self.windowStart = now;
  if (now - self.windowStart >= 2) {
    double fps = self.frames / (now - self.windowStart);
    NSString *line =
        [NSString stringWithFormat:@"%@  %.1f fps  dropped %d  max gap %.1f ms",
                                   self.transport == BOWSER_TRANSPORT_CALAYERHOST ? @"calayerhost" : @"iosurface",
                                   fps, self.dropped, self.maxGapMs];
    fprintf(stderr, "%s\n", line.UTF8String);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.stats.string = line;
    [CATransaction commit];
    self.frames = 0;
    self.dropped = 0;
    self.maxGapMs = 0;
    self.windowStart = now;
  }

  double travel = fmax(1, self.size.width - 2 * kFieldX - 48 - 40);
  double t = fmod(now * 200, travel * 2);
  double x = t < travel ? t : 2 * travel - t;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  self.box.position = CGPointMake(kFieldX + 24 + x, kFieldY + kFieldH + 60);
  [CATransaction commit];

  if (self.transport == BOWSER_TRANSPORT_IOSURFACE) [self renderToSurface];
}

- (void)renderToSurface {
  size_t w = (size_t)ceil(self.size.width * self.size.scale);
  size_t h = (size_t)ceil(self.size.height * self.size.scale);
  if (!self.device) {
    self.device = MTLCreateSystemDefaultDevice();
    self.queue = [self.device newCommandQueue];
    self.pool = [NSMutableArray new];
    self.renderRoot = [CALayer layer];
    self.renderRoot.anchorPoint = CGPointZero;
    [self.renderRoot addSublayer:self.root];
  }
  // Drop surfaces of the old size, then take one the host no longer shows.
  [self.pool filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSArray *e, NSDictionary *b) {
               IOSurfaceRef s = (__bridge IOSurfaceRef)e[0];
               return IOSurfaceGetWidth(s) == w && IOSurfaceGetHeight(s) == h;
             }]];
  NSArray *entry = nil;
  for (NSArray *e in self.pool)
    if (!IOSurfaceIsInUse((__bridge IOSurfaceRef)e[0])) {
      entry = e;
      break;
    }
  if (!entry) {
    if (self.pool.count >= 6) return; // host is behind; skip this frame
    IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef) @{
      (id)kIOSurfaceWidth : @(w),
      (id)kIOSurfaceHeight : @(h),
      (id)kIOSurfaceBytesPerElement : @4,
      (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA'),
    });
    IOSurfaceSetValue(s, kIOSurfaceColorSpace, kCGColorSpaceSRGB);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                 width:w
                                                                                height:h
                                                                             mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [self.device newTextureWithDescriptor:d iosurface:s plane:0];
    CARenderer *r = [CARenderer rendererWithMTLTexture:tex options:@{
      kCARendererMetalCommandQueue : self.queue,
      kCARendererColorSpace : (__bridge_transfer id)CGColorSpaceCreateWithName(kCGColorSpaceSRGB),
    }];
    r.layer = self.renderRoot;
    r.bounds = CGRectMake(0, 0, w, h);
    entry = @[ (__bridge_transfer id)s, r ];
    [self.pool addObject:entry];
  }
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  self.renderRoot.bounds = CGRectMake(0, 0, w, h);
  self.renderRoot.sublayerTransform = CATransform3DMakeScale(self.size.scale, self.size.scale, 1);
  [CATransaction commit];
  [CATransaction flush];

  CARenderer *r = entry[1];
  [r beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
  [r addUpdateRect:r.bounds];
  [r render];
  [r endFrame];
  id<MTLCommandBuffer> cb = [self.queue commandBuffer];
  [cb commit];
  [cb waitUntilScheduled];
  [cb waitUntilCompleted];
  bowser_surface_present(self.surface, (__bridge IOSurfaceRef)entry[0],
                         (bowser_rect_s){0, 0, self.size.width, self.size.height});
}

@end

// ---- Callbacks ------------------------------------------------------

static Scene *scene;
static bool echo, spawn;
static NSMutableArray<NSValue *> *surfaces; // index = surface number in --echo output

// --echo prints every event a surface receives, for the end-to-end test.
static void say(bowser_surface_t *s, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static void say(bowser_surface_t *s, NSString *fmt, ...) {
  if (!echo) return;
  va_list ap;
  va_start(ap, fmt);
  NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  NSUInteger i = [surfaces indexOfObject:[NSValue valueWithPointer:s]];
  printf("s%lu %s\n", (unsigned long)i, line.UTF8String);
  fflush(stdout);
}
static bool is_scene(bowser_surface_t *s) { return s == scene.surface; }

static void on_wakeup(void *ud) {
  dispatch_async(dispatch_get_main_queue(), ^{ bowser_producer_tick(scene.producer); });
}
static void on_key(void *ud, bowser_surface_t *s, const bowser_key_s *k) {
  say(s, @"key %d %u %@ %llu", k->action, k->keycode, @(k->text ? k->text : ""), k->timestamp_ns);
  if (is_scene(s)) [scene key:k];
}
static void on_mouse(void *ud, bowser_surface_t *s, const bowser_mouse_s *m) {
  say(s, @"mouse %d %d %.1f %.1f %d", m->action, m->button, m->x, m->y, m->click_count);
  if (is_scene(s)) [scene mouse:m];
}
static void on_scroll(void *ud, bowser_surface_t *s, const bowser_scroll_s *sc) {
  say(s, @"scroll %.1f %.1f %d", sc->dx, sc->dy, sc->precise);
  if (is_scene(s)) [scene scroll:sc];
}
static void on_text(void *ud, bowser_surface_t *s, const bowser_text_s *t) {
  say(s, @"text %d %@", t->kind, @(t->text ? t->text : ""));
  if (is_scene(s)) [scene text:t];
}
static void on_resize(void *ud, bowser_surface_t *s, bowser_size_s size) {
  say(s, @"resize %.0fx%.0f@%.0f", size.width, size.height, size.scale);
  if (!is_scene(s)) return;
  scene.size = size;
  [scene layout];
}
static void on_focus(void *ud, bowser_surface_t *s, bool focused) { say(s, @"focus %d", focused); }
static void on_attach(void *ud, bowser_surface_t *s, bool attached) {
  say(s, @"%@", attached ? @"attached" : @"detached");
  if (!echo) fprintf(stderr, "host %s\n", attached ? "attached" : "detached");
  if (attached && is_scene(s)) [scene renderText]; // send the caret to the new host
  if (attached && spawn) {
    pid_t pid;
    char *argv[] = {"/bin/sleep", "5", NULL};
    posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);
  }
}

int main(int argc, char **argv) {
  @autoreleasepool {
    bowser_transport_e transport = BOWSER_TRANSPORT_CALAYERHOST;
    int tickets = 1, count = 1;
    for (int i = 1; i < argc; i++) {
      if (!strcmp(argv[i], "--transport") && i + 1 < argc)
        transport = !strcmp(argv[++i], "iosurface") ? BOWSER_TRANSPORT_IOSURFACE : BOWSER_TRANSPORT_CALAYERHOST;
      else if (!strcmp(argv[i], "--tickets") && i + 1 < argc)
        tickets = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--surfaces") && i + 1 < argc)
        count = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--echo"))
        echo = true;
      else if (!strcmp(argv[i], "--spawn"))
        spawn = true;
    }

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

    scene = [Scene new];
    scene.transport = transport;
    bowser_producer_config_s cfg = {
        .size = sizeof cfg,
        .transport = transport,
        .wakeup_cb = on_wakeup,
        .key_cb = on_key,
        .mouse_cb = on_mouse,
        .scroll_cb = on_scroll,
        .text_cb = on_text,
        .resize_cb = on_resize,
        .focus_cb = on_focus,
        .attach_cb = on_attach,
    };
    bowser_producer_t *producer;
    if (bowser_producer_new(&cfg, &producer) != BOWSER_OK) {
      fprintf(stderr, "producer: %s\n", bowser_last_error());
      return 1;
    }
    scene.producer = producer;
    scene.size = (bowser_size_s){800, 500, NSScreen.mainScreen.backingScaleFactor};
    bowser_surface_t *surface;
    if (bowser_surface_new(producer, scene.size, &surface) != BOWSER_OK) {
      fprintf(stderr, "surface: %s\n", bowser_last_error());
      return 1;
    }
    scene.surface = surface;
    [scene build];
    [scene layout];
    CALayer *root = bowser_surface_root_layer(surface);
    if (root) {
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      [root addSublayer:scene.root];
      [CATransaction commit];
    }

    surfaces = [NSMutableArray arrayWithObject:[NSValue valueWithPointer:surface]];
    for (int i = 1; i < count; i++) {
      bowser_surface_t *extra; // echo-only surfaces with no scene
      if (bowser_surface_new(producer, scene.size, &extra) == BOWSER_OK)
        [surfaces addObject:[NSValue valueWithPointer:extra]];
    }
    for (NSValue *v in surfaces) {
      for (int i = 0; i < tickets; i++) {
        char *t = bowser_surface_ticket(v.pointerValue);
        printf("%s\n", t);
        bowser_string_free(t);
      }
    }
    fflush(stdout);

    CADisplayLink *link = [NSScreen.mainScreen displayLinkWithTarget:scene selector:@selector(frame:)];
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [NSApp run];
  }
  return 0;
}
