# Status

## Step 1: pipe ✅

- [x] C ABI (`include/bowser.h`), ABI version 0
- [x] CALAYERHOST transport (private `CAContext` / `CALayerHost`)
- [x] IOSURFACE transport (IOSurface mach ports over a bootstrap service)
- [x] Single-use tickets, host takeover, reattach, producer-death detection
- [x] Test producer and Swift host, with input, IME text, caret, and cursor
- [x] End-to-end tests: 8 cases, real processes

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

## Known gaps

- The test scene's `CATextLayer`s don't draw under `CARenderer` (IOSURFACE only). A real engine draws its own text.
- `bowser_surface_present` ignores the dirty rect and sends the whole surface.
- Input-to-photon latency is not measured yet.
- Moving test windows to a Space uses private CGS calls (`BOWSER_SPACE`).
