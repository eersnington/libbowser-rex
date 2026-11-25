// End-to-end tests for the CEF adapter: a real bowser-cef process loading a
// real page, and hosts in this process on the IOSURFACE transport, so the
// host layer's pixels can be read back. Pages are data: URLs; no network.
#include "harness.h"

static NSString *const kEngine = @"build/bowser-cef.app/Contents/MacOS/bowser-cef";

static NSString *data_url(NSString *html) {
  return [@"data:text/html," stringByAppendingString:[html stringByAddingPercentEncodingWithAllowedCharacters:
                                                               NSCharacterSet.URLQueryAllowedCharacterSet]];
}

// A fresh profile per engine: Chromium locks a profile to one process, and
// tests must not touch the user's.
static NSMutableArray<NSString *> *profiles;

static NSString *temp_profile(void) {
  char dir[] = "/tmp/bowser-cef-test.XXXXXX";
  NSString *path = @(mkdtemp(dir));
  if (!profiles) profiles = [NSMutableArray new];
  [profiles addObject:path];
  return path;
}

static Producer *start_cef(NSString *html, int tickets) {
  NSArray *argv = @[
    kEngine, @"--profile", temp_profile(), @"--transport", @"iosurface", @"--url", data_url(html), @"--tickets",
    @(tickets).stringValue
  ];
  return [Producer spawn:argv tickets:tickets];
}

// Size the host layer to w x h points at scale 1.
static void resize(Host *host, double w, double h) {
  bowser_host_layer(host.handle).frame = CGRectMake(0, 0, w, h);
  bowser_host_resize(host.handle, (bowser_size_s){w, h, 1});
}

static Host *attach_sized(NSString *ticket, double w, double h) {
  Host *host;
  CHECK(attach(ticket, &host) == BOWSER_OK, "attach: %s", bowser_last_error());
  resize(host, w, h);
  return host;
}

typedef struct { uint8_t r, g, b; } rgb;

// The host layer's pixels at its four corners, as a screenshot would show them.
static void corners(Host *h, rgb out[4]) {
  CALayer *layer = bowser_host_layer(h.handle);
  size_t w = (size_t)layer.bounds.size.width, hgt = (size_t)layer.bounds.size.height;
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(NULL, w, hgt, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(cs);
  [layer renderInContext:ctx];
  uint8_t *px = CGBitmapContextGetData(ctx);
  size_t at[4][2] = {{2, 2}, {w - 3, 2}, {2, hgt - 3}, {w - 3, hgt - 3}};
  for (int i = 0; i < 4; i++) {
    uint8_t *p = px + at[i][1] * w * 4 + at[i][0] * 4;
    out[i] = (rgb){p[0], p[1], p[2]};
  }
  CGContextRelease(ctx);
}

static BOOL near(rgb c, int r, int g, int b) { return abs(c.r - r) < 24 && abs(c.g - g) < 24 && abs(c.b - b) < 24; }

static BOOL shows(Host *h, int r, int g, int b) {
  rgb c[4];
  corners(h, c);
  for (int i = 0; i < 4; i++)
    if (!near(c[i], r, g, b)) return NO;
  return YES;
}

static NSString *describe(Host *h) {
  rgb c[4];
  corners(h, c);
  NSMutableString *s = [NSMutableString new];
  for (int i = 0; i < 4; i++) [s appendFormat:@"(%d,%d,%d) ", c[i].r, c[i].g, c[i].b];
  return s;
}

#define MAGENTA 255, 0, 255
#define CYAN 0, 255, 255
#define GREEN 0, 255, 0
static NSString *const kMagentaPage = @"<body style='margin:0;background:rgb(255,0,255)'>";

// A page that has finished painting sends no more frames, so a host that
// takes over the surface sees only what the producer re-sends.
static void test_new_host_sees_a_finished_page(void) {
  Producer *p = start_cef(kMagentaPage, 2);
  Host *first = attach_sized(p.tickets[0], 64, 64);
  CHECK(wait_for(^{ return shows(first, MAGENTA); }, 10), "first host shows the page: %s", describe(first).UTF8String);
  pump(1); // the page is idle now
  Host *next = attach_sized(p.tickets[1], 64, 64);
  CHECK(wait_for(^{ return shows(next, MAGENTA); }, 3), "the new host shows the page: %s", describe(next).UTF8String);
  detach(first);
  detach(next);
  [p stop];
}

static void test_resize_fills_the_new_size(void) {
  Producer *p = start_cef(kMagentaPage, 1);
  Host *h = attach_sized(p.tickets[0], 64, 64);
  CHECK(wait_for(^{ return shows(h, MAGENTA); }, 10), "host shows the page: %s", describe(h).UTF8String);
  resize(h, 160, 120);
  CHECK(wait_for(^{ return shows(h, MAGENTA); }, 3), "every corner of the larger host is page: %s",
        describe(h).UTF8String);
  detach(h);
  [p stop];
}

static void test_scroll_moves_the_page(void) {
  Producer *p = start_cef(@"<body style='margin:0'><div style='height:100px;background:rgb(255,0,255)'></div>"
                          @"<div style='height:4000px;background:rgb(0,255,255)'></div>",
                          1);
  Host *h = attach_sized(p.tickets[0], 64, 64);
  CHECK(wait_for(^{ return shows(h, MAGENTA); }, 10), "host shows the top of the page: %s", describe(h).UTF8String);
  for (int i = 0; i < 10; i++) {
    bowser_scroll_s s = {.dy = -40, .precise = true, .x = 32, .y = 32};
    bowser_host_scroll(h.handle, &s);
  }
  CHECK(wait_for(^{ return shows(h, CYAN); }, 3), "host shows the page scrolled past its top: %s",
        describe(h).UTF8String);
  detach(h);
  [p stop];
}

static void test_typing_reaches_a_focused_field(void) {
  Producer *p = start_cef(@"<body style='margin:0;background:rgb(255,0,0)'>"
                          @"<input autofocus style='position:absolute;left:20px;top:20px;width:20px' "
                          @"oninput=\"document.body.style.background=this.value=='ok'?'rgb(0,255,0)':'rgb(0,0,255)'\">",
                          1);
  Host *h = attach_sized(p.tickets[0], 64, 64);
  CHECK(wait_for(^{ return shows(h, 255, 0, 0); }, 10), "host shows the page: %s", describe(h).UTF8String);
  bowser_host_focus(h.handle, true);
  bowser_key_s o = {.action = BOWSER_KEY_PRESS, .keycode = 31, .text = "o", .unmodified_text = "o"};
  bowser_host_key(h.handle, &o);
  text(h, BOWSER_TEXT_INSERT, "o");
  o.action = BOWSER_KEY_RELEASE;
  bowser_host_key(h.handle, &o);
  text(h, BOWSER_TEXT_SET_MARKED, "k"); // an IME composition, then its commit
  text(h, BOWSER_TEXT_INSERT, "k");
  CHECK(wait_for(^{ return shows(h, GREEN); }, 3), "the field holds \"ok\": %s", describe(h).UTF8String);
  detach(h);
  [p stop];
}

static void test_cursor_follows_the_page(void) {
  Producer *p =
      start_cef(@"<body style='margin:0'><a href='x' style='display:block;height:100vh;color:white'>link</a>", 1);
  Host *h = attach_sized(p.tickets[0], 64, 64);
  CHECK(wait_for(^{ return shows(h, 255, 255, 255); }, 10), "host shows the page: %s", describe(h).UTF8String);
  bowser_mouse_s m = {.action = BOWSER_MOUSE_MOVE, .x = 30, .y = 30};
  bowser_host_mouse(h.handle, &m);
  CHECK(wait_for(^{ return (BOOL)(h.cursor == BOWSER_CURSOR_POINTER); }, 3),
        "cursor is a pointer over a link, got %d", h.cursor);
  detach(h);
  [p stop];
}

// ---- The engine, driven on its control channel ----------------------------

@interface Engine : NSObject
@property Producer *proc;
@property int lastId;
@property NSMutableArray<NSDictionary *> *queue; // events not yet waited for
@property NSMutableArray<NSDictionary *> *log;   // every event
@end

@implementation Engine
- (NSDictionary *)read:(double)timeout {
  NSString *line = [self.proc nextLine:timeout];
  if (!line) return nil;
  NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
                                                      options:0
                                                        error:nil];
  if (obj[@"event"]) {
    [self.queue addObject:obj];
    [self.log addObject:obj];
  }
  return obj;
}

