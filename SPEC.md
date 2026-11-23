# libbowser

A C ABI that lets one process show another process's live, native UI.
The first use is a Chromium-class browser running as a Rex tab.

Status: draft, `0.x`. No compatibility promise until `1.0`.

## Why

libghostty-vt moved the hard part of a terminal behind a C ABI. It owns
the terminal state. The host owns the window, the drawing, and the pty.
That split is why several native terminals can exist on one core.

A browser can't split the same way. Its state is rendered pixels plus
input, text input, and accessibility. Today the choices are:

| Choice | Problem |
|---|---|
| Put the engine in the client (WKWebView, CEF windowed) | The client owns the work. That breaks a server-owned model like Rex's. |
| Stream frames (CDP screencast, video) | Lossy, slow, no IME, no accessibility. Not native. |

libbowser is the missing primitive: **the engine runs in a producer
process, and a host mounts its output as a native layer and sends input
back.**

## Goals

- A small, stable C ABI that any language can call (Swift, Go via cgo, Zig, Rust).
- Native fidelity on the same Mac: native frame rate, no copies, no lossy encoding.
- Real text input: marked text, the IME candidate window, press-and-hold accents.
- Engine-agnostic. The host never knows if CEF, Helium, or a test app is behind it.
- Transport-agnostic. The host gets a `CALayer` whatever the transport.

## Non-goals (for 0.x)

- Remote hosts. Pixels over a network need video encoding. A separate spec covers that.
- Accessibility mirroring. It comes after text input works.
- Clipboard, drag and drop, file pickers, permission prompts.
- Browser chrome (tabs, address bar). The host builds its own UI from events.
- Platforms other than macOS.

## Model

| Role | Owns | Example |
|---|---|---|
| **Producer** | The engine, its state, and its rendering | A CEF or Helium process started by the Rex server |
| **Host** | The window, the view, and the user's input | The Rex app |
| **Surface** | One live output plus its input channel | One browser tab |

- One producer can serve many surfaces.
- A surface has at most one host at a time. A new host takes it over, like a Rex client that reconnects.
- The surface keeps running when no host is attached.

### Lifecycle

1. The producer creates a surface and gets a **ticket** (an opaque string).
2. The producer gives the ticket to the host out of band. In Rex, that is a block's data ticket.
3. The host attaches with the ticket and gets a `CALayer`.
4. The host mounts the layer and sends input and size.
5. The host detaches, or the connection drops. The surface keeps running.

#### Tickets

- A ticket works once and expires 60 s after it is made, like a Rex data ticket. The producer prunes expired tickets each time it makes or redeems one.
- Attaching with a ticket replaces the surface's current host. It does **not** invalidate the surface's other unused tickets. Each ticket was handed to a client the producer trusts, and the TTL bounds how stale one can be. Invalidating the others would only make clients that race fail and fetch a new ticket, with no clearer winner.
- Test hook: `BOWSER_TICKET_TTL_MS` in the producer's environment overrides the 60 s. Only the tests use it.

#### Attach handshake

```mermaid
sequenceDiagram
  participant H as New host
  participant P as Producer
  participant O as Old host
  H->>P: HELLO token
  P->>H: WELCOME (or REJECT)
  Note over P: ticket consumed; old host still attached
  H->>P: SUBSCRIBE over Mach (IOSURFACE only)
  H->>P: READY
  Note over P: commit
  P->>O: DETACH REPLACED
  P-->>P: attach_cb(true)
```

- `bowser_host_attach` is synchronous, with one total deadline of 3 s from the call. It returns only after the host is fully set up.
- The producer commits on READY, not on WELCOME. READY is the only signal that the new host's attach succeeded, on both transports. So a host that fails after WELCOME (subscribe fails, deadline passes, the process dies) leaves the current host attached. Its ticket is still used up.
- SUBSCRIBE and READY travel on different channels, so they can arrive in either order. Frames start once both have arrived.

#### Connections

- Send functions never write to the socket or block. They queue the message, and a write source drains the queue on the library's io queue. So a stalled or stopped peer can't hang the embedder's thread, and no lock is held across a call into the other process.
- Latest-wins messages replace an older unsent one of the same kind: resize, mouse move, mouse drag, caret, composition, cursor. The replacement only skips over other latest-wins messages, so the peer sees a subsequence of what was sent, with only superseded states missing. Clicks, keys, text, focus, and scroll always arrive. Scroll deltas add up, so merging them would need phase rules; that waits for a real need.
- A message over 1 MiB is refused at the call with `BOWSER_ERR_INVALID`. The connection stays up.
- If a peer leaves 4 MiB unread, the library drops it: the call returns `BOWSER_ERR_STALLED`, and the host gets `detached_cb(BOWSER_ERR_STALLED)`.
- A producer that doesn't tick stops reading after 4096 queued input events. The back pressure lands in its hosts' send queues, where moves merge, and finally the hosts drop it as stalled.
- `bowser_host_detach` and `bowser_surface_free` still deliver what was queued before them. A peer that doesn't read gets 1 s.

