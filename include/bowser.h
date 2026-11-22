// libbowser: show another process's live, native UI as a layer.
//
// A producer owns an engine and its rendering. A host mounts the producer's
// output as a CALayer and sends input back. See SPEC.md.
//
// ABI version 0: no compatibility promise until 1.0.
#ifndef BOWSER_H
#define BOWSER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <IOSurface/IOSurfaceRef.h>

#ifdef __OBJC__
@class CALayer;
#else
typedef struct CALayer CALayer;
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define BOWSER_ABI_VERSION 0

typedef enum {
  BOWSER_OK = 0,
  BOWSER_ERR_INVALID,
  BOWSER_ERR_TICKET,       // expired, used, or unknown ticket
  BOWSER_ERR_TRANSPORT,    // transport failed or isn't supported here
  BOWSER_ERR_DISCONNECTED, // the other side went away
  BOWSER_ERR_REPLACED,     // another host attached to the surface
  BOWSER_ERR_STALLED,      // the other side stopped reading, so the library dropped it
} bowser_result_e;

typedef enum {
  BOWSER_TRANSPORT_CALAYERHOST = 0, // producer commits layers; host shows them by context ID
  BOWSER_TRANSPORT_IOSURFACE = 1,   // producer sends IOSurfaces; host sets layer contents
} bowser_transport_e;

// Geometry is in points with a top-left origin.
typedef struct { double width, height, scale; } bowser_size_s;
typedef struct { double x, y, width, height; } bowser_rect_s;

// ---- Input ----------------------------------------------------------
//
// timestamp_ns is when the event happened, in CLOCK_UPTIME_RAW nanoseconds:
// the clock behind NSEvent.timestamp (seconds) and CACurrentMediaTime(), so
// pass `(uint64_t)(event.timestamp * 1e9)`. 0 means "now": the library stamps
// the event when you send it.

typedef enum { BOWSER_KEY_PRESS, BOWSER_KEY_RELEASE, BOWSER_KEY_REPEAT } bowser_key_action_e;

typedef struct {
  bowser_key_action_e action;
  uint16_t keycode;            // macOS virtual key code
  uint64_t mods;               // NSEventModifierFlags
  const char *text;            // UTF-8 `characters`, may be NULL
  const char *unmodified_text; // UTF-8 `charactersIgnoringModifiers`, may be NULL
  uint64_t timestamp_ns;
} bowser_key_s;

typedef enum {
  BOWSER_MOUSE_DOWN,
  BOWSER_MOUSE_UP,
  BOWSER_MOUSE_MOVE,
  BOWSER_MOUSE_DRAG,
  BOWSER_MOUSE_EXIT,
} bowser_mouse_action_e;

typedef struct {
  bowser_mouse_action_e action;
  int32_t button; // 0 left, 1 right, 2 middle
  double x, y;
  int32_t click_count;
  uint64_t mods;
  uint64_t timestamp_ns;
} bowser_mouse_s;

typedef struct {
  double dx, dy;
  bool precise;          // trackpad pixels, not lines
  int32_t phase;         // NSEventPhase
  int32_t momentum_phase; // NSEventPhase
  double x, y;
  uint64_t mods;
  uint64_t timestamp_ns;
} bowser_scroll_s;

typedef enum { BOWSER_TEXT_INSERT, BOWSER_TEXT_SET_MARKED, BOWSER_TEXT_UNMARK } bowser_text_kind_e;

// Mirrors NSTextInputClient. A location of -1 means NSNotFound.
typedef struct {
  bowser_text_kind_e kind;
  const char *text; // UTF-8, may be NULL for UNMARK
  int64_t selected_location, selected_length;
  int64_t replacement_location, replacement_length;
} bowser_text_s;

typedef enum {
  BOWSER_CURSOR_ARROW,
  BOWSER_CURSOR_IBEAM,
  BOWSER_CURSOR_POINTER,
  BOWSER_CURSOR_CROSSHAIR,
  BOWSER_CURSOR_NOT_ALLOWED,
  BOWSER_CURSOR_RESIZE_LEFT_RIGHT,
  BOWSER_CURSOR_RESIZE_UP_DOWN,
} bowser_cursor_e;

// ---- Conventions ----------------------------------------------------
//
// Threading: each producer or host belongs to one thread, the embedder's.
// Call its functions only on that thread. The library calls wakeup_cb from
// any thread; wakeup_cb must not block or call into the library. It should
// only schedule a call to *_tick() on the embedder's thread. Every other
// callback runs inside *_tick(). bowser_abi_version, bowser_last_error, and
// bowser_string_free are safe on any thread.
//
// Pointers a callback receives (strings, rect arrays, input structs) are valid
// only until the callback returns. Copy what you keep.
//
// Errors: a function that returns a bowser_result_e other than BOWSER_OK
// also sets bowser_last_error() on the calling thread.
//
// Sending: send functions never block. They queue the message and return.
// Messages over 1 MiB are refused with BOWSER_ERR_INVALID. If the other side
// stops reading for long enough that 4 MiB queue up, the library drops it and
// reports BOWSER_ERR_STALLED. Latest-wins messages (resize, mouse move and
// drag, caret, composition, cursor) replace older unsent ones of the same
// kind, so a stalled peer costs a slot each, not a queue.
//
// Config structs start with a size field and only grow at the end. Pass
// sizeof your struct. The library accepts any size from the *_MIN_SIZE
// constant up and zero-fills the fields a smaller struct lacks.

uint32_t bowser_abi_version(void);
// The message for the latest failed call on the calling thread, or "".
// Successful calls don't clear it. The text changes on the next failure.
const char *bowser_last_error(void);
void bowser_string_free(char *);

