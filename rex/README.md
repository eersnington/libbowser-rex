# dev.libbowser Rex block plugin

Every `dev.libbowser.browser` block is one surface of a shared bowser-cef
engine (`adapters/cef`). The plugin starts the engine with the first block,
restarts it on the next call after it dies, and stops it when the last block
closes. See `PROTOCOL.md` for the Rex wire protocol.

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

| Event | Payload |
|---|---|
| `state` | The engine's `state` message, at most once per frame |
| `error` | `{"message"}`: the engine exited, or the page closed itself. The block's next method call opens the page again, at its last URL, in a new engine. |
| `host_attached`, `host_detached` | `{}` |

The plugin sets the block's label to the page title (up to 40 characters),
once per title change, through the server's `session.set_block_label`.

| Variable | Default |
|---|---|
| `BOWSER_ENGINE` | `~/Development/libbowser/build/bowser-cef.app/Contents/MacOS/bowser-cef` (`run.sh` sets the workspace's) |
| `BOWSER_PROFILE` | The engine's default, under `$HOME`, which `run.sh` points at `rex-client/dev/home` |
| `REXPLUGIN_LOG` | None: Rex points the plugin's stdout and stderr at `/dev/null` |