- (NSDictionary *)call:(NSDictionary *)cmd {
  NSMutableDictionary *c = [cmd mutableCopy];
  c[@"id"] = @(++self.lastId);
  NSMutableData *d = [[NSJSONSerialization dataWithJSONObject:c options:0 error:nil] mutableCopy];
  [d appendBytes:"\n" length:1];
  write(self.proc.in, d.bytes, d.length);
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:5];
  NSDictionary *obj;
  while ([end timeIntervalSinceNow] > 0 && (obj = [self read:[end timeIntervalSinceNow]]))
    if ([obj[@"id"] isEqual:c[@"id"]]) return obj;
  return @{@"error" : @"no reply"};
}

// The first queued or new event that matches. It and the earlier events of
// its surface are used up.
- (NSDictionary *)wait:(BOOL (^)(NSDictionary *))match within:(double)seconds {
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
  for (;;) {
    for (NSUInteger i = 0; i < self.queue.count; i++) {
      NSDictionary *e = self.queue[i];
      if (!match(e)) continue;
      NSIndexSet *used = [self.queue indexesOfObjectsPassingTest:^BOOL(NSDictionary *o, NSUInteger j, BOOL *stop) {
        return j <= i && (o[@"surface"] == e[@"surface"] || [o[@"surface"] isEqual:e[@"surface"]]);
      }];
      [self.queue removeObjectsAtIndexes:used];
      return e;
    }
    if ([end timeIntervalSinceNow] < 0 || ![self read:[end timeIntervalSinceNow]]) return nil;
  }
}

- (NSDictionary *)state:(NSString *)sid where:(BOOL (^)(NSDictionary *))match {
  return [self wait:^BOOL(NSDictionary *e) {
    return [e[@"event"] isEqual:@"state"] && [e[@"surface"] isEqual:sid] && match(e);
  } within:10];
}

- (NSString *)open:(NSString *)url {
  return [self open:url transport:@"iosurface"];
}

// calayerhost opens a windowed (zero-copy) tab, iosurface an OSR one.
- (NSString *)open:(NSString *)url transport:(NSString *)transport {
  NSDictionary *r = [self call:@{@"cmd" : @"open", @"url" : url, @"transport" : transport}];
  CHECK(r[@"surface"], "open: %s", r.description.UTF8String);
  NSString *want = [transport isEqual:@"calayerhost"] ? @"windowed" : @"osr";
  CHECK([r[@"mode"] isEqual:want], "a %s tab is %s: %s", transport.UTF8String, want.UTF8String,
        r.description.UTF8String);
  return r[@"surface"];
}

- (NSString *)ticket:(NSString *)sid {
  return [self call:@{@"cmd" : @"ticket", @"surface" : sid}][@"ticket"];
}

- (NSDictionary *)message:(NSString *)name to:(NSString *)sid body:(NSDictionary *)body {
  return [self call:@{@"cmd" : @"message", @"surface" : sid, @"name" : name, @"body" : body ?: @{}}];
}
@end

static Engine *start_engine(void) {
  Engine *e = [Engine new];
  e.queue = [NSMutableArray new];
  e.log = [NSMutableArray new];
  e.proc = [Producer spawnWithInput:@[ kEngine, @"--profile", temp_profile() ]];
  CHECK([e wait:^BOOL(NSDictionary *ev) { return [ev[@"event"] isEqual:@"ready"]; } within:15], "engine is ready");
  return e;
}

static BOOL titled(NSDictionary *state, NSString *title) {
  return [state[@"title"] isEqual:title] && ![state[@"loading"] boolValue];
}

