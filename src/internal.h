#ifndef BOWSER_INTERNAL_H
#define BOWSER_INTERNAL_H

#include "../include/bowser.h"
#include "wire.h"

// Set the calling thread's error message and return code.
bowser_result_e bw_fail(bowser_result_e code, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

// Copy a caller's config struct into dst (dst_size bytes), zero-filling the
// fields a smaller, older struct lacks. False if it's below min_size.
bool bw_copy_config(void *dst, size_t dst_size, const void *src, size_t min_size);

// CLOCK_UPTIME_RAW nanoseconds, the input timestamp clock.
uint64_t bw_now_ns(void);

// Encode and decode the structs that cross the wire.
void bw_put_size(bw_buf *, bowser_size_s);
bowser_size_s bw_get_size(bw_rd *);
void bw_put_rect(bw_buf *, bowser_rect_s);
bowser_rect_s bw_get_rect(bw_rd *);

static inline bw_rd bw_reader(const bw_buf *b) { return (bw_rd){.p = b->data, .left = b->len}; }

#endif
