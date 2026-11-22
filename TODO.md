# Status

## Step 1: pipe ✅

- [x] C ABI (`include/bowser.h`), ABI version 0
- [x] CALAYERHOST transport (private `CAContext` / `CALayerHost`)
- [x] IOSURFACE transport (IOSurface mach ports over a bootstrap service)
- [x] Single-use tickets, host takeover, reattach, producer-death detection
- [x] Test producer and Swift host, with input, IME text, caret, and cursor
- [x] End-to-end tests: 18 cases, real processes

## Step 1b: hardening ✅

- [x] Sends never block: a bounded queue per connection, drained by a write source; latest-wins input merges; a peer that leaves 4 MiB unread is dropped as `BOWSER_ERR_STALLED`
- [x] Close-on-exec on every socket; peer uid check on both sides; socket in a 0700 `mkdtemp` directory
- [x] Attach commits on READY, with one 3 s deadline; 60 s ticket TTL
- [x] Strict Mach receive validation; header rights released; quit by message, not by port name
- [x] Host holds an IOSurface use count from receipt until the frame is replaced
- [x] Surface handles outlive their producer as inert handles
- [x] `timestamp_ns` on key, mouse, and scroll input; documented threading, lifetimes, and errors

Measured on an M4 MacBook Air (60 Hz), macOS 27.2, about 19,200 frames each:

| | CALAYERHOST | IOSURFACE |
|---|---|---|
| Average | 60.0 fps | 60.0 fps |
| Dropped frames | 0.08% | 0.08% |
| Host CPU | 0.0% | 2.5% |
| Producer CPU | 1.1% | 2.5% |

Pacing is measured at the producer's display link, not on screen.

## Step 2: engine

CEF 158.0.3 (Chromium 158.0.8127.18), C API, sandboxed helpers.
`scripts/fetch-cef.sh` pins and verifies it; `make cef`, `make test-cef`,
`scripts/demo-cef.sh`, `scripts/bench-cef.sh`.

- [x] `adapters/cef`: CEF off-screen rendering with shared textures, behind the IOSURFACE transport
- [x] CALAYERHOST for CEF: each frame is a layer's IOSurface contents in the producer's `CAContext`
- [x] Load a real page; forward mouse, scroll (with trackpad phases), and keys
- [x] Resize without stretched frames (a frame always shows at its own size)
- [ ] Resize without blank frames: while the host grows, a strip of host background shows until the new-size frame arrives (12-18 ms). Needs a resize fence between host and producer.
- [ ] 120 fps: not measurable on this 60 Hz machine

CEF lends its IOSurface only for the length of `on_accelerated_paint` and
reuses it from a pool of 2-3. The adapter copies each frame (Metal blit) into
a pool of its own, reused least-recently-shown first and only when
`IOSurfaceIsInUse()` is false, and waits for the copy before returning.

Measured with `scripts/bench-cef.sh` on Wikipedia's "Chromium (web browser)",
800x600 pt at 2x, 10 s of synthesized trackpad scrolling, on an M4 MacBook Air
(60 Hz) with other apps running. Frame stats are 2 s windows at the producer's
paint callback; CPU is `ps` CPU time over the scroll, as % of one core.

| | CALAYERHOST | IOSURFACE |
|---|---|---|
| Frame rate while scrolling | 59.7-60.3 fps | 59.4-60.1 fps |
| Late frames (> 25 ms gap) | 0-4 per 120 | 0-5 per 120 |
| Frame-interval jitter (RMS) | 1.7-4.3 ms | 3.7-4.3 ms |
| Copy, wall (GPU) | 1.0-2.2 ms (0.4-1.5 ms) | 1.0-3.6 ms (0.3-2.6 ms) |
| Browser / GPU / renderer CPU | 6% / 7% / 6% | 5% / 6-7% / 5-6% |
| Host CPU | 0.3-0.6% | 1.3-1.5% |
| Resize to new-size frame | 13-18 ms | 12-15 ms |

- Live resize of this page runs at 21-40 fps: Chromium relayout, not the pipe.
- `external_begin_frame_enabled` (frames driven by the display link) measured
  worse jitter (2-4 ms against 2 ms), so CEF keeps its own timer.

## Step 3: text input

- [ ] Japanese IME in the Swift host against CEF
- [ ] Press-and-hold accents, emoji picker

## Rex

- [ ] Find how a Rex block could mount `bowser_host_layer()` (creator API, client internals)

## Proposals

- **Generic message channel.** Engines need more than input and IME state: navigation, title, URL, load progress, find-in-page. A `bowser_surface_send(type, bytes, len)` / `message_cb` pair with app-defined types would carry them without growing the ABI per feature. Open: whether messages are latest-wins by type, and how big they may be (the 1 MiB frame limit applies).

## Known gaps

- The test scene's `CATextLayer`s don't draw under `CARenderer` (IOSURFACE only). A real engine draws its own text.
- `bowser_surface_present` ignores the dirty rect and sends the whole surface.
- Input-to-photon latency is not measured yet. `timestamp_ns` makes it possible.
- Unverified: whether the render server holds an IOSurface use count while a surface is layer contents. The host gives back its count right after it commits the newer frame. If the render server doesn't hold one, the producer could reuse the old surface one composite early.
- Scroll events never merge, so a long stall during a trackpad scroll ends as `BOWSER_ERR_STALLED` sooner than a mouse-move flood does.
- Close-on-exec has a gap: there is no `SOCK_CLOEXEC` or `accept4` on macOS. A thread that spawns between `socket()`/`accept()` and `fcntl` leaks the fd. Embedders that spawn from other threads should use `POSIX_SPAWN_CLOEXEC_DEFAULT`.
- A connection that sends HELLO but never READY holds a socket until it closes. The uid check limits this to the producer's own user.
- `bowser_host_attach` blocks the calling thread for up to 3 s when the producer is stopped or busy.
- Moving test windows to a Space uses private CGS calls (`BOWSER_SPACE`).
- CEF: `<select>` popups (`PET_POPUP`) aren't composited.
- CEF: menus, JS dialogs, file pickers, and new windows are suppressed (links open in place). The ABI has no way to hand them to the host.
- CEF: the host's screen position isn't in the ABI, so CEF gets view coordinates as screen coordinates.
- CEF: caret rects arrive only during an IME composition (`on_ime_composition_range_changed`), not for a plain caret.
- CEF: AppKit commands (`doCommandBySelector:`, such as emacs bindings) don't reach the producer. Return, Tab, Escape, and Control/Command chords are sent as CHAR events instead.
- CEF: one profile per process in `$TMPDIR`, removed on a clean exit. Nothing persists.