static NSDictionary *parse(NSString *json) {
  return [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
}

// The newest state message the host got, as JSON.
static NSDictionary *host_state(Host *h) {
  for (NSString *m in h.messages.reverseObjectEnumerator)
    if ([m hasPrefix:@"state "]) return parse([m substringFromIndex:6]);
  return nil;
}

// A pixel of the host layer, as a screenshot would show it.
static rgb pixel(Host *h, size_t x, size_t y) {
  CALayer *layer = bowser_host_layer(h.handle);
  size_t w = (size_t)layer.bounds.size.width, hgt = (size_t)layer.bounds.size.height;
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(NULL, w, hgt, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(cs);
  [layer renderInContext:ctx];
  // CG rows run bottom up; y counts down from the top, like the page.
  uint8_t *p = (uint8_t *)CGBitmapContextGetData(ctx) + (hgt - 1 - y) * w * 4 + x * 4;
  rgb c = {p[0], p[1], p[2]};
  CGContextRelease(ctx);
  return c;
}

static void click(Host *h, double x, double y) {
  bowser_mouse_s m = {.action = BOWSER_MOUSE_MOVE, .x = x, .y = y};
  bowser_host_mouse(h.handle, &m);
  m.action = BOWSER_MOUSE_DOWN;
  m.click_count = 1;
  bowser_host_mouse(h.handle, &m);
  m.action = BOWSER_MOUSE_UP;
  bowser_host_mouse(h.handle, &m);
}

static NSString *const kPageA = @"<title>A</title><body style='background:rgb(255,0,255)'>";
static NSString *const kPageB = @"<title>B</title><body style='background:rgb(0,255,255)'>";

static void test_navigation_reports_state(void) {
  Engine *e = start_engine();
  NSString *a = data_url(kPageA), *b = data_url(kPageB);
  NSString *sid = [e open:a];
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return titled(s, @"A") && [s[@"url"] isEqual:a]; }],
        "the controller hears the first page's title and url");
  Host *h = attach_sized([e ticket:sid], 64, 64);
  CHECK(wait_for(^{ return [host_state(h)[@"title"] isEqual:@"A"]; }, 3),
        "a host that attaches gets the current state at once: %s", h.messages.description.UTF8String);

  bowser_host_send(h.handle, "navigate", [NSString stringWithFormat:@"{\"url\":\"%@\"}", b].UTF8String);
  NSDictionary *s = [e state:sid where:^BOOL(NSDictionary *s) { return titled(s, @"B"); }];
  CHECK([s[@"url"] isEqual:b] && [s[@"can_go_back"] boolValue] && ![s[@"can_go_forward"] boolValue],
        "a host's navigate loads the page: %s", s.description.UTF8String);
  CHECK(wait_for(^{ return titled(host_state(h), @"B"); }, 3), "and the host hears it too");
  CHECK(wait_for(^{ return shows(h, CYAN); }, 3), "and shows it: %s", describe(h).UTF8String);

  [e message:@"back" to:sid body:nil];
  s = [e state:sid where:^BOOL(NSDictionary *s) { return titled(s, @"A"); }];
  CHECK([s[@"url"] isEqual:a] && ![s[@"can_go_back"] boolValue] && [s[@"can_go_forward"] boolValue],
        "back returns to the first page: %s", s.description.UTF8String);
  [e message:@"forward" to:sid body:nil];
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return titled(s, @"B"); }], "forward goes to the second again");

  NSDictionary *bad = [e message:@"navigate" to:sid body:@{}];
  CHECK(bad[@"error"], "navigate without a url is an error: %s", bad.description.UTF8String);
  detach(h);
  [e.proc stop];
}

static void test_typed_hosts_get_a_scheme(void) {
  Engine *e = start_engine();
  NSString *sid = [e open:@"about:blank"];
  // .invalid never resolves (RFC 2606), so this loads an error page, offline.
  [e message:@"navigate" to:sid body:@{@"url" : @"  bowser.invalid/path  "}];
  NSDictionary *st = [e state:sid where:^BOOL(NSDictionary *s) { return [s[@"url"] hasPrefix:@"https://bowser"]; }];
  CHECK([st[@"url"] isEqual:@"https://bowser.invalid/path"], "a bare host loads over https: %s", e.log.description.UTF8String);

  // A typed path to a file on disk opens the file, as a page someone just wrote.
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"bowser typed path.html"];
  [@"<title>From disk</title>" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
  [e message:@"navigate" to:sid body:@{@"url" : path}];
  st = [e state:sid where:^BOOL(NSDictionary *s) { return [s[@"title"] isEqual:@"From disk"]; }];
  CHECK([st[@"title"] isEqual:@"From disk"], "a typed path opens the file: %s", e.log.description.UTF8String);
  [NSFileManager.defaultManager removeItemAtPath:path error:nil];
  [e.proc stop];
}

static NSArray<NSPasteboardItem *> *save_pasteboard(void) {
  NSMutableArray *items = [NSMutableArray new];
  for (NSPasteboardItem *item in NSPasteboard.generalPasteboard.pasteboardItems) {
    NSPasteboardItem *copy = [NSPasteboardItem new];
    for (NSPasteboardType type in item.types) {
      NSData *d = [item dataForType:type];
      if (d) [copy setData:d forType:type];
    }
    [items addObject:copy];
  }
  return items;
}

static void restore_pasteboard(NSArray<NSPasteboardItem *> *items) {
  [NSPasteboard.generalPasteboard clearContents];
  if (items.count) [NSPasteboard.generalPasteboard writeObjects:items];
}

// Chromium writes to the general pasteboard; it has no way to name another.
static void test_copy_puts_the_selection_on_the_pasteboard(void) {
  NSArray *saved = save_pasteboard();
  Engine *e = start_engine();
  NSString *sid = [e open:data_url(@"<title>copy</title><p>bowser copy check</p>")];
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return titled(s, @"copy"); }], "page loaded");
  NSInteger before = NSPasteboard.generalPasteboard.changeCount;
  [e message:@"edit" to:sid body:@{@"command" : @"select_all"}];
  [e message:@"edit" to:sid body:@{@"command" : @"copy"}];
  CHECK(wait_for(^{ return (BOOL)(NSPasteboard.generalPasteboard.changeCount != before); }, 3),
        "copy writes the pasteboard");
  NSString *copied = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
  CHECK([copied containsString:@"bowser copy check"], "with the page's selected text, got %s", copied.UTF8String);
  NSDictionary *bad = [e message:@"edit" to:sid body:@{@"command" : @"explode"}];
  CHECK(bad[@"error"], "an unknown edit command is an error");
  [e.proc stop];
  restore_pasteboard(saved);
}

static void test_find_counts_matches(void) {
  Engine *e = start_engine();
  NSString *sid = [e open:data_url(@"<title>find</title>needle one needle two needle")];
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return titled(s, @"find"); }], "page loaded");
  Host *h = attach_sized([e ticket:sid], 64, 64); // a hidden tab finds matches but activates none
  CHECK(wait_for(^{ return shows(h, 255, 255, 255); }, 5), "host shows the page");
  [e message:@"find" to:sid body:@{@"text" : @"needle"}];
  NSDictionary *r = [e wait:^BOOL(NSDictionary *ev) {
    return [ev[@"event"] isEqual:@"find_result"] && [ev[@"count"] intValue] == 3;
  } within:5];
  CHECK(r && [r[@"active"] intValue] == 1, "find reports 3 matches, the first active: %s", r.description.UTF8String);
  [e message:@"find" to:sid body:@{@"text" : @"needle", @"next" : @YES}];
  r = [e wait:^BOOL(NSDictionary *ev) { return [ev[@"event"] isEqual:@"find_result"]; } within:5];
  CHECK([r[@"count"] intValue] == 3, "the count stays: %s", r.description.UTF8String);
  CHECK([r[@"active"] intValue] == 2, "find next moves to the second: %s", r.description.UTF8String);
  [e.proc stop];
}

static NSString *const kField = @"<title>%@</title><body style='margin:0;background:rgb(255,0,255)'>"
                                @"<input autofocus oninput='document.title=this.value'>";

static void type_into(Host *h, const char *c) {
  bowser_key_s k = {.action = BOWSER_KEY_PRESS, .keycode = 0, .text = c, .unmodified_text = c};
  bowser_host_key(h.handle, &k);
  text(h, BOWSER_TEXT_INSERT, c);
  k.action = BOWSER_KEY_RELEASE;
  bowser_host_key(h.handle, &k);
}