#### Security

- The socket lives in a fresh `mkdtemp` directory (mode 0700), so only the producer's user can reach it, from the moment it exists.
- Both sides check the peer's uid with `getpeereid` and refuse other users. The host checks too, because it sends the producer keystrokes.
- Every socket is close-on-exec. Otherwise a child (a Rex shell, a CEF helper) inherits an authenticated connection, and the other side never sees EOF. macOS has no `SOCK_CLOEXEC` or `accept4`, so this is `fcntl` right after `socket()` and `accept()`. A thread that spawns a child in that gap can still leak the fd; such embedders should spawn with `POSIX_SPAWN_CLOEXEC_DEFAULT`.
- The Mach frame service is public within the bootstrap namespace. It accepts only exactly formed messages and destroys everything else, including reply and voucher rights.

## Transports

The transport is hidden behind the ABI. 0.x ships two, so they can be
compared on the same producer.

| Transport | How frames reach the screen | API | Added latency |
|---|---|---|---|
| `BOWSER_TRANSPORT_CALAYERHOST` | The producer commits its own layer tree to WindowServer. The host shows it by context ID. | Private (`CAContext`, `CALayerHost`) | ~0. Frames keep coming even if the host hangs. |
| `BOWSER_TRANSPORT_IOSURFACE` | The producer sends IOSurfaces once over XPC, then surface IDs and dirty rects per frame. The host sets `layer.contents`. | Public | About 1 frame |

- WebKit and Chromium both use the CALayerHost path internally, so it is the reference for "native".
- IOSurface is the fallback if the private API breaks or the App Store becomes a goal.
- Input, IME, and resize use one XPC connection in both transports.

## ABI

Conventions, the same as libghostty:

- Opaque handles: `bowser_*_t`.
- Config structs passed by pointer, with a `size` field first for forward compatibility. They grow only at the end. The library accepts any size from `BOWSER_*_CONFIG_MIN_SIZE` up and zero-fills missing fields. The minimum ends just before `message_cb`, the first field added after the first release; at 1.0 it freezes at the 1.0 layout.
- Callbacks take a `void *userdata`. Pointers a callback gets are valid only until it returns.
- **Threading:** each producer or host belongs to the embedder's thread. The library never calls host code on an arbitrary thread to do work. It calls `wakeup_cb`, from any thread, and the embedder then calls `*_tick()` on its own thread. `wakeup_cb` must not block or call into the library. Every other callback runs inside `*_tick()`. Only `bowser_abi_version`, `bowser_last_error`, and `bowser_string_free` are safe on any thread.
- Errors: functions return `bowser_result_e`. A failing call sets `bowser_last_error()` for the calling thread; success doesn't clear it.
- **Free order:** free surfaces before their producer. A surface whose producer is gone stays a valid, inert handle until `bowser_surface_free`. `bowser_host_detach` frees the host at once, so a tick the embedder scheduled earlier must check that the host still exists. Detaching or freeing from inside a callback is safe: that object gets no more callbacks.
- **Timestamps:** key, mouse, and scroll input carry `timestamp_ns` in `CLOCK_UPTIME_RAW` nanoseconds, the clock behind `NSEvent.timestamp` and `CACurrentMediaTime()`. Producers get click and scroll velocity, and input-to-photon latency becomes measurable. 0 means the library stamps the event when it is sent.

