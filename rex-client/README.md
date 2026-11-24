# Rex client integration (dev harness)

Shows libbowser surfaces inside real Rex panes. It runs a **dev copy** of the
Rex client against an **isolated dev server**, so the user's own Rex is never
touched.

```sh
rex-client/run.sh server            # sandboxed dev server (fake HOME, own state)
rex-client/run.sh client            # injected dev client; windows go to Space 3
kill -USR2 "$(cat rex-client/dev/client.pid)"   # open its window, without activating
rex-client/dev/rexdev ...           # the rex CLI, pointed at the dev server
rex-client/run.sh stop
rex-client/check-typing.sh          # types into pages like a person, checks what they got
BOWSER_LOG=1 rex-client/run.sh server; rex-client/bench-startup.sh   # docs/perf.md
```

## Find a stutter

Three tools, one capture format. Every capture is `dev/perf/<time>/` with a
`trace.json.gz` (open it in [Perfetto](https://ui.perfetto.dev)) and a report.
All captures together stay under 200 MB (`PERF_KEEP_MB`); the oldest go first.

| Tool | Use it when |
|---|---|
| `perf-watch.py` | You use the browser and want each stutter caught. Leave it running. It saves the 6 s before a pane that was animating steadily on screen shows a frame 50 ms late or more (`--gap`) and then animates on, or before you press **⌃⌥⌘J** in the dev Rex. |
| `perf-trace.sh SECS` | You can make it stutter on purpose: record now, for SECS. |
| `perf-load.py` | Load tests: scripted scenarios in the `loadtest` session (`dev/restore.sh` makes it, in its own window), one row each. Four `check:` scenarios plant a known cause, or a known bug, and fail if the report misses it. Run it with Space 3 on screen to get the pane lanes. |

The report shows each lane as a strip, so a stutter lines up across them,
and each spike with a verdict:

```
  index.html             │▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▃▁▁▁▁▁▁▁▁▁▁▁▁▃▁▁▁▁▁▃▁▁▁▁│
  Rex main thread busy   │                                  ▁     │
  GPU busy (all)         │▄▃▃▅▆▄▄▅▄▄▄▄▅▄▄▄▃▄▃▄▅▄▃▃▄▃▄▆▅▄▄▄▅▅▄▆▄▅▄▄│  0–100%

  #1 at   1.74s, 33 ms: 1 late in index.html
     ⇒ waiting for WindowServer to put the frame on screen: 33 ms, usually 20
     stage SwapEndToPresentationCompositorFrame: 33.0 ms, usually 20.4: …
     GPU busy %: Chromium GPU process 16, other apps 5, WindowServer 2
```

| Lane | Source | Shows |
|---|---|---|
| Chromium | engine `trace_start`/`trace_stop` | Each frame of each tab through its stages, from the page's main thread to WindowServer; dropped frames; the script, layout or raster that ran |
| Rex client | `BOWSER_REX_PERF` (`run.sh` sets it) | Main-thread turns of 4 ms or more, pane layouts, mounts, attaches, ⌃⌥⌘J |
| Rex windows | `framegaps.swift` (ScreenCaptureKit) | Each frame WindowServer composited for each Rex window, while it is on the current Space |
| Panes on screen | `framegaps.swift` and `BOWSER_REX_PANES` (`run.sh` sets it) | When each browser pane's own pixels changed. The window can't tell: with two panes, one keeps it changing while the other stutters. Pixels are compared in memory at half size and never kept. |
| Load | `sysmon.swift` | GPU busy per process (IOKit) and CPU, every 50 ms. Other apps only as one total |

How to read a verdict:

| Verdict starts with | Where the time went |
|---|---|
| the page's main thread | The page's own script, style, layout or paint. Any browser pays it. |
| Chromium's GPU process was busy | Raster or drawing in the engine |
| a stage name (rasterizing, drawing, …) | The stage that grew most against the tab's usual frame |
| … went silent | That process was stopped, starved of CPU, or blocked in the kernel |
| GPU saturated | Everything on the Mac wanted the GPU |
| after Chromium | The page presented on time but its pane on screen didn't change: Rex or WindowServer |

Two rules keep pauses from looking like stutter. On screen, a long frame
counts only between steady frames, with frames resuming after it, and not
while the page's tab said it had nothing to draw. And a tab's frames are
timed when the GPU process hands them to Core Animation: Chromium's own
"presented" time comes from the tab's hidden window, which runs late while
the Rex window shows the frame on time.

**⚠ blank or frozen pane** means a tab drew animating frames but no pane on
screen changed with them. Each pane is matched to the tab whose frames its
pixels follow.

Chromium's trace buffer stops recording when full (about 640 MB, 2 minutes
of one busy tab), so `perf-watch.py` throws it away and restarts it every
20 s. Tracing costs the engine about 8 % of one core while it runs.

## How it works

| Piece | What it does |
|---|---|
| `launch.c` | Applies `sandbox.sb`, then `exec`s. (`sandbox-exec` and `nohup` are platform binaries, and dyld strips `DYLD_*` from them.) |
| `sandbox.sb` | Kernel guard: denies writes to the real `~/Library/Application Support/rex`, `…/com.superlogical.rex`, and `~/.config/rex`; denies connecting to the real server socket; denies the keychain. |
| Dev client | A re-signed copy of `Rex Beta.app` with bundle ID `com.superlogical.rex.bowserdev` and `REX_SERVER` set to the dev socket. The client finds its server through the `rex` CLI it spawns, and the CLI honors `REX_SERVER`. |
| `rexinject.m` | Injected library: puts every window on Space `BOWSER_SPACE` before ordering it in, makes app activation a no-op, opens a window on `SIGUSR2` (a reopen Apple Event to itself), and dumps the view tree on `SIGUSR1`. |
| `RexBowser.swift` | Hooks `NativePaneView.layout`. It reads the pane's block from `cell.context.pane.block` with `Mirror`. For `dev.libbowser` blocks it puts a `BowserPaneView` over the unsupported-block placeholder, asks the block for a ticket (`rex block call <block> dev.libbowser.ticket`), and attaches. |

| `BrowserChrome.swift` | The pane's native chrome: a toolbar above the page (back and forward once there is history, reload or stop, the address as host and path, a loading line), and a find bar (⌘F) that floats over the page. |

## Keys in a browser pane

⇧⌘B in any pane opens a new browser pane beside it (see `rex/README.md`).

Rex consumes its menu shortcuts before views see them, so the injected
library checks keys in `NSApplication.sendEvent` first, and only while the
keyboard is in a browser pane:

| Keys | Go to |
|---|---|
| ⌘A ⌘C ⌘V ⌘X ⌘Z ⇧⌘Z | The responder chain: the page, or the address/find field being typed in |
| ⌘L, ⌘R, ⌘F, ⌘G, ⇧⌘G, ⌘+ ⌘- ⌘0 | The page: edit the address, reload, find, zoom |
| ⌘[ ⌘] | Back and forward. Rex binds them to pane focus; ⌥⌘ + arrows still move between panes. |
| Everything else | Rex, unchanged |

Mouse buttons 4 and 5 go back and forward too. A click on the address, or
⌘L, shows the full URL selected; Return loads what you typed (a URL, a host, a
file path, or a search), and Escape returns the keyboard to the page. A click in the page focuses the pane
with Rex's own `onFocus` action, and Rex focusing the pane gives the page the
keyboard.

Dev hooks: `BOWSER_REX_KEYS` + `kill -INFO` replays key lines into the browser
pane that last took the keyboard, and drops them when it no longer has it, so
they never type into a terminal (`cmd+l`,
`type:text`, `enter`, `esc`) through `NSApp.sendEvent`, for testing without
clicking. `BOWSER_REX_CREATOR` treats another creator's blocks as ours, and
`BOWSER_REX_TICKET` uses a fixed ticket instead of asking the block.

## What first-party Rex support would need

The hooks above stand in for about four things in the Rex client:

1. A renderer for the flavor, in place of the unsupported-block view: a view
   that implements `NSTextInputClient` and mounts `bowser_host_layer()`.
2. On attach, call the block's `ticket` method (the server plugin issues
   single-use tickets), then `bowser_host_attach`.
3. Forward pane focus to `bowser_host_focus`, and keep ⌘ shortcuts for Rex.
4. Detach when the pane leaves its window, and reattach with a fresh ticket.

CALAYERHOST works only when the client and the producer share a Mac. A remote
host needs the video transport in SPEC.md's open questions.

## Findings about Rex (client 0.1.0 build 2061, macOS 27.2)

- The client draws only terminal and onboarding blocks. Others get an
  "Unsupported block" view: a SwiftUI `NSHostingView` inside
  `NativePaneFlippedView`, under a 36 pt header.
- Pane view tree: `NativePaneView` › `NativePaneFlippedView` › content view
  (`NativeTerminalView` › `GhosttyTerminal.SurfaceView` ›
  `GhosttyRender.PlatformRenderView` for terminals).
- Remote actions (`rex -C CLIENT do …`) need `rex.client.remoteControl` in the
  client's defaults.
- The Go server reads `$HOME` (so a fake HOME isolates it); the Swift client
  does not.