static NSArray *states_of(Engine *e, NSString *sid, NSUInteger since) {
  NSMutableArray *got = [NSMutableArray new];
  for (NSUInteger i = since; i < e.log.count; i++)
    if ([e.log[i][@"event"] isEqual:@"state"] && [e.log[i][@"surface"] isEqual:sid]) [got addObject:e.log[i]];
  return got;
}

static void test_surfaces_in_one_engine_are_isolated(void) {
  Engine *e = start_engine();
  NSString *a = [e open:data_url([NSString stringWithFormat:kField, @"a"])];
  NSString *b = [e open:data_url([NSString stringWithFormat:kField, @"b"])];
  CHECK(![a isEqual:b], "each open makes its own surface");
  CHECK([e state:a where:^BOOL(NSDictionary *s) { return titled(s, @"a"); }], "a loaded");
  CHECK([e state:b where:^BOOL(NSDictionary *s) { return titled(s, @"b"); }], "b loaded");
  Host *ha = attach_sized([e ticket:a], 64, 64), *hb = attach_sized([e ticket:b], 64, 64);
  // Below the field, which sits at the top.
  CHECK(wait_for(^{ return (BOOL)(near(pixel(ha, 32, 50), MAGENTA) && near(pixel(hb, 32, 50), MAGENTA)); }, 5),
        "both show their page");
  bowser_host_focus(ha.handle, true);
  bowser_host_focus(hb.handle, true);

  NSUInteger mark = e.log.count;
  type_into(ha, "x");
  CHECK([e state:a where:^BOOL(NSDictionary *s) { return [s[@"title"] isEqual:@"x"]; }], "typing reaches a's field");
  bowser_host_send(ha.handle, "navigate", [NSString stringWithFormat:@"{\"url\":\"%@\"}", data_url(kPageB)].UTF8String);
  CHECK([e state:a where:^BOOL(NSDictionary *s) { return titled(s, @"B"); }], "a navigates");
  CHECK(wait_for(^{ return shows(ha, CYAN); }, 3), "a's host shows a's new page");
  pump(0.3);
  [e read:0.1];
  CHECK(states_of(e, b, mark).count == 0, "b's state never changed: %s", states_of(e, b, mark).description.UTF8String);
  CHECK(near(pixel(hb, 32, 50), MAGENTA), "b's host still shows b");
  CHECK(![host_state(hb)[@"title"] isEqual:@"B"], "and b's host heard nothing of a's navigation");

  [e call:@{@"cmd" : @"close", @"surface" : a}];
  CHECK(wait_for(^{ return ha.detached; }, 3), "closing a detaches a's host");
  CHECK(!hb.detached, "and not b's");
  type_into(hb, "y");
  CHECK([e state:b where:^BOOL(NSDictionary *s) { return [s[@"title"] isEqual:@"y"]; }], "b still takes input");
  NSDictionary *late = [e call:@{@"cmd" : @"ticket", @"surface" : a}];
  CHECK(late[@"error"], "a closed surface has no tickets");
  detach(ha);
  detach(hb);
  [e.proc stop];
}

static void test_engine_death_reaches_every_host(void) {
  Engine *e = start_engine();
  NSString *a = [e open:data_url(kPageA)], *b = [e open:data_url(kPageB)];
  Host *ha = attach_sized([e ticket:a], 64, 64), *hb = attach_sized([e ticket:b], 64, 64);
  CHECK(wait_for(^{ return (BOOL)(shows(ha, MAGENTA) && shows(hb, CYAN)); }, 10), "both attached and showing");
  [e.proc kill];
  CHECK(wait_for(^{ return (BOOL)(ha.detached && hb.detached); }, 3), "every host hears the engine died");
  CHECK(ha.detachedWhy == BOWSER_ERR_DISCONNECTED && hb.detachedWhy == BOWSER_ERR_DISCONNECTED,
        "as DISCONNECTED, got %d and %d", ha.detachedWhy, hb.detachedWhy);
  detach(ha);
  detach(hb);
}

static void test_engine_exits_when_its_controller_goes(void) {
  Engine *e = start_engine();
  [e open:data_url(kPageA)];
  close(e.proc.in);
  e.proc.in = -1;
  CHECK(wait_for(^{ return (BOOL)(waitpid(e.proc.pid, NULL, WNOHANG) == e.proc.pid); }, 10),
        "stdin's end stops the engine and its helpers");
}

// <select> opens as a separate popup paint, which must be drawn over the page.
static void test_select_popup_shows(void) {
  NSString *options = @"";
  for (int i = 0; i < 6; i++)
    options = [options stringByAppendingFormat:@"<option style='background:rgb(0,255,0)'>option %d</option>", i];
  Producer *p = start_cef([NSString stringWithFormat:@"<body style='margin:0;background:rgb(255,0,255)'>"
                                                     @"<select style='position:absolute;left:10px;top:10px;"
                                                     @"width:150px;height:30px'>%@</select>",
                                                     options],
                          1);
  Host *h = attach_sized(p.tickets[0], 240, 240);
  CHECK(wait_for(^{ return shows(h, MAGENTA); }, 10), "host shows the page: %s", describe(h).UTF8String);
  bowser_host_focus(h.handle, true);
  click(h, 60, 25);
  CHECK(wait_for(^{ return near(pixel(h, 60, 80), GREEN); }, 3), "the open list shows under the select, got (%d,%d,%d)",
        pixel(h, 60, 80).r, pixel(h, 60, 80).g, pixel(h, 60, 80).b);
  bowser_key_s esc = {.action = BOWSER_KEY_PRESS, .keycode = 53, .text = "\x1b", .unmodified_text = "\x1b"};
  bowser_host_key(h.handle, &esc);
  esc.action = BOWSER_KEY_RELEASE;
  bowser_host_key(h.handle, &esc);
  CHECK(wait_for(^{ return near(pixel(h, 60, 80), MAGENTA); }, 3), "a closed list leaves the page, got (%d,%d,%d)",
        pixel(h, 60, 80).r, pixel(h, 60, 80).g, pixel(h, 60, 80).b);
  detach(h);
  [p stop];
}


// ---- Windowed (zero-copy) tabs --------------------------------------------
//
// A windowed tab's pixels are Chromium's own GPU layers, which a host in this
// process can't read back; what the page does shows in its title instead.

static NSString *const kWindowed = @"calayerhost";

// Whether a window of the engine is on screen. Never, in any mode.
static BOOL engine_window_on_screen(Engine *e) {
  NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
  for (NSDictionary *w in windows)
    if ([w[(id)kCGWindowOwnerPID] intValue] == e.proc.pid) return YES;
  return NO;
}

static void click_button(Host *h, double x, double y, int button) {
  bowser_mouse_s m = {.action = BOWSER_MOUSE_MOVE, .x = x, .y = y};
  bowser_host_mouse(h.handle, &m);
  m.action = BOWSER_MOUSE_DOWN;
  m.button = button;
  m.click_count = 1;
  bowser_host_mouse(h.handle, &m);
  m.action = BOWSER_MOUSE_UP;
  bowser_host_mouse(h.handle, &m);
}

