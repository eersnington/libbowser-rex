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

## Step 2: engine (next)

- [ ] `adapters/cef`: CEF off-screen rendering with shared textures, behind the IOSURFACE transport
- [ ] CALAYERHOST for CEF: CEF hands out an IOSurface, so it needs a layer with IOSurface contents committed in the producer's `CAContext`
- [ ] Load a real page; forward mouse, scroll, and keys
- [ ] Resize without stretched or blank frames

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
