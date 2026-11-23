# bowser-cef

One CEF engine (CEF 158, off-screen rendering) that serves many libbowser
surfaces. Each surface is one browser tab. All tabs share one profile and
CEF's GPU, network, and storage processes.

```sh
make cef
build/bowser-cef.app/Contents/MacOS/bowser-cef [--profile DIR]           # control mode
build/bowser-cef.app/Contents/MacOS/bowser-cef [--profile DIR] \
  [--transport calayerhost|iosurface] [--url URL] [--tickets N]          # one tab
```

| Flag | Meaning |
|---|---|
| `--profile DIR` | Cookies, logins, cache, and site zoom. Default: `$HOME/Library/Application Support/libbowser/profile`. Chromium locks a profile: a second engine on the same one exits with an error. |
| `--url`, `--tickets`, `--transport` | One-tab mode, for tests, demos, and benchmarks. Opens `URL` (default `https://example.com`), prints `N` tickets (default 1), one per line, and runs until SIGTERM. |

With neither `--url` nor `--tickets`, the engine runs in **control mode**:
JSON lines on stdin and stdout. It exits when stdin closes, so it never
outlives its parent.

## Control protocol

One JSON object per line. Each command can carry an `id`; the reply carries
the same `id`. A failed command replies `{"id":…,"error":"…"}`.

| Command | Reply |
|---|---|
| `{"id":1,"cmd":"open","url":"…","transport":"calayerhost"}` | `{"id":1,"surface":"1"}`. `url` is fixed up like `navigate`; default `about:blank`. `transport` defaults to `calayerhost`. |
| `{"id":2,"cmd":"ticket","surface":"1"}` | `{"id":2,"ticket":"bowser2:…"}`: a fresh single-use ticket, valid for 60 s. |
| `{"id":3,"cmd":"close","surface":"1"}` | `{"id":3}`. The surface's host gets `detached_cb(BOWSER_ERR_DISCONNECTED)`. |
| `{"id":4,"cmd":"message","surface":"1","name":"navigate","body":{"url":"…"}}` | `{"id":4}`. Any message from the vocabulary below. |

Events have no `id`:

| Event | When |
|---|---|
| `{"event":"ready","pid":…}` | Once, when the engine takes commands. |
| `{"event":"state","surface":"1",…}` | The `state` message below, as sent to the host. |
| `{"event":"find_result","surface":"1",…}` | The `find_result` message below. |
| `{"event":"attached","surface":"1","attached":true}` | A host attached or detached. |
| `{"event":"closed","surface":"1"}` | The page closed itself. The surface is gone. |

## Browser messages

The vocabulary on the libbowser message channel (`bowser_host_send`,
`bowser_surface_send`). Bodies are JSON objects.

### Host to producer

| Name | Body | Does |
|---|---|---|
| `navigate` | `{"url"}` | Loads what the user typed. See [Typed addresses](#typed-addresses). |
| `back`, `forward`, `reload`, `stop` | none | History and loading. |
| `edit` | `{"command"}` | `copy`, `cut`, `paste`, `select_all`, `undo`, `redo`, or `delete`, in the focused frame. Copy and cut write the general pasteboard. |
| `find` | `{"text","forward":true,"next":false}` | `next: false` starts a search at the first match; `next: true` moves to the next one (or the previous, with `forward: false`). |
| `find_stop` | none | Ends the search. The active match stays selected, as in Safari. |
| `zoom` | `{"delta"}` | `1` or `-1` steps through Chromium's zoom levels; `0` resets. Zoom is kept per site in the profile. |

A malformed message is logged to stderr and ignored. A host gets no answer.

### Producer to host

| Name | Body | When |
|---|---|---|
| `state` | `{"url","title","loading","progress","can_go_back","can_go_forward"}` | On attach, at once, and then on every change, at most once per frame. `progress` is 0 to 1. |
| `find_result` | `{"count","active"}` | When a search settles. `active` counts from 1; 0 means no active match. |

The library never replays messages to a host that attaches later, so the
engine sends `state` from `attach_cb`.

### Typed addresses

`navigate` and `open` take what the user typed:

| Input | Loads |
|---|---|
| Has a scheme with `://`, or is `about:`, `data:`, `mailto:`, `view-source:` | As is |
| One word that looks like a host (`example.com`, `example.com/a?b`) | `https://` + input |
| `localhost` or an IP address, with an optional port | `http://` + input |
| Anything else (`two words`, `example`) | `https://duckduckgo.com/?q=` + input |

On an error page, `state.url` is the address that failed, not the one before it.

## Behavior

- **Popups.** `<select>` lists and other popup widgets arrive as a separate
  paint (`PET_POPUP`). On CALAYERHOST they are a sublayer over the page; on
  IOSURFACE they are drawn into each frame. A popup stays inside the view.
- **New windows.** Links with `target=_blank` and `window.open` load in the
  same tab. The vocabulary has no "new tab" message yet.
- **Hidden tabs.** A tab with no host is hidden: Chromium stops painting it
  and throttles it, and it keeps only its newest frame.
- **Suppressed UI.** Context menus, JavaScript dialogs, file pickers, and
  `beforeunload` prompts never show: the engine has no window to put them in.
