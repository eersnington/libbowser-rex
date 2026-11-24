# bowser-cef

One CEF engine (CEF 158) that serves many libbowser surfaces. Each surface
is one browser tab. All tabs share one profile and CEF's GPU, network, and
storage processes.

```sh
make cef
build/bowser-cef.app/Contents/MacOS/bowser-cef [--profile DIR] [--mode M]   # control mode
build/bowser-cef.app/Contents/MacOS/bowser-cef [--profile DIR] [--mode M] \
  [--transport calayerhost|iosurface] [--url URL] [--tickets N]             # one tab
```

A tab renders in one of two modes:

| Mode | Transport | How a frame reaches the host |
|---|---|---|
| `windowed` (default) | CALAYERHOST | Zero copy. Chromium runs windowed, in a window that is never on screen; the surface hosts Chromium's own GPU-process layers. See `docs/perf.md`. |
| `osr` | IOSURFACE, or CALAYERHOST with `--mode osr` | Off-screen rendering: a Metal copy of each frame. |

| Flag | Meaning |
|---|---|
| `--mode windowed\|osr` | The mode of CALAYERHOST tabs that `open` gives none. Default `windowed`. IOSURFACE tabs are always `osr`. |
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
| `{"id":1,"cmd":"open","url":"…","transport":"calayerhost","mode":"windowed"}` | `{"id":1,"surface":"1","mode":"windowed"}`. `url` is fixed up like `navigate`; default `about:blank`. `transport` defaults to `calayerhost`; `mode` to the engine's (see `--mode`). `windowed` needs `calayerhost`. |
| `{"id":2,"cmd":"ticket","surface":"1"}` | `{"id":2,"ticket":"bowser3:…"}`: a fresh single-use ticket, valid for 60 s. |
| `{"id":3,"cmd":"close","surface":"1"}` | `{"id":3}`. The surface's host gets `detached_cb(BOWSER_ERR_DISCONNECTED)`. |
| `{"id":4,"cmd":"message","surface":"1","name":"navigate","body":{"url":"…"}}` | `{"id":4}`. Any message from the vocabulary below. |
| `{"id":5,"cmd":"trace_start","categories":"…"}` | `{"id":5,"trace_us":…,"mach_us":…}`. Starts Chromium's trace of every engine process. `categories` defaults to a frame-timing set. The trace's clock is mach time in µs: the two values match. |
| `{"id":6,"cmd":"trace_stop","path":"/abs/trace.json"}` | `{"id":6}`. The file appears at `path` once every process has sent its events. With no `path`, the trace is thrown away: Chromium's buffer stops recording when full (about 640 MB, 2 minutes of one busy tab), so a long-running recorder restarts it this way. |

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
| `menu_result` | `{"id","index"}` | The answer to a `menu`: the chosen item's index in the flattened items, or `-1` for dismissed. |

A malformed message is logged to stderr and ignored. A host gets no answer.

### Producer to host

| Name | Body | When |
|---|---|---|
| `state` | `{"url","title","loading","progress","can_go_back","can_go_forward"}` | On attach, at once, and then on every change, at most once per frame. `progress` is 0 to 1. |
| `find_result` | `{"count","active"}` | When a search settles. `active` counts from 1; 0 means no active match. |
| `menu` | `{"id","kind","x","y","selected","items"}` | The page opened a menu, which the host shows. See [Menus](#menus). |

The library never replays messages to a host that attaches later, so the
engine sends `state` from `attach_cb`.

### Menus

The producer has no window on screen, so the host shows every menu, as a
native menu of its own, and answers with `menu_result`:

```json
{"id": 7, "kind": "select", "x": 10, "y": 10, "selected": 0,
 "items": [{"label": "a", "enabled": true, "checked": false, "separator": false},
           {"label": "", "enabled": false, "checked": false, "separator": true},
           {"label": "More", "enabled": true, "checked": false, "separator": false,
            "children": [{"label": "b", "enabled": true, "checked": false, "separator": false}]}]}
```

| Field | Meaning |
|---|---|
| `id` | Echo it in `menu_result`. |
| `kind` | `select`: a `<select>` list (windowed tabs). `context`: a right click (both modes). |
| `x`, `y` | Surface points, top-left origin. `select`: the control's top-left corner; put the `selected` item there, as `NSMenu.popUp(positioning:at:in:)` does. `context`: the click; put the menu's top-left there. |
| `selected` | Index of the current item, or `-1`. |
| `items` | `label`, `enabled`, `checked`, `separator`, and `children` for a submenu. |

`index` counts items **flattened depth first**: an item, then its children,
then its next sibling. Separators and submenu items count. Above, `a` is 0,
the separator 1, `More` 2, and `b` 3. Choosing a separator, a disabled item,
or a submenu item counts as dismissed.

`<select>` in a windowed tab blocks Chromium until the answer, as a native
menu does; the engine keeps running meanwhile. The engine dismisses a menu
(`-1`) when no host is attached, when the host leaves or another takes over,
when the tab closes, or after 30 s without an answer. A `menu_result` for a
menu that is no longer open is logged and ignored.

Context menus keep CEF's edit and history items (Back, Forward, Reload, Undo
… Select All, spelling suggestions) and add Open Link and Copy Link Address on
links. Open Link loads in the same tab.

In OSR tabs, `<select>` stays a popup drawn into the page (see Behavior): CEF
gives OSR the popup's pixels, not its items.

### Typed addresses

`navigate` and `open` take what the user typed:

| Input | Loads |
|---|---|
| Has a scheme with `://`, or is `about:`, `data:`, `mailto:`, `view-source:` | As is |
| One word that looks like a host (`example.com`, `example.com/a?b`) | `https://` + input |
| `localhost` or an IP address, with an optional port | `http://` + input |
| A path to a file that exists (`/tmp/a.html`, `~/notes.html`) | The `file://` URL |
| Anything else (`two words`, `example`) | `https://duckduckgo.com/?q=` + input |

On an error page, `state.url` is the address that failed, not the one before it.

## Behavior

- **Popups.** OSR: `<select>` lists and other popup widgets arrive as a
  separate paint (`PET_POPUP`). On CALAYERHOST they are a sublayer over the
  page; on IOSURFACE they are drawn into each frame. Windowed: `<select>` is a
  `menu`; other popup widgets (date pickers, `<datalist>`) are Chromium windows
  that never come on screen; their layers are mirrored over the page, and
  input over them goes to them. Either way a popup stays inside the view.
- **New windows.** Links with `target=_blank` and `window.open` load in the
  same tab. The vocabulary has no "new tab" message yet.
- **Hidden tabs.** A tab with no host is hidden: Chromium stops painting it
  and throttles it. An OSR tab keeps only its newest frame.
- **Displays.** A windowed tab paces frames to the display its host reports
  with `bowser_host_set_display`; until then, the main display.
- **Never on screen.** No window of the engine is ever ordered in, in either
  mode: menus go to the host, popup widgets are mirrored, drags out of a page
  end at once with nothing dropped.
- **Suppressed UI.** JavaScript dialogs, file pickers, tooltips, the color
  panel, and `beforeunload` prompts never show.
