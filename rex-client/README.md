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
```

## How it works

| Piece | What it does |
|---|---|
| `launch.c` | Applies `sandbox.sb`, then `exec`s. (`sandbox-exec` and `nohup` are platform binaries, and dyld strips `DYLD_*` from them.) |
| `sandbox.sb` | Kernel guard: denies writes to the real `~/Library/Application Support/rex`, `…/com.superlogical.rex`, and `~/.config/rex`; denies connecting to the real server socket; denies the keychain. |
| Dev client | A re-signed copy of `Rex Beta.app` with bundle ID `com.superlogical.rex.bowserdev` and `REX_SERVER` set to the dev socket. The client finds its server through the `rex` CLI it spawns, and the CLI honors `REX_SERVER`. |
| `rexinject.m` | Injected library: puts every window on Space `BOWSER_SPACE` before ordering it in, makes app activation a no-op, opens a window on `SIGUSR2` (a reopen Apple Event to itself), and dumps the view tree on `SIGUSR1`. |
| `RexBowser.swift` | Hooks `NativePaneView.layout`. It reads the pane's block from `cell.context.pane.block` with `Mirror`. For `dev.libbowser` blocks it puts a `BowserPaneView` over the unsupported-block placeholder, asks the block for a ticket (`rex block call <block> dev.libbowser.ticket`), and attaches. |

| `BrowserChrome.swift` | The pane's native chrome: an address bar (⌘L), a find bar (⌘F), and a loading line. They float over the page, so showing them never resizes it. |

## Keys in a browser pane

Rex consumes its menu shortcuts before views see them, so the injected
library checks keys in `NSApplication.sendEvent` first, and only while the
keyboard is in a browser pane:

| Keys | Go to |
|---|---|
| ⌘A ⌘C ⌘V ⌘X ⌘Z ⇧⌘Z | The responder chain: the page, or the address/find field being typed in |
| ⌘L, ⌘R, ⌘F, ⌘G, ⇧⌘G, ⌘+ ⌘- ⌘0 | The page: address bar, reload, find, zoom |
| Everything else, including ⌘[ ⌘] | Rex, unchanged |

Mouse buttons 4 and 5 go back and forward. A click in the page focuses the pane
with Rex's own `onFocus` action, and Rex focusing the pane gives the page the
keyboard.

Dev hooks: `BOWSER_REX_KEYS` + `kill -INFO` replays key lines (`cmd+l`,
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