// The newest `menu` message the host got after `since` messages.
static NSDictionary *menu_after(Host *h, NSUInteger since) {
  for (NSUInteger i = h.messages.count; i-- > since;)
    if ([h.messages[i] hasPrefix:@"menu "]) return parse([h.messages[i] substringFromIndex:5]);
  return nil;
}

static NSDictionary *wait_menu(Host *h, NSUInteger since) {
  __block NSDictionary *menu;
  wait_for(^{ return (BOOL)((menu = menu_after(h, since)) != nil); }, 5);
  return menu;
}

static void answer(Host *h, NSDictionary *menu, int index) {
  bowser_host_send(h.handle, "menu_result",
                   [NSString stringWithFormat:@"{\"id\":%@,\"index\":%d}", menu[@"id"], index].UTF8String);
}

// Depth first, separators and submenu items included: the index menu_result takes.
static void flatten(NSArray *items, NSMutableArray *out) {
  for (NSDictionary *item in items) {
    [out addObject:item];
    if (item[@"children"]) flatten(item[@"children"], out);
  }
}

static int index_of(NSDictionary *menu, NSString *label) {
  NSMutableArray *flat = [NSMutableArray new];
  flatten(menu[@"items"], flat);
  for (NSUInteger i = 0; i < flat.count; i++)
    if ([flat[i][@"label"] isEqual:label]) return (int)i;
  return -1;
}

// At the display's scale, as a real host: a scale change in flight makes
// CEF's OSR place a context menu by the old scale.
static Host *attach_windowed(Engine *e, NSString *sid) {
  Host *h;
  CHECK(attach([e ticket:sid], &h) == BOWSER_OK, "attach: %s", bowser_last_error());
  bowser_host_layer(h.handle).frame = CGRectMake(0, 0, 300, 200);
  bowser_host_resize(h.handle, (bowser_size_s){300, 200, NSScreen.mainScreen.backingScaleFactor});
  if (!h.messages) h.messages = [NSMutableArray new];
  return h;
}

static void test_windowed_navigation_reports_state(void) {
  Engine *e = start_engine();
  NSString *a = data_url([kPageA stringByAppendingString:@"lorem ipsum lorem"]), *b = data_url(kPageB);
  NSString *sid = [e open:a transport:kWindowed];
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return titled(s, @"A") && [s[@"url"] isEqual:a]; }],
        "the controller hears the first page's title and url");
  Host *h = attach_windowed(e, sid);
  CHECK(wait_for(^{ return [host_state(h)[@"title"] isEqual:@"A"]; }, 3), "a host that attaches gets the state");
  bowser_host_send(h.handle, "navigate", [NSString stringWithFormat:@"{\"url\":\"%@\"}", b].UTF8String);
  NSDictionary *s = [e state:sid where:^BOOL(NSDictionary *s) { return titled(s, @"B"); }];
  CHECK([s[@"url"] isEqual:b] && [s[@"can_go_back"] boolValue], "a host's navigate loads the page: %s",
        s.description.UTF8String);
  CHECK(wait_for(^{ return titled(host_state(h), @"B"); }, 3), "and the host hears it too");
  [e message:@"back" to:sid body:nil];
  s = [e state:sid where:^BOOL(NSDictionary *s) { return titled(s, @"A"); }];
  CHECK([s[@"can_go_forward"] boolValue], "back returns to the first page: %s", s.description.UTF8String);
  [e message:@"find" to:sid body:@{@"text" : @"lorem"}];
  NSDictionary *r = [e wait:^BOOL(NSDictionary *ev) { return [ev[@"event"] isEqual:@"find_result"]; } within:5];
  CHECK([r[@"count"] intValue] == 2, "find works in a windowed tab: %s", r.description.UTF8String);
  CHECK(!engine_window_on_screen(e), "and no window of the engine is on screen");
  detach(h);
  [e.proc stop];
}

// A tab no host shows is hidden, like a background tab: Chromium stops
// drawing and throttles it.
static void test_windowed_tab_without_a_host_is_hidden(void) {
  Engine *e = start_engine();
  NSString *sid = [e open:data_url(@"<title>t</title><script>"
                                   @"document.onvisibilitychange = () => document.title = document.visibilityState;"
                                   @"</script>")
                transport:kWindowed];
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return titled(s, @"t"); }], "page loaded");
  Host *h = attach_windowed(e, sid);
  pump(0.5);
  detach(h);
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return [s[@"title"] isEqual:@"hidden"]; }],
        "when its host leaves, the tab is hidden");
  Host *again = attach_windowed(e, sid);
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return [s[@"title"] isEqual:@"visible"]; }],
        "and visible again for the next host");
  detach(again);
  [e.proc stop];
}

static void test_windowed_keys_and_ime_reach_a_field(void) {
  Engine *e = start_engine();
  // The title is the field's value, with * while a composition is open.
  NSString *sid = [e open:data_url(@"<title>field</title><input autofocus><script>"
                                   @"const f = document.querySelector('input'); let c = '';"
                                   @"const show = () => setTimeout(() => document.title = f.value + c);"
                                   @"f.oninput = show;"
                                   @"f.addEventListener('compositionstart', () => { c = '*'; show(); });"
                                   @"f.addEventListener('compositionend', () => { c = ''; show(); });</script>")
                transport:kWindowed];
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return titled(s, @"field"); }], "page loaded");
  Host *h = attach_windowed(e, sid);
  bowser_host_focus(h.handle, true);
  type_into(h, "o");
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return [s[@"title"] isEqual:@"o"]; }], "a key press types");
  text(h, BOWSER_TEXT_SET_MARKED, "かな");
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return [s[@"title"] isEqual:@"oかな*"]; }],
        "marked text is a composition: %s", [[e.log valueForKey:@"title"] componentsJoinedByString:@"|"].UTF8String);
  CHECK(wait_for(^{ return (BOOL)(h.composing && h.compositionRects.count > 0); }, 3),
        "the host hears where the composition is");
  text(h, BOWSER_TEXT_INSERT, "仮名");
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return [s[@"title"] isEqual:@"o仮名"]; }],
        "the commit replaces the composition and ends it: %s", e.log.lastObject.description.UTF8String);
  CHECK(wait_for(^{ return (BOOL)!h.composing; }, 3), "and the host hears the composition ended");
  detach(h);
  [e.proc stop];
}

