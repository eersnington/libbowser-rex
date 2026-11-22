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

Dev hooks: `BOWSER_REX_CREATOR` treats another creator's blocks as ours, and
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