```c
// bowser.h (draft; include/bowser.h is the source of truth)

#define BOWSER_ABI_VERSION 0

typedef enum {
  BOWSER_OK = 0,
  BOWSER_ERR_INVALID,
  BOWSER_ERR_TICKET,      // expired, used, or unknown ticket
  BOWSER_ERR_TRANSPORT,   // transport not supported here
  BOWSER_ERR_DISCONNECTED,
  BOWSER_ERR_REPLACED,    // another host attached to the surface
  BOWSER_ERR_STALLED,     // the other side stopped reading, so it was dropped
} bowser_result_e;

typedef enum {
  BOWSER_TRANSPORT_CALAYERHOST,
  BOWSER_TRANSPORT_IOSURFACE,
} bowser_transport_e;

typedef struct { double width, height, scale; } bowser_size_s;  // points + backing scale
typedef struct { double x, y, width, height; } bowser_rect_s;

uint32_t    bowser_abi_version(void);
const char *bowser_last_error(void);

// ---- Producer side --------------------------------------------------

typedef struct bowser_producer bowser_producer_t;
typedef struct bowser_surface  bowser_surface_t;

typedef struct {
  size_t size;
  bowser_transport_e transport;
  void *userdata;
  void (*wakeup_cb)(void *userdata);
  // Input from the host, delivered inside bowser_producer_tick().
  void (*key_cb)(void *ud, bowser_surface_t *, const struct bowser_key_s *);
  void (*mouse_cb)(void *ud, bowser_surface_t *, const struct bowser_mouse_s *);
  void (*scroll_cb)(void *ud, bowser_surface_t *, const struct bowser_scroll_s *);
  void (*text_cb)(void *ud, bowser_surface_t *, const struct bowser_text_s *);
  void (*resize_cb)(void *ud, bowser_surface_t *, bowser_size_s);
  void (*focus_cb)(void *ud, bowser_surface_t *, bool focused);
  void (*attach_cb)(void *ud, bowser_surface_t *, bool attached);
  void (*message_cb)(void *ud, bowser_surface_t *, const char *name, const char *body);
} bowser_producer_config_s;

bowser_result_e bowser_producer_new(const bowser_producer_config_s *, bowser_producer_t **out);
void            bowser_producer_free(bowser_producer_t *);
void            bowser_producer_tick(bowser_producer_t *);

bowser_result_e bowser_surface_new(bowser_producer_t *, bowser_size_s, bowser_surface_t **out);
void            bowser_surface_free(bowser_surface_t *);
// A fresh ticket: single use, valid for 60 s. Caller frees with bowser_string_free.
char           *bowser_surface_ticket(bowser_surface_t *);

// Frame output. Use the one that matches the transport.
CALayer        *bowser_surface_root_layer(bowser_surface_t *);   // CALAYERHOST: draw into this tree
bowser_result_e bowser_surface_present(bowser_surface_t *,       // IOSURFACE: hand over a frame
                                       IOSurfaceRef, bowser_rect_s dirty);

// Text input state the host needs to place the IME window. Senders never block.
bowser_result_e bowser_surface_set_caret(bowser_surface_t *, bowser_rect_s caret);
bowser_result_e bowser_surface_set_composition(bowser_surface_t *, bool active,
                                               const bowser_rect_s *char_rects, size_t count);
bowser_result_e bowser_surface_set_cursor(bowser_surface_t *, int bowser_cursor_shape);
bowser_result_e bowser_surface_send(bowser_surface_t *, const char *name, const char *body);

// ---- Host side ------------------------------------------------------

typedef struct bowser_host bowser_host_t;

typedef struct {
  size_t size;
  void *userdata;
  void (*wakeup_cb)(void *userdata);
  // Delivered inside bowser_host_tick().
  void (*caret_cb)(void *ud, bowser_host_t *, bowser_rect_s caret);
  void (*composition_cb)(void *ud, bowser_host_t *, bool active,
                         const bowser_rect_s *char_rects, size_t count);
  void (*cursor_cb)(void *ud, bowser_host_t *, int bowser_cursor_shape);
  void (*detached_cb)(void *ud, bowser_host_t *, bowser_result_e why);
  void (*message_cb)(void *ud, bowser_host_t *, const char *name, const char *body);
} bowser_host_config_s;

bowser_result_e bowser_host_attach(const char *ticket, const bowser_host_config_s *,
                                   bowser_host_t **out);
void            bowser_host_detach(bowser_host_t *);
void            bowser_host_tick(bowser_host_t *);

CALayer *bowser_host_layer(bowser_host_t *);   // mount in any NSView; same for both transports

// Senders never block. See "Connections".
bowser_result_e bowser_host_resize(bowser_host_t *, bowser_size_s);
bowser_result_e bowser_host_focus(bowser_host_t *, bool focused);
bowser_result_e bowser_host_key(bowser_host_t *, const struct bowser_key_s *);
bowser_result_e bowser_host_mouse(bowser_host_t *, const struct bowser_mouse_s *);
bowser_result_e bowser_host_scroll(bowser_host_t *, const struct bowser_scroll_s *);
bowser_result_e bowser_host_text(bowser_host_t *, const struct bowser_text_s *);
bowser_result_e bowser_host_send(bowser_host_t *, const char *name, const char *body);

void bowser_string_free(char *);
```

### Messages

Everything that isn't pixels or input travels as a small named message:
navigation, titles, edit commands. The library defines the channel; each
engine adapter defines its vocabulary (bowser-cef's is in
`adapters/cef/README.md`).

