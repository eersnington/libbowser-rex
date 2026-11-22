// End-to-end tests for the CEF adapter: a real bowser-cef process loading a
// real page, and hosts in this process on the IOSURFACE transport, so the
// host layer's pixels can be read back. Pages are data: URLs; no network.
#include "harness.h"

static Producer *start_cef(NSString *html, int tickets) {
  NSString *encoded =
      [html stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
  NSArray *argv = @[
    @"build/bowser-cef.app/Contents/MacOS/bowser-cef", @"--transport", @"iosurface", @"--url",
    [@"data:text/html," stringByAppendingString:encoded], @"--tickets", @(tickets).stringValue
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

int main(void) {
  @autoreleasepool {
    test_case tests[] = {
        {"a host that takes over a finished page sees it", test_new_host_sees_a_finished_page},
        {"after a resize the page fills the new size", test_resize_fills_the_new_size},
        {"scrolling the host scrolls the page", test_scroll_moves_the_page},
        {"key presses and IME text reach a focused field", test_typing_reaches_a_focused_field},
        {"the cursor follows what the page is under", test_cursor_follows_the_page},
    };
    return run_tests(tests, sizeof tests / sizeof *tests);
  }
}
