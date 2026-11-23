// Control channel between a producer and a host: framed messages over a Unix
// stream socket. Frames are a u32 payload length, a u16 type, then the payload.
// Numbers are little-endian. Strings are a u32 length, then UTF-8 bytes.
#ifndef BOWSER_WIRE_H
#define BOWSER_WIRE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define BW_TICKET_PREFIX "bowser2:" // bump when the wire format changes
#define BW_TOKEN_LEN 32
#define BW_MAX_FRAME (1u << 20)  // largest payload either side sends or accepts
#define BW_MAX_QUEUED (4u << 20) // unsent bytes a connection holds before it drops the peer as stalled

typedef enum {
  // host -> producer
  BW_MSG_HELLO = 1, // str token
  BW_MSG_RESIZE,    // f64 w, h, scale
  BW_MSG_FOCUS,     // u8
  BW_MSG_KEY,       // u32 action, u32 keycode, u64 mods, str text, str unmodified, u64 timestamp
  BW_MSG_MOUSE,     // u32 action, i32 button, f64 x, y, i32 clicks, u64 mods, u64 timestamp
  BW_MSG_SCROLL,    // f64 dx, dy, u8 precise, i32 phase, i32 momentum, f64 x, y, u64 mods, u64 timestamp
  BW_MSG_TEXT,      // u32 kind, str text, i64 sel loc, len, i64 repl loc, len
  BW_MSG_READY,     // empty; the host is set up, so the producer commits the attach
  BW_MSG_MESSAGE,   // str name, u8 has body, str body (BOWSER_MESSAGE_MAX); input, so it keeps its place
  // producer -> host
  BW_MSG_WELCOME = 100, // u32 transport, u32 context id, f64 w, h, scale, str mach service, u64 nonce
  BW_MSG_REJECT,        // u32 bowser_result_e
  BW_MSG_DETACH,        // u32 bowser_result_e
  BW_MSG_CARET,         // f64 x, y, w, h
  BW_MSG_COMPOSITION,   // u8 active, u32 count, count * (f64 x, y, w, h)
  BW_MSG_CURSOR,        // u32 bowser_cursor_e
  BW_MSG_PRODUCER_MESSAGE, // as BW_MSG_MESSAGE
} bw_msg_type;

typedef struct {
  uint8_t *data;
  size_t len, cap;
} bw_buf;

void bw_buf_free(bw_buf *);
void bw_put_u8(bw_buf *, uint8_t);
void bw_put_u32(bw_buf *, uint32_t);
void bw_put_i32(bw_buf *, int32_t);
void bw_put_u64(bw_buf *, uint64_t);
void bw_put_i64(bw_buf *, int64_t);
void bw_put_f64(bw_buf *, double);
void bw_put_str(bw_buf *, const char *); // NULL is written as an empty string

typedef struct {
  const uint8_t *p;
  size_t left;
  bool err;
} bw_rd;

uint8_t bw_get_u8(bw_rd *);
uint32_t bw_get_u32(bw_rd *);
int32_t bw_get_i32(bw_rd *);
uint64_t bw_get_u64(bw_rd *);
int64_t bw_get_i64(bw_rd *);
double bw_get_f64(bw_rd *);
char *bw_get_str(bw_rd *); // malloc'd, NUL-terminated; free it

// Append one whole frame, header and payload, to out.
void bw_put_frame(bw_buf *out, uint16_t type, const bw_buf *payload);

// Frames with the same nonzero kind are latest-wins: a queued one may be
// dropped when a newer one follows. 0 means the frame must arrive.
uint32_t bw_latest_wins_kind(uint16_t type, const bw_buf *payload);

// Read whatever is available into acc. Returns false on EOF or error.
bool bw_recv_some(int fd, bw_buf *acc);
// Pop one complete frame from acc. Returns false if none is complete yet.
// Sets *bad if the stream is corrupt.
bool bw_next_frame(bw_buf *acc, uint16_t *type, bw_buf *payload, bool *bad);

#endif