// Windowed opens start from a page the engine made ahead. Opens back to back
// (the second finds the next one still being made) each show their own page,
// as the first entry of their history.
static void test_windowed_opens_back_to_back_are_fresh_pages(void) {
  Engine *e = start_engine();
  NSString *a = [e open:data_url(@"<title>one</title>") transport:kWindowed];
  NSString *b = [e open:data_url(@"<title>two</title>") transport:kWindowed];
  CHECK([e state:a where:^BOOL(NSDictionary *s) { return titled(s, @"one"); }], "the first open shows its page");
  CHECK([e state:b where:^BOOL(NSDictionary *s) { return titled(s, @"two"); }], "the second shows its own");
  for (NSString *sid in @[ a, b ]) {
    NSDictionary *last = states_of(e, sid, 0).lastObject;
    CHECK(![last[@"can_go_back"] boolValue], "with nothing to go back to: %s", last.description.UTF8String);
  }
  [e.proc stop];
}

// A key's press and its text are two messages, and a busy page can see them in
// separate deliveries, as typing in a Rex pane does. Each key still types once.
static void test_windowed_split_key_and_text_type_once(void) {
  Engine *e = start_engine();
  NSString *sid = [e open:data_url(@"<title>field</title><input autofocus><script>"
                                   @"const f = document.querySelector('input');"
                                   @"f.oninput = () => setTimeout(() => document.title = f.value);</script>")
                transport:kWindowed];
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return titled(s, @"field"); }], "page loaded");
  Host *h = attach_windowed(e, sid);
  bowser_host_focus(h.handle, true);
  const char *word = "crab";
  const uint16_t codes[] = {8, 15, 0, 11}; // the US key codes for c, r, a, b
  for (int i = 0; word[i]; i++) {
    char one[2] = {word[i], 0};
    bowser_key_s k = {.action = BOWSER_KEY_PRESS, .keycode = codes[i], .text = one, .unmodified_text = one};
    bowser_host_key(h.handle, &k);
    pump(0.05); // the press reaches the engine before its text, as a slow IME makes it
    text(h, BOWSER_TEXT_INSERT, one);
    k.action = BOWSER_KEY_RELEASE;
    bowser_host_key(h.handle, &k);
  }
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return [s[@"title"] isEqual:@"crab"]; }],
        "typing crab types crab: %s", [[e.log valueForKey:@"title"] componentsJoinedByString:@"|"].UTF8String);
  detach(h);
  [e.proc stop];
}

static NSString *const kSelect = @"<title>pick</title><body style='margin:0'>"
                                 @"<select style='position:absolute;left:10px;top:10px;width:150px;height:30px' "
                                 @"onchange='document.title=this.value'>"
                                 @"<option>a</option><option>b</option><option disabled>x</option><option>c</option>"
                                 @"</select>";

// A <select>'s list is the host's native menu; the producer's never shows.
static void test_windowed_select_is_a_host_menu(void) {
  Engine *e = start_engine();
  NSString *sid = [e open:data_url(kSelect) transport:kWindowed];
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return titled(s, @"pick"); }], "page loaded");
  Host *h = attach_windowed(e, sid);
  bowser_host_focus(h.handle, true);
  NSUInteger mark = h.messages.count;
  click_button(h, 60, 25, 0);
  NSDictionary *menu = wait_menu(h, mark);
  CHECK([menu[@"kind"] isEqual:@"select"], "clicking the select asks the host for a menu: %s",
        menu.description.UTF8String);
  NSArray *labels = [menu[@"items"] valueForKey:@"label"];
  CHECK([labels isEqual:(@[ @"a", @"b", @"x", @"c" ])], "with the options: %s", labels.description.UTF8String);
  CHECK([menu[@"selected"] intValue] == 0, "the current one selected");
  CHECK(![menu[@"items"][2][@"enabled"] boolValue] && [menu[@"items"][3][@"enabled"] boolValue],
        "and disabled options disabled");
  CHECK(fabs([menu[@"x"] doubleValue] - 10) < 2 && fabs([menu[@"y"] doubleValue] - 10) < 2,
        "at the select's top-left corner: %.1f, %.1f", [menu[@"x"] doubleValue], [menu[@"y"] doubleValue]);
  CHECK(!engine_window_on_screen(e), "and while it is open, no window of the engine is on screen");
  answer(h, menu, 3);
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return [s[@"title"] isEqual:@"c"]; }],
        "the host's choice changes the select: %s", e.log.lastObject.description.UTF8String);

  mark = h.messages.count;
  click_button(h, 60, 25, 0);
  menu = wait_menu(h, mark);
  CHECK([menu[@"selected"] intValue] == 3, "the next menu has the new value selected: %s",
        menu.description.UTF8String);
  NSUInteger states = states_of(e, sid, 0).count;
  answer(h, menu, -1);
  pump(0.5);
  [e read:0.1];
  CHECK(states_of(e, sid, 0).count == states, "dismissing it changes nothing");

  // A host that leaves with a menu open must not leave the page stuck in it.
  mark = h.messages.count;
  click_button(h, 60, 25, 0);
  CHECK(wait_menu(h, mark), "a third menu");
  detach(h);
  Host *next = attach_windowed(e, sid);
  bowser_host_focus(next.handle, true);
  click_button(next, 60, 25, 0);
  menu = wait_menu(next, 0);
  CHECK(menu, "after its host left, the page opens menus for the next host");
  answer(next, menu, 1);
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return [s[@"title"] isEqual:@"b"]; }], "and takes the answer");
  detach(next);
  [e.proc stop];
}

// Right click, in both modes: the host shows the page's context menu.
static void context_menu_goes_back(NSString *transport) {
  Engine *e = start_engine();
  NSString *sid = [e open:data_url(kPageA) transport:transport];
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return titled(s, @"A"); }], "A loaded");
  [e message:@"navigate" to:sid body:@{@"url" : data_url(kPageB)}];
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return titled(s, @"B"); }], "B loaded");
  Host *h = attach_windowed(e, sid);
  bowser_host_focus(h.handle, true);
  NSUInteger mark = h.messages.count;
  click_button(h, 100, 80, 1);
  NSDictionary *menu = wait_menu(h, mark);
  CHECK([menu[@"kind"] isEqual:@"context"] && [menu[@"selected"] intValue] == -1,
        "a right click asks the host for a context menu: %s", menu.description.UTF8String);
  CHECK(fabs([menu[@"x"] doubleValue] - 100) < 2 && fabs([menu[@"y"] doubleValue] - 80) < 2,
        "at the click: %.1f, %.1f", [menu[@"x"] doubleValue], [menu[@"y"] doubleValue]);
  int back = index_of(menu, @"Back");
  CHECK(back >= 0 && index_of(menu, @"Reload") >= 0 && index_of(menu, @"Print") < 0,
        "with Back and Reload, and nothing that opens a window: %s", menu.description.UTF8String);
  answer(h, menu, back);
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return titled(s, @"A"); }], "choosing Back goes back");
  CHECK(!engine_window_on_screen(e), "no window of the engine came on screen");
  detach(h);
  [e.proc stop];
}

static void test_context_menu_windowed(void) { context_menu_goes_back(kWindowed); }
static void test_context_menu_osr(void) { context_menu_goes_back(@"iosurface"); }