- `name` is 1-64 of `[A-Za-z0-9_.-]`. `body` is UTF-8 (JSON by convention) or NULL, at most `BOWSER_MESSAGE_MAX` (64 KiB). Anything else is refused with `BOWSER_ERR_INVALID` at the call; the connection stays up.
- Each direction is in order. Host messages share the input queue: never merged, never reordered against keys or text, and they hold their place when latest-wins input around them merges.
- Nothing is kept for a host that isn't attached: `bowser_surface_send` returns `BOWSER_ERR_DISCONNECTED`. A producer sends its current state from `attach_cb`.
- `message_cb` is the last field of both config structs. The `*_MIN_SIZE` constants still end at the field before it, so callers built before messages keep working and never have `message_cb` read past their struct.
- A host that doesn't tick stops reading after 4096 unread messages, as a producer does with input.

### Input structs

Input keeps `NSEvent`-level detail, so the producer can rebuild native
events for the engine.

| Struct | Fields |
|---|---|
| `bowser_key_s` | action (press, release, repeat), macOS key code, modifiers, characters, characters without modifiers, timestamp |
| `bowser_mouse_s` | action (down, up, move, drag, exit), button, position in points, click count, modifiers, timestamp |
| `bowser_scroll_s` | delta x and y, precise (trackpad) or line, momentum and gesture phase, position, modifiers, timestamp |
| `bowser_text_s` | kind (insert, set marked, unmark), UTF-8 text, selected range, replacement range |

### Text input

The host's view implements `NSTextInputClient` and maps it like this:

| `NSTextInputClient` call | libbowser |
|---|---|
| `setMarkedText:selectedRange:replacementRange:` | `bowser_host_text` with kind set marked |
| `insertText:replacementRange:` | `bowser_host_text` with kind insert |
| `unmarkText` | `bowser_host_text` with kind unmark |
| `firstRectForCharacterRange:` | The latest rects from `composition_cb`, or `caret_cb` |

The candidate window must sit next to the caret on the first keystroke.
So the producer sends caret and composition rects as soon as they change.
The host doesn't ask for them.

## Engine adapters

Adapters live outside the core library. Each is a producer built on the ABI.

| Adapter | Engine | Phase |
|---|---|---|
| `bowser-test` | Metal clear color, animated, with a text field drawn in Core Text | POC step 1 |
| `bowser-cef` | CEF off-screen rendering with shared textures (`on_accelerated_paint` gives an IOSurface) | POC step 2 |
| `bowser-helium` | Helium plus a patch set with a `//content` embedder target | After the POC |

The CEF adapter maps input to CEF's C API: `send_key_event`,
`send_mouse_click_event`, `send_mouse_move_event`, `send_mouse_wheel_event`,
`ime_set_composition`, `ime_commit_text`. The caret and composition rects
come from `on_ime_composition_range_changed`.

## POC plan

Each step has a stop condition. If a step fails, don't start the next one.

| Step | Build | Pass when |
|---|---|---|
| 1. Pipe | Core library, both transports, `bowser-test`, a test host app | 120 fps on ProMotion with no dropped frames, on both transports |
| 2. Engine | `bowser-cef` | A heavy page scrolls at 120 fps. Resize shows no stretched or blank frames. Retina scale changes are clean. |
| 3. Text | IME path end to end | The Japanese IME, press-and-hold accents, and emoji entry behave as in Safari |

### What to measure

| Metric | How | Target |
|---|---|---|
| Added latency | Input to photon, compared with the same engine in process | Less than 1 frame on CALAYERHOST |
| Frame pacing | Present times compared with display link times | No dropped frames at 120 Hz |
| CPU | Producer and host, while scrolling | Host near idle on CALAYERHOST |
| Host hang | Block the host's main thread for 1 s | CALAYERHOST keeps updating |

## Repository layout

```
libbowser/
  include/bowser.h
  src/              core: tickets, XPC, both transports
  adapters/
    test/
    cef/
  examples/
    host-swift/     minimal AppKit host
```

## Open questions

- **Ticket exchange.** Decided in step 1: a Unix socket in a 0700 directory carries control, the ticket is `bowser2:<socket path>#<token>`, and IOSURFACE frames use a bootstrap Mach service named in WELCOME.
- **Rex integration.** Rex lists only first-party creators today. A browser block needs a creator API or first-party support.
- **Who renders the cursor.** The producer sends a cursor shape and the host sets `NSCursor`. Custom image cursors need a bitmap path.
- **Popups and `<select>` menus.** Decided: the producer composites them. CALAYERHOST adds a sublayer; IOSURFACE draws the popup into each frame. The host sees one surface.
- **Accessibility.** Mirror the tree over XPC, or use `NSAccessibilityRemoteUIElement` (private)?
- **Remote hosts.** An HEVC transport with VideoToolbox, behind the same `bowser_host_layer()`.
