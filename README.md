# libbowser

A C ABI that lets one process show another process's live, native UI as a
`CALayer`. See [SPEC.md](SPEC.md) for the design and [TODO.md](TODO.md) for status.

## Build and run

```sh
make                          # library, test producer, Swift host
make test                     # end-to-end tests (real processes)
scripts/demo.sh calayerhost   # or: iosurface
```

Set `BOWSER_SPACE=3` to open the host window on Mission Control Space 3
without switching to it.

## Layout

| Path | What |
|---|---|
| `include/bowser.h` | The public C ABI |
| `src/` | Control socket (`wire.c`), IOSurface frames over Mach (`frames.c`), producer and host |
| `adapters/test/` | `bowser-test`: a producer with a scene for checking pacing, input, and IME |
| `examples/host-swift/` | `bowser-host`: a minimal AppKit host with `NSTextInputClient` |
| `tests/e2e.m` | End-to-end tests against a real producer process |