static void test_windowed_surfaces_are_isolated(void) {
  Engine *e = start_engine();
  NSString *a = [e open:data_url([NSString stringWithFormat:kField, @"a"]) transport:kWindowed];
  NSString *b = [e open:data_url(kSelect) transport:kWindowed];
  CHECK([e state:a where:^BOOL(NSDictionary *s) { return titled(s, @"a"); }], "a loaded");
  CHECK([e state:b where:^BOOL(NSDictionary *s) { return titled(s, @"pick"); }], "b loaded");
  Host *ha = attach_windowed(e, a), *hb = attach_windowed(e, b);
  bowser_host_focus(ha.handle, true);
  bowser_host_focus(hb.handle, true);

  NSUInteger mark = e.log.count;
  type_into(ha, "x");
  CHECK([e state:a where:^BOOL(NSDictionary *s) { return [s[@"title"] isEqual:@"x"]; }], "typing reaches a's field");
  click_button(hb, 60, 25, 0);
  NSDictionary *menu = wait_menu(hb, 0);
  CHECK(menu, "b's select opens a menu on b's host");
  CHECK(!menu_after(ha, 0), "and not on a's");
  answer(hb, menu, 1);
  CHECK([e state:b where:^BOOL(NSDictionary *s) { return [s[@"title"] isEqual:@"b"]; }], "b takes its answer");
  CHECK(![states_of(e, a, mark).lastObject[@"title"] isEqual:@"b"], "a's page is untouched");

  [e call:@{@"cmd" : @"close", @"surface" : a}];
  CHECK(wait_for(^{ return ha.detached; }, 3), "closing a detaches a's host");
  CHECK(!hb.detached, "and not b's");
  mark = hb.messages.count;
  click_button(hb, 60, 25, 0);
  menu = wait_menu(hb, mark);
  answer(hb, menu, 3);
  CHECK([e state:b where:^BOOL(NSDictionary *s) { return [s[@"title"] isEqual:@"c"]; }], "b still takes input");
  detach(ha);
  detach(hb);
  [e.proc stop];
}

// A date picker is a popup widget: its own window in Chromium, which must
// show over the page and take the clicks over it, as in OSR.
static void test_windowed_date_picker_takes_clicks(void) {
  Engine *e = start_engine();
  NSString *sid = [e open:data_url(@"<title>date</title><body style='margin:0'><input type=date "
                                   @"style='position:absolute;left:10px;top:10px;width:200px;height:30px' "
                                   @"onclick='this.showPicker()' onchange='document.title=this.value'>")
                transport:kWindowed];
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return titled(s, @"date"); }], "page loaded");
  Host *h = attach_windowed(e, sid);
  bowser_host_focus(h.handle, true);
  click_button(h, 60, 25, 0);
  pump(1); // the picker opens below the field
  CHECK(!engine_window_on_screen(e), "the picker's window stays off screen");
  click_button(h, 110, 170, 0); // a day, in the picker's grid
  NSDictionary *s = [e state:sid where:^BOOL(NSDictionary *s) {
    return [s[@"title"] rangeOfString:@"^\\d{4}-\\d\\d-\\d\\d$" options:NSRegularExpressionSearch].location != NSNotFound;
  }];
  CHECK(s, "a click on a day in the picker picks it: %s", e.log.lastObject.description.UTF8String);
  detach(h);
  [e.proc stop];
}

// Dragging a link out of a windowed page would put a drag image on the
// user's screen. The drag ends at once instead, and the page goes on.
static void test_windowed_drag_ends_at_once(void) {
  Engine *e = start_engine();
  NSString *sid = [e open:data_url(@"<title>drag</title><body style='margin:0'>"
                                   @"<a href='https://example.com' style='font-size:40px'>link</a><script>"
                                   @"let n = 0; onmousedown = () => document.title = 'down ' + ++n;"
                                   @"ondragend = () => document.title = 'dragend';</script>")
                transport:kWindowed];
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return titled(s, @"drag"); }], "page loaded");
  Host *h = attach_windowed(e, sid);
  bowser_host_focus(h.handle, true);
  bowser_mouse_s m = {.action = BOWSER_MOUSE_DOWN, .x = 30, .y = 25, .click_count = 1};
  bowser_host_mouse(h.handle, &m);
  for (int i = 1; i <= 20; i++) {
    pump(0.02);
    m = (bowser_mouse_s){.action = BOWSER_MOUSE_DRAG, .x = 30 + i * 10, .y = 25 + i * 5};
    bowser_host_mouse(h.handle, &m);
  }
  m = (bowser_mouse_s){.action = BOWSER_MOUSE_UP, .x = 230, .y = 125, .click_count = 1};
  bowser_host_mouse(h.handle, &m);
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return [s[@"title"] isEqual:@"dragend"]; }],
        "the drag ends: %s", [[e.log valueForKey:@"title"] componentsJoinedByString:@"|"].UTF8String);
  CHECK(!engine_window_on_screen(e), "with nothing on screen");
  click_button(h, 200, 150, 0);
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return [s[@"title"] isEqual:@"down 2"]; }],
        "and the page takes clicks again");
  detach(h);
  [e.proc stop];
}

