#include "wire.h"

#include "../include/bowser.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void reserve(bw_buf *b, size_t extra) {
  if (b->len + extra <= b->cap) return;
  size_t cap = b->cap ? b->cap : 64;
  while (cap < b->len + extra) cap *= 2;
  b->data = realloc(b->data, cap);
  b->cap = cap;
}

static void put(bw_buf *b, const void *p, size_t n) {
  reserve(b, n);
  memcpy(b->data + b->len, p, n);
  b->len += n;
}

void bw_buf_free(bw_buf *b) {
  free(b->data);
  *b = (bw_buf){0};
}

// arm64 and x86_64 are both little-endian, so raw copies match the wire format.
void bw_put_u8(bw_buf *b, uint8_t v) { put(b, &v, 1); }
void bw_put_u32(bw_buf *b, uint32_t v) { put(b, &v, 4); }
void bw_put_i32(bw_buf *b, int32_t v) { put(b, &v, 4); }
void bw_put_u64(bw_buf *b, uint64_t v) { put(b, &v, 8); }
void bw_put_i64(bw_buf *b, int64_t v) { put(b, &v, 8); }
void bw_put_f64(bw_buf *b, double v) { put(b, &v, 8); }
void bw_put_str(bw_buf *b, const char *s) {
  uint32_t n = s ? (uint32_t)strlen(s) : 0;
  bw_put_u32(b, n);
  if (n) put(b, s, n);
}

static bool get(bw_rd *r, void *out, size_t n) {
  if (r->err || r->left < n) {
    r->err = true;
    memset(out, 0, n);
    return false;
  }
  memcpy(out, r->p, n);
  r->p += n;
  r->left -= n;
  return true;
}

uint8_t bw_get_u8(bw_rd *r) { uint8_t v; get(r, &v, 1); return v; }
uint32_t bw_get_u32(bw_rd *r) { uint32_t v; get(r, &v, 4); return v; }
int32_t bw_get_i32(bw_rd *r) { int32_t v; get(r, &v, 4); return v; }
uint64_t bw_get_u64(bw_rd *r) { uint64_t v; get(r, &v, 8); return v; }
int64_t bw_get_i64(bw_rd *r) { int64_t v; get(r, &v, 8); return v; }
double bw_get_f64(bw_rd *r) { double v; get(r, &v, 8); return v; }

char *bw_get_str(bw_rd *r) {
  uint32_t n = bw_get_u32(r);
  if (r->err || r->left < n) {
    r->err = true;
    return calloc(1, 1);
  }
  char *s = malloc(n + 1);
  memcpy(s, r->p, n);
  s[n] = 0;
  r->p += n;
  r->left -= n;
  return s;
}

void bw_put_frame(bw_buf *out, uint16_t type, const bw_buf *payload) {
  uint32_t len = payload ? (uint32_t)payload->len : 0;
  put(out, &len, 4);
  put(out, &type, 2);
  if (len) put(out, payload->data, len);
}

uint32_t bw_latest_wins_kind(uint16_t type, const bw_buf *payload) {
  switch (type) {
  case BW_MSG_RESIZE:
  case BW_MSG_CARET:
  case BW_MSG_COMPOSITION:
  case BW_MSG_CURSOR:
    return type;
  case BW_MSG_MOUSE: {
    // Moves and drags are positions, so only the newest matters. Clicks and
    // exits must all arrive. Scroll deltas add up, so scrolls aren't merged.
    bw_rd r = {.p = payload->data, .left = payload->len};
    uint32_t action = bw_get_u32(&r);
    if (r.err || (action != BOWSER_MOUSE_MOVE && action != BOWSER_MOUSE_DRAG)) return 0;
    return (uint32_t)type << 8 | action;
  }
  default:
    return 0;
  }
}

bool bw_recv_some(int fd, bw_buf *acc) {
  reserve(acc, 4096);
  for (;;) {
    ssize_t n = read(fd, acc->data + acc->len, acc->cap - acc->len);
    if (n > 0) {
      acc->len += (size_t)n;
      return true;
    }
    if (n < 0 && errno == EINTR) continue;
    if (n < 0 && errno == EAGAIN) return true;
    return false;
  }
}

bool bw_next_frame(bw_buf *acc, uint16_t *type, bw_buf *payload, bool *bad) {
  *bad = false;
  if (acc->len < 6) return false;
  uint32_t len;
  memcpy(&len, acc->data, 4);
  if (len > BW_MAX_FRAME) {
    *bad = true;
    return false;
  }
  if (acc->len < 6 + (size_t)len) return false;
  memcpy(type, acc->data + 4, 2);
  *payload = (bw_buf){0};
  if (len) put(payload, acc->data + 6, len);
  memmove(acc->data, acc->data + 6 + len, acc->len - 6 - len);
  acc->len -= 6 + len;
  return true;
}