// ---- Producer side --------------------------------------------------
//
// Free surfaces before their producer. If the producer goes first, its
// surface handles stay valid but inert: calls on them do nothing or return
// BOWSER_ERR_DISCONNECTED. Free them with bowser_surface_free all the same.
// Freeing a surface, or the producer, from inside a callback is fine: the
// freed surfaces get no more callbacks.

typedef struct bowser_producer bowser_producer_t;
typedef struct bowser_surface bowser_surface_t;

typedef struct {
  size_t size; // sizeof(bowser_producer_config_s)
  bowser_transport_e transport;
  void *userdata;
  void (*wakeup_cb)(void *userdata);
  void (*key_cb)(void *ud, bowser_surface_t *, const bowser_key_s *);
  void (*mouse_cb)(void *ud, bowser_surface_t *, const bowser_mouse_s *);
  void (*scroll_cb)(void *ud, bowser_surface_t *, const bowser_scroll_s *);
  void (*text_cb)(void *ud, bowser_surface_t *, const bowser_text_s *);
  void (*resize_cb)(void *ud, bowser_surface_t *, bowser_size_s);
  void (*focus_cb)(void *ud, bowser_surface_t *, bool focused);
  void (*attach_cb)(void *ud, bowser_surface_t *, bool attached);
} bowser_producer_config_s;

// In 0.x the minimum is the whole struct. From 1.0 it is frozen at the 1.0 layout.
#define BOWSER_PRODUCER_CONFIG_MIN_SIZE \
  (offsetof(bowser_producer_config_s, attach_cb) + sizeof(((bowser_producer_config_s *)0)->attach_cb))

bowser_result_e bowser_producer_new(const bowser_producer_config_s *, bowser_producer_t **out);
void bowser_producer_free(bowser_producer_t *);
void bowser_producer_tick(bowser_producer_t *);

bowser_result_e bowser_surface_new(bowser_producer_t *, bowser_size_s, bowser_surface_t **out);
void bowser_surface_free(bowser_surface_t *);
bowser_size_s bowser_surface_size(bowser_surface_t *);
// A fresh ticket. It works once, within 60 s. Attaching with it replaces the
// surface's current host; other unused tickets keep working until they
// expire. Free it with bowser_string_free. NULL after the producer is freed.
char *bowser_surface_ticket(bowser_surface_t *);

// CALAYERHOST: the root of the layer tree the host shows. It has a top-left
// origin, and the library sets its bounds on resize. NULL on IOSURFACE.
CALayer *bowser_surface_root_layer(bowser_surface_t *);
// IOSURFACE: hand a finished frame to the host. Don't draw into the surface
// again while IOSurfaceIsInUse() is true: the host keeps it in use from this
// call until it shows a newer frame. Drops the frame if the host is behind or
// no host is attached.
bowser_result_e bowser_surface_present(bowser_surface_t *, IOSurfaceRef, bowser_rect_s dirty);

// Text input state, so the host can place the IME window. Each returns
// BOWSER_ERR_DISCONNECTED when no host is attached.
bowser_result_e bowser_surface_set_caret(bowser_surface_t *, bowser_rect_s caret);
bowser_result_e bowser_surface_set_composition(bowser_surface_t *, bool active, const bowser_rect_s *char_rects,
                                               size_t count);
bowser_result_e bowser_surface_set_cursor(bowser_surface_t *, bowser_cursor_e);

// ---- Host side ------------------------------------------------------
//
// bowser_host_attach blocks for at most 3 s. bowser_host_detach frees the
// handle at once, so a tick you scheduled from wakeup_cb before the detach
// must check that the host still exists. Detaching from inside a callback is
// fine: the host gets no more callbacks.

typedef struct bowser_host bowser_host_t;

typedef struct {
  size_t size; // sizeof(bowser_host_config_s)
  void *userdata;
  void (*wakeup_cb)(void *userdata);
  void (*caret_cb)(void *ud, bowser_host_t *, bowser_rect_s caret);
  void (*composition_cb)(void *ud, bowser_host_t *, bool active, const bowser_rect_s *char_rects,
                         size_t count);
  void (*cursor_cb)(void *ud, bowser_host_t *, bowser_cursor_e);
  void (*detached_cb)(void *ud, bowser_host_t *, bowser_result_e why);
} bowser_host_config_s;

// In 0.x the minimum is the whole struct. From 1.0 it is frozen at the 1.0 layout.
#define BOWSER_HOST_CONFIG_MIN_SIZE \
  (offsetof(bowser_host_config_s, detached_cb) + sizeof(((bowser_host_config_s *)0)->detached_cb))

bowser_result_e bowser_host_attach(const char *ticket, const bowser_host_config_s *, bowser_host_t **out);
void bowser_host_detach(bowser_host_t *);
void bowser_host_tick(bowser_host_t *);
bowser_transport_e bowser_host_transport(bowser_host_t *);

// Mount this in any view. Set its frame like any layer, then call resize.
CALayer *bowser_host_layer(bowser_host_t *);

// Each returns BOWSER_ERR_DISCONNECTED once the producer is gone.
bowser_result_e bowser_host_resize(bowser_host_t *, bowser_size_s);
bowser_result_e bowser_host_focus(bowser_host_t *, bool focused);
bowser_result_e bowser_host_key(bowser_host_t *, const bowser_key_s *);
bowser_result_e bowser_host_mouse(bowser_host_t *, const bowser_mouse_s *);
bowser_result_e bowser_host_scroll(bowser_host_t *, const bowser_scroll_s *);
bowser_result_e bowser_host_text(bowser_host_t *, const bowser_text_s *);

#ifdef __cplusplus
}
#endif

#endif