// What a user sees: real bowser-host windows, on the Mission Control Space
// that BOWSER_SPACE names, captured window by window. Each windowed surface
// must show its own page: the mirrors are per tab. Skipped without
// BOWSER_SPACE, since it opens windows; the terminal needs Screen Recording.
static rgb captured_center(int window) {
  NSString *path = [NSTemporaryDirectory() stringByAppendingFormat:@"bowser-capture-%d.png", window];
  NSTask *t = [NSTask launchedTaskWithLaunchPath:@"/usr/sbin/screencapture"
                                       arguments:@[ @"-x", @"-o", @"-l", @(window).stringValue, path ]];
  [t waitUntilExit];
  CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
  CGImageRef image = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
  rgb c = {0};
  if (image) {
    uint8_t px[4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(px, 1, 1, 8, 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    CGContextDrawImage(ctx, CGRectMake(-(double)w / 2, -(double)h / 2, w, h), image);
    c = (rgb){px[0], px[1], px[2]};
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    CGImageRelease(image);
  }
  if (src) CFRelease(src);
  [NSFileManager.defaultManager removeItemAtPath:path error:nil];
  return c;
}

static void test_windowed_hosts_show_their_own_pages(void) {
  NSString *space = NSProcessInfo.processInfo.environment[@"BOWSER_SPACE"];
  if (!space) {
    printf("     (skipped: set BOWSER_SPACE to a Space for host windows)\n");
    return;
  }
  Engine *e = start_engine();
  NSString *pages[2] = {@"<body style='margin:0;background:rgb(255,0,255)'>",
                        @"<body style='margin:0;background:rgb(0,255,255)'>"};
  Producer *hosts[2];
  int windows[2] = {0};
  for (int i = 0; i < 2; i++) {
    NSString *sid = [e open:data_url(pages[i]) transport:kWindowed];
    hosts[i] = [Producer spawn:@[ @"build/bowser-host", [e ticket:sid] ] tickets:0 env:@{@"BOWSER_SPACE" : space}];
    NSString *line = [hosts[i] nextLine:10];
    windows[i] = [line hasPrefix:@"window="] ? [[line substringFromIndex:7] intValue] : 0;
    CHECK(windows[i], "bowser-host %d has a window: %s", i, line.UTF8String);
  }
  __block rgb a, b;
  int first = windows[0], second = windows[1];
  BOOL shown = wait_for(^{
    a = captured_center(first);
    b = captured_center(second);
    return (BOOL)(near(a, MAGENTA) && near(b, CYAN));
  }, 10);
  CHECK(shown, "each host shows its own page: (%d,%d,%d) and (%d,%d,%d)", a.r, a.g, a.b, b.r, b.g, b.b);
  CHECK(!engine_window_on_screen(e), "and the engine shows no window of its own");
  for (int i = 0; i < 2; i++) [hosts[i] stop];
  [e.proc stop];
}

static void remove_profiles(void) {
  for (NSString *path in profiles) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

// The browser is part of its host app: a link that opens a window asks the
// controller for a new pane (a page alone can't), and Send to Agent hands
// the controller what was right-clicked. The page stays where it was.
static void test_new_windows_and_send_to_agent_reach_the_controller(void) {
  Engine *e = start_engine();
  NSString *sid = [e open:data_url(@"<title>Links</title><body style='margin:0'>"
                                    "<a target=_blank href='https://example.com/new' "
                                    "style='display:block;width:200px;height:40px'>New</a>"
                                    "<script>setTimeout(() => { open('https://example.com/spam'); document.title = 'Tried' }, 200)"
                                    "</script>")
                transport:kWindowed];
  CHECK([e state:sid where:^BOOL(NSDictionary *s) { return titled(s, @"Tried"); }], "the page loaded and tried a popup");
  Host *h = attach_windowed(e, sid);
  bowser_host_focus(h.handle, true);
  BOOL (^popup)(NSDictionary *) = ^BOOL(NSDictionary *ev) {
    return [ev[@"event"] isEqual:@"popup"] && [ev[@"surface"] isEqual:sid];
  };

  click_button(h, 50, 20, 0);
  NSDictionary *ev = [e wait:popup within:5];
  CHECK([ev[@"url"] isEqual:@"https://example.com/new"] && [ev[@"foreground"] boolValue],
        "clicking a target=_blank link asks for a new pane, in front: %s", ev.description.UTF8String);
  for (NSDictionary *seen in e.log)
    CHECK(![seen[@"url"] hasSuffix:@"/spam"], "a popup the page opened on its own is blocked: %s",
          seen.description.UTF8String);
  NSDictionary *href = [e call:@{@"cmd" : @"cdp", @"surface" : sid, @"method" : @"Runtime.evaluate",
                                 @"params" : @{@"expression" : @"location.protocol", @"returnByValue" : @YES}}];
  CHECK([href[@"result"][@"result"][@"value"] isEqual:@"data:"], "and the page stays: %s", href.description.UTF8String);

  NSUInteger mark = h.messages.count;
  click_button(h, 50, 20, 1);
  NSDictionary *menu = wait_menu(h, mark);
  int send = index_of(menu, @"Send to Agent"), pane = index_of(menu, @"Open Link in New Pane");
  CHECK(send >= 0 && pane >= 0, "a link's menu can send it to the agent or open it in a new pane: %s",
        menu.description.UTF8String);
  answer(h, menu, send);
  ev = [e wait:^BOOL(NSDictionary *x) { return [x[@"event"] isEqual:@"send_to_agent"]; } within:5];
  CHECK(fabs([ev[@"x"] doubleValue] - 50) < 2 && fabs([ev[@"y"] doubleValue] - 20) < 2,
        "Send to Agent tells the controller where the click was: %s", ev.description.UTF8String);

  mark = h.messages.count;
  click_button(h, 50, 20, 1);
  menu = wait_menu(h, mark);
  answer(h, menu, index_of(menu, @"Open Link in New Pane"));
  ev = [e wait:popup within:5];
  CHECK([ev[@"url"] isEqual:@"https://example.com/new"], "Open Link in New Pane asks for one: %s",
        ev.description.UTF8String);
  detach(h);
  [e.proc stop];
}

int main(void) {
  @autoreleasepool {
    test_case tests[] = {
        {"a host that takes over a finished page sees it", test_new_host_sees_a_finished_page},
        {"after a resize the page fills the new size", test_resize_fills_the_new_size},
        {"scrolling the host scrolls the page", test_scroll_moves_the_page},
        {"key presses and IME text reach a focused field", test_typing_reaches_a_focused_field},
        {"the cursor follows what the page is under", test_cursor_follows_the_page},
        {"navigation reports url, title, and history", test_navigation_reports_state},
        {"a typed host gets a scheme", test_typed_hosts_get_a_scheme},
        {"copy puts the selection on the pasteboard", test_copy_puts_the_selection_on_the_pasteboard},
        {"find counts matches", test_find_counts_matches},
        {"surfaces in one engine are isolated", test_surfaces_in_one_engine_are_isolated},
        {"the engine's death reaches every host", test_engine_death_reaches_every_host},
        {"the engine exits when its controller goes", test_engine_exits_when_its_controller_goes},
        {"a <select> popup shows over the page", test_select_popup_shows},
        {"windowed: navigation reports url, title, and history", test_windowed_navigation_reports_state},
        {"windowed: a tab with no host is hidden", test_windowed_tab_without_a_host_is_hidden},
        {"windowed: key presses and IME text reach a field", test_windowed_keys_and_ime_reach_a_field},
        {"windowed: a press and its text, delivered apart, type once", test_windowed_split_key_and_text_type_once},
        {"windowed: opens back to back are fresh pages", test_windowed_opens_back_to_back_are_fresh_pages},
        {"windowed: a <select> is the host's menu", test_windowed_select_is_a_host_menu},
        {"windowed: a context menu is the host's menu", test_context_menu_windowed},
        {"osr: a context menu is the host's menu", test_context_menu_osr},
        {"windowed: surfaces in one engine are isolated", test_windowed_surfaces_are_isolated},
        {"windowed: a date picker takes clicks", test_windowed_date_picker_takes_clicks},
        {"windowed: a drag out of the page ends at once", test_windowed_drag_ends_at_once},
        {"windowed: real hosts show their own pages", test_windowed_hosts_show_their_own_pages},
        {"new windows and Send to Agent reach the controller", test_new_windows_and_send_to_agent_reach_the_controller},
    };
    atexit(remove_profiles);
    return run_tests(tests, sizeof tests / sizeof *tests);
  }
}
