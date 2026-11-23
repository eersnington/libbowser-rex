#include "internal.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

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

bool bw_copy_config(void *dst, size_t dst_size, const void *src, size_t min_size) {
  size_t size;
  memcpy(&size, src, sizeof size); // every config struct starts with its size
  if (size < min_size) return false;
  memset(dst, 0, dst_size);
  memcpy(dst, src, size < dst_size ? size : dst_size);
  return true;
}

uint64_t bw_now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

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

#define NAME_MAX_LEN 64

static bool valid_name(const char *name) {
  size_t n = name ? strlen(name) : 0;
  if (n == 0 || n > NAME_MAX_LEN) return false;
  for (size_t i = 0; i < n; i++) {
    char c = name[i];
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.' ||
          c == '-'))
      return false;
  }
  return true;
}

bowser_result_e bw_put_message(bw_buf *b, const char *name, const char *body) {
  if (!valid_name(name)) return bw_fail(BOWSER_ERR_INVALID, "message name must be 1-%d of [A-Za-z0-9_.-]", NAME_MAX_LEN);
  size_t n = body ? strlen(body) : 0;
  if (n > BOWSER_MESSAGE_MAX)
    return bw_fail(BOWSER_ERR_INVALID, "message body is %zu bytes; the limit is %d", n, BOWSER_MESSAGE_MAX);
  bw_put_str(b, name);
  bw_put_u8(b, body != NULL);
  bw_put_str(b, body);
  return BOWSER_OK;
}

bool bw_get_message(bw_rd *r, char **name, char **body) {
  *name = bw_get_str(r);
  bool has = bw_get_u8(r);
  char *b = bw_get_str(r);
  // The peer is checked the same way, so this only catches a broken one.
  if (r->err || !valid_name(*name) || strlen(b) > BOWSER_MESSAGE_MAX) {
    free(*name);
    free(b);
    *name = *body = NULL;
    return false;
  }
  if (!has) {
    free(b);
    b = NULL;
  }
  *body = b;
  return true;
}
