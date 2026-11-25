# dev.libbowser Rex block plugin

Every `dev.libbowser.browser` block is one surface of a shared bowser-cef
engine (`adapters/cef`). The engine starts with the plugin, before any block
needs it, starts again after it dies, and outlives the last block: a cold
engine takes most of a second, and a block on a running one opens in
milliseconds. See `PROTOCOL.md` for the Rex wire protocol.

With `BOWSER_TICKET_SOCKET` set, the plugin also answers tickets on that Unix
socket (`tickets.go`): a pane's session block ID in, `{"ticket"}` out, from a
ticket minted ahead. The Rex client uses it in place of the `ticket` method,
which it can reach only by starting the `rex` CLI.

## Open a browser pane

[`browser.lua`](browser.lua) adds a Rex action, `browser`. Load it from your
`init.lua` with `dofile`; `rex-client/run.sh` does this for the dev server.

| Where | How |
|---|---|
| Any pane | ⇧⌘B, then type an address or a search in Rex's prompt |
| Rex's command list | **New Browser Pane** |
| A shell | `rex do browser url=news.ycombinator.com` |

The pane opens to the right of the focused pane, and takes focus.

```sh
rex-client/run.sh server            # isolated dev server with this plugin; builds it and bowser-cef
R=rex-client/dev/rexdev             # the rex CLI, pointed at the dev server
$R api call session.create '{"initial_windows":[{"layout":{"block":{"flavor":"dev.libbowser.browser","options":{"url":"example.com"}}}}]}'
BOWSER_SPACE=3 build/bowser-host "$($R block call -b <block> ticket | jq -r .ticket)"
$R block call -b <block> navigate '{"url":"en.wikipedia.org"}'
$R events -s <session> --json       # state, error, host_attached, host_detached
cd rex/plugin && go test ./...      # end to end, with the real engine (make cef first)
```

Plugin log: `rex-client/dev/logs/plugin.log`. The engine's stderr goes there too.

## Block API

| Method | Args | Result |
|---|---|---|
| `ticket` | none | `{"ticket"}`: fresh from the engine, single use, valid 60 s |
| `state` | none | The newest `state` (see `adapters/cef/README.md`), plus `transport`, `mode` (`windowed`, the zero-copy default on `calayerhost`, or `osr`), and `engine_pid` (0 while the block has no surface) |
| `navigate` | `{"url"}` | Loads what was typed: a URL, a host, or a search |
| `back`, `forward`, `reload`, `stop` | none | |
| `snapshot` | `{"interactive"}` | `{"snapshot"}`: the page's accessibility tree, one element per line. Elements an agent can act on get a ref (`[ref=e3]`). Refs belong to the block and last until its next snapshot. |
| `click` | `{"target"}` | Scrolls the element into view and clicks its middle with real mouse events. `target`: a ref, or a CSS selector. |
| `fill` | `{"target","text"}` | Selects the field's text and types `text` over it |
| `type`, `press` | `{"text"}`, `{"key"}` | Key events into what has the keyboard. `key`: a character, or `Enter`, `Tab`, `Escape`, `Backspace`, `ArrowDown`, …, with `Shift+`, `Control+`, `Alt+`, `Meta+` |
| `scroll` | `{"dx","dy"}` | The mouse wheel, from the page's middle |
| `eval` | `{"js"}` | `{"value"}`: the expression's value as JSON; a promise is awaited |
| `screenshot` | `{"path"}` | Writes a PNG of the page to the absolute `path` |
| `wait` | `{"target"}`, `{"text"}`, or none; `"timeout_ms"` | Until the selector or text shows, or, with neither, the page has loaded. At most 8 s. |
| `cdp` | `{"method","params"}` | `{"result"}`: any DevTools protocol method |

| Event | Payload |
|---|---|
| `state` | The engine's `state` message, at most once per frame |
| `error` | `{"message"}`: the engine exited, or the page closed itself. The block's next method call opens the page again, at its last URL, in a new engine. |
| `host_attached`, `host_detached` | `{}` |

The plugin sets the block's label to the page title (up to 40 characters),
once per title change, through the server's `session.set_block_label`.

It also uses Rex the way a person would:

| When | The plugin |
|---|---|
| A click opens a new window, or the menu's Open Link in New Pane | Opens a browser pane beside this one (`session.new_split`). If Rex can't, the link loads in this pane. |
| The menu's Send to Agent | Pastes the page's title and URL, the selection, and the clicked element (a selector and its HTML) into the terminal pane running an agent (`claude`, `codex`, …; this window first), and focuses it. It never pastes into a shell. |

## Drive it from a shell: `bowser`

`rex/bowser` is a CLI over the block API, for agents and scripts in Rex
panes. `run.sh server` builds it and puts it on the dev server's PATH.

```sh
bowser open localhost:3000 --split right --size 0.4   # a pane beside this one; waits for the page
bowser snapshot -i                                    # - textbox "Email" [ref=e2] …
bowser fill e2 ribbet@example.com && bowser click e3
bowser wait --text Welcome && bowser screenshot
bowser eval 'document.title'
```

It acts on the session's only browser pane, or the only one in your window;
`-b PANE` picks one from `bowser ls`. `bowser --help` lists every command.
It refuses to run when `rex` reaches a server that doesn't have its pane, as
a dev server's shell without `REX_SERVER` would reach your own server, and it
never starts a server.

Agents learn it from the `bowser` skill, `rex/bowser/skill/SKILL.md`;
link that folder into `~/.claude/skills/bowser` (Claude Code) or
`~/.agents/skills/bowser` (Codex, OpenCode, Pi).

`rex-client/check-bowser.sh` runs it in a terminal pane of a throwaway Rex
server, against real browser panes, and removes the server after.

| Variable | Default |
|---|---|
| `BOWSER_ENGINE` | `~/Development/libbowser/build/bowser-cef.app/Contents/MacOS/bowser-cef` (`run.sh` sets the workspace's) |
| `BOWSER_PROFILE` | The engine's default, under `$HOME`, which `run.sh` points at `rex-client/dev/home` |
| `REXPLUGIN_LOG` | None: Rex points the plugin's stdout and stderr at `/dev/null` |
