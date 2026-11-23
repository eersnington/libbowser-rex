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
  NSDictionary *r = [self call:@{@"cmd" : @"open", @"url" : url, @"transport" : @"iosurface"}];
  CHECK(r[@"surface"], "open: %s", r.description.UTF8String);
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

static void remove_profiles(void) {
  for (NSString *path in profiles) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
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
    };
    atexit(remove_profiles);
    return run_tests(tests, sizeof tests / sizeof *tests);
  }
}
