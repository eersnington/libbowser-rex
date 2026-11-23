# libbowser

A real Chromium browser as a native pane in Rex.

The engine runs in its own process. Rex mounts its output as a `CALayer` and
sends input back. No frame copies, no video stream.

```
Rex server ── block plugin (Go) ── bowser-cef (Chromium)
                                        │ ticket
Rex client ── browser pane ─────────────┘ CALayerHost, keys, IME
```

Status: experiment, macOS only. The Rex side is a dev harness: Rex has no
API for third-party panes yet, so it runs an injected copy of the Rex client.

## Build

```sh
scripts/fetch-cef.sh   # pinned CEF build
make && make cef
make test              # core, real processes
make test-cef          # the engine
make test-rex          # the Rex plugin with the real engine
```

## Use in Rex

```sh
rex-client/run.sh server
rex-client/run.sh client
rex-client/dev/rexdev do browser url=news.ycombinator.com
```

⇧⌘B in a pane asks for an address. ⌘L, ⌘F, ⌘R, and zoom work in the page.

## Numbers

M4 MacBook Air, 60 Hz. Details in [docs/perf.md](docs/perf.md).

| | |
|---|---|
| Frame time p99, animating | 16.7 ms |
| Browser process CPU, animating | 0.4–3 % |
| Rex mounts the pane → page attached | 1.7 ms p50, 2.8 ms p90 |

## Layout

| Path | What |
|---|---|
| `include/bowser.h` | The C ABI: producers, surfaces, hosts |
| `src/` | Control socket, IOSurface frames over Mach, producer and host |
| `adapters/cef/` | `bowser-cef`: one Chromium engine for many panes |
| `adapters/test/` | A test producer |
| `rex/` | The Rex block plugin, the `browser` action, the observed plugin protocol |
| `rex-client/` | The pane view and the dev Rex client harness |
| `examples/host-swift/` | A minimal AppKit host |
| `tests/` | End-to-end tests |

Design: [SPEC.md](SPEC.md). Status and known gaps: [TODO.md](TODO.md).
