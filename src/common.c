#include "internal.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

static _Thread_local char last_error[512];

bowser_result_e bw_fail(bowser_result_e code, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(last_error, sizeof last_error, fmt, ap);
  va_end(ap);
  return code;
}

uint32_t bowser_abi_version(void) { return BOWSER_ABI_VERSION; }
const char *bowser_last_error(void) { return last_error; }
void bowser_string_free(char *s) { free(s); }

void bw_put_size(bw_buf *b, bowser_size_s s) {
  bw_put_f64(b, s.width);
  bw_put_f64(b, s.height);
  bw_put_f64(b, s.scale);
}

bowser_size_s bw_get_size(bw_rd *r) {
  bowser_size_s s;
  s.width = bw_get_f64(r);
  s.height = bw_get_f64(r);
  s.scale = bw_get_f64(r);
  return s;
}

void bw_put_rect(bw_buf *b, bowser_rect_s v) {
  bw_put_f64(b, v.x);
  bw_put_f64(b, v.y);
  bw_put_f64(b, v.width);
  bw_put_f64(b, v.height);
}

bowser_rect_s bw_get_rect(bw_rd *r) {
  bowser_rect_s v;
  v.x = bw_get_f64(r);
  v.y = bw_get_f64(r);
  v.width = bw_get_f64(r);
  v.height = bw_get_f64(r);
  return v;
}
