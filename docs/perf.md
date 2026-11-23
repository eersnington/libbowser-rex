# CEF performance: OSR copy vs windowed zero copy

Status: shipped as `bowser-cef --mode windowed`, the default on CALAYERHOST
(see [Productionize](#productionize)). The spike measured 2026-11-23 on a MacBook Air (M4, 60 Hz built-in
display, macOS 27.2), CEF 158 (Chromium 158.0.8127.18), transport CALAYERHOST.

## Summary

| | OSR (`--mode osr`) | Windowed (`--mode windowed`) |
|---|---|---|
| How a frame reaches the host | GPU process → IOSurface → Metal blit in the browser process → our `CAContext` | GPU process's own `CAContext`, hosted in ours by a `CALayerHost`. No copy. |
| Frame time p99 (all animated pages) | 33.3 ms (a dropped frame per ~100) | 16.7 ms |
| Input to display, p50 | 31 ms | 30–31 ms (same) |
| Browser process CPU, animating | 5–10 % | 0.4–3 % |
| Browser + GPU process memory | 99 MB idle, 327 MB scrolling | 60 MB idle, 215 MB scrolling |
| Video | GPU process composites and copies each frame | Hardware overlay: GPU process GPU time 0 |

**Recommendation:** adopt windowed as the default CALAYERHOST producer. Keep
OSR for IOSURFACE. Done.

## Method

Everything is measured at the host, the way a user sees it, with one tool for
both producers: `build/cef/bowser-cef-probe` (`adapters/cef/probe.m`), driven
by `scripts/bench-latency.sh`.

- **Frames.** The probe captures its own window with ScreenCaptureKit, using a
  *display* filter limited to that window, so it gets the pixels the window
  server composited for the panel. A frame counts when a 48×48 grid of samples
  differs from the previous capture. Frame time is the gap between
  `SCStreamFrameInfoDisplayTime` stamps of consecutive new frames.
- **Input to display.** The probe stamps each input with `CLOCK_UPTIME_RAW`
  (the ABI's `timestamp_ns`) and sends it. The page flips between red and blue
  on `keydown` and `mousedown`. Latency is the display time of the first frame
  whose center pixel has the new color, minus the input stamp. Both clocks are
  mach time. It excludes only panel scanout. Inputs are 120–220 ms apart, so
  they land at every vsync phase. Results quantize to 16.7 ms (60 Hz).
- **Resize.** The window grows and shrinks between 800×600 and 1100×800 every
  frame for 4 s. A frame with the magenta window background showing at the
  right or bottom edge counts as a gutter. A positive control (SIGSTOP the
  producer mid-resize) shows 6 gutter frames, so the detector works.
- **Resources.** `proc_pid_rusage` per process (CPU time, `ri_energy_nj`,
  physical footprint), GPU time from each process's `AGXDeviceUserClient`
  `AppUsage` (what Activity Monitor reads), WindowServer CPU from `ps`.
  Processes are classed by `--type=` in their arguments. Energy is CPU energy
  only; `powermetrics` needs root and was skipped.

### The probe window

Where the probe window sits changes the numbers, so this was measured too:

| Placement | Capture |
|---|---|
| Titled window on another Space (`BOWSER_SPACE=3`) | Window capture only, about 30 Hz: the window server renders an inactive Space's window for capture, not at display rate. Display capture: nothing. |
| Below the desktop, or alpha 0 | Not composited at all: no frames |
| Current Space, alpha 0.01, ignores the mouse | Display rate. Used. |

At alpha 0.01 the window changes the screen by at most 2.5/255 of a color
step, which no one sees. Captured pixels come premultiplied (red reads about
`(2,0,0)`), so color checks compare channels, and low-contrast motion (a soft
gradient scrolling) can go uncounted. The test pages use high contrast.

## Results

`scripts/bench-latency.sh`, 800×600 pt at 2×. CPU and GPU in % of one core or
of the GPU. Columns: browser / GPU process / renderer / host / WindowServer.
Memory: browser / GPU / renderer, MB. Energy: browser + GPU + renderer, mW.
WindowServer includes the capture itself and the rest of the desktop, so
compare it across rows, not as an absolute.

| Page | Step | Producer | fps | Frame p50 / p99 ms | Latency p50 / p99 ms | CPU % | GPU % (browser / gpu / WS) | Memory MB | mW |
|---|---|---|---|---|---|---|---|---|---|
| latency | idle 5 s | OSR | 0 | – | – | 0.3 / 0.3 / 0.5 / 0.8 / 8.4 | 0 / 0 / 0 | 40 / 59 / 83 | 4 |
| latency | idle 5 s | windowed | 0 | – | – | 0.4 / 0.4 / 0.0 / 0.9 / 4.4 | 0 / 0 / 0.5 | 33 / 27 / 82 | 2 |
| latency | 100 keys | OSR | – | – | 31.4 / 66.6 | 1.3 / 1.2 / 1.4 / 0.9 / 11.8 | 0.5 / 0.7 / 2.1 | 82 / 113 / 83 | 16 |
| latency | 100 keys | windowed | – | – | 30.2 / 67.1 | 1.4 / 2.1 / 1.2 / 1.4 / 5.9 | 0 / 0 / 2.5 | 34 / 27 / 82 | 7 |
| latency | 100 clicks | OSR | – | – | 31.1 / 75.5 | 1.2 / 1.0 / 0.8 / 1.0 / 12.9 | 0.5 / 0.8 / 3.6 | 84 / 113 / 56 | 10 |
| latency | 100 clicks | windowed | – | – | 31.4 / 50.5 | 1.1 / 1.6 / 0.8 / 1.2 / 8.2 | 0 / 0 / 3.7 | 35 / 27 / 55 | 2 |
| CSS animation | 10 s | OSR | 58.1 | 16.7 / 33.3 | – | 8.6 / 9.6 / 5.9 / 2.2 / 42.8 | 5.9 / 7.1 / 27.3 | 91 / 122 / 85 | 93 |
| CSS animation | 10 s | windowed | 59.8 | 16.7 / 16.7 | – | 1.4 / 4.1 / 3.8 / 1.6 / 35.4 | 0 / 0 / 26.0 | 33 / 38 / 86 | 80 |
| CSS animation | live resize 4 s | OSR | 50.1 | 16.7 / 33.3 | – | 11.2 / 16.3 / 6.7 / 6.6 / 43.8 | 5.1 / 8.8 / 28.3 | 92 / 190 / 88 | 258 |
| CSS animation | live resize 4 s | windowed | 59.5 | 16.7 / 16.7 | – | 9.3 / 11.2 / 7.2 / 6.2 / 43.0 | 0 / 6.1 / 28.3 | 35 / 274 / 91 | 295 |
| canvas 2D, rAF | 10 s | OSR | 59.4 | 16.7 / 33.3 | – | 5.3 / 10.7 / 5.4 / 1.6 / 32.6 | 2.4 / 10.4 / 21.3 | 93 / 159 / 96 | 258 |
| canvas 2D, rAF | 10 s | windowed | 60.0 | 16.7 / 16.7 | – | 0.5 / 12.8 / 7.5 / 2.4 / 45.6 | 0 / 9.4 / 28.6 | 33 / 121 / 99 | 93 |
| VP9 1080p60 video | 10 s | OSR | 58.4 | 16.7 / 33.3 | – | 7.3 / 15.3 / 2.7 / 2.3 / 41.7 | 5.4 / 12.4 / 24.7 | 92 / 128 / 97 | 89 |
| VP9 1080p60 video | 10 s | windowed | 59.6 | 16.7 / 16.7 | – | 0.5 / 9.2 / 2.8 / 2.7 / 40.6 | 0 / 0 / 26.1 | 35 / 32 / 100 | 36 |
| Wikipedia, trackpad scroll | 10 s | OSR | 56.7 | 16.7 / 33.3 | – | 10.0 / 12.4 / 10.2 / 2.8 / 40.8 | 5.7 / 9.2 / 24.4 | 106 / 221 / 147 | 113 |
| Wikipedia, trackpad scroll | 10 s | windowed | 57.9 | 16.7 / 16.7 | – | 2.8 / 5.5 / 9.1 / 2.7 / 40.3 | 0 / 0.6 / 26.8 | 41 / 174 / 152 | 56 |

Resize gutters: 0 frames in both. OSR fps varies run to run (46–58 on the
animation page across three runs); windowed held 59.5–60 in every run.

GPU process restart (`kill -9` of the GPU helper mid-animation): windowed's
longest frame gap was 83 ms and Chromium's context ID changed once; OSR's was
117 ms.

## Findings

1. **Nested remote hosting composites correctly.** Host `CALayerHost` →
   producer `CAContext` → Chromium's GPU `CAContext` shows the page upright and
   at the right scale; the producer's root layer is already flipped, which is
   what Chromium's GPU layer tree expects.
2. **Hidden-window placement is the whole game.**
   - Never order the window in, and keep its frame on a display (`--placement
     unordered`, the default). Chromium keeps drawing, with or without
     `--disable-backgrounding-occluded-windows`. (The merged engine drops
     that switch: it reports a tab with no host occluded, to hide it.)
   - A window ordered in *off every display* draws at first, then, once the
     page idles, never draws again: the window has no `screen`, and Chromium
     paces frames by the window's display. Its first frames made this look
     fine. The spike's screen-capture checks failed all three. An
     *unordered* window off every display kept drawing (measured in the
     merged engine), but its screen still sets the refresh rate.
   - An unordered window is never on screen, never focused, not in the Dock or
     ⌘Tab (activation policy prohibited), not in screenshots
     (`NSWindowSharingNone`).
3. **Context ID changes, and the mirror follows in the same commit.** It is
   stable across resize, changes on a cross-site navigation and on a GPU
   process restart. The producer hooks `-[CALayerHost setContextId:]` in its own
   process, so the mirror changes inside Chromium's own `CATransaction`: no
   polling, no extra frame.
4. **Resize:** no stretched or blank frames in either, at a per-frame resize.
   Windowed keeps 60 fps while resizing; OSR drops to 50.
5. **Input is Chromium's own Mac input path.** Synthesized `NSEvent`s go to
   `RenderWidgetHostViewCocoa` (`mouseDown:`, `keyDown:`, `scrollWheel:` built
   from a `CGEvent` with phases). Its `inputContext` is swapped for one that
   replays the host's `insertText:`/`setMarkedText:`/`unmarkText` *inside*
   `keyDown:`, so Chromium sees text exactly as AppKit delivers it. Verified on
   a page field: `keydown`/`keypress`/`input` for typed text,
   `compositionstart`/`update`/`end` for marked text, Return commits a
   composition without a `keypress`, Backspace and Return act as commands.
   Gotcha: `CGEvent` numbers scroll phases differently from `NSEventPhase`;
   unconverted, only the first event of a gesture scrolls.
6. **Latency is unchanged at 60 Hz** (both p50 ≈ 31 ms, two vsyncs). The
   1–2 ms blit rarely crosses a vsync boundary. The win is frame pacing:
   OSR's p99 is a dropped frame on every animated page; windowed has none.
   120 Hz (ProMotion) was not available to test.
7. **Native feel.**
   - Cursor: from `on_cursor_change`, as with OSR. Works.
   - Focus: the hidden window reports `isKeyWindow` from the host's focus,
     so Chromium treats the view as active (`document.hasFocus()` is true while
     the host has focus, false after). Focus rings and caret blink follow from
     that; not checked by eye.
   - IME caret: from Chromium's own `firstRectForCharacterRange:`. The caret
     tracks; per-character composition rects come back zero-width, so the
     candidate window anchors at the start of the composition. (Merged
     engine: asked one character at a time, Chromium answers every range with
     the caret; it has no composition bounds from the renderer in windowed
     CEF. The host gets one rect.)
   - Scrollbars: overlay or legacy follows the system setting, as in Chrome.
   - Context menus and tooltips: suppressed, as in OSR. **`<select>` popups**
     in windowed mode are native `NSMenu`s from the producer process; they
     would appear on the user's screen at the hidden window's position. Not
     exercised, to keep a menu off the user's screen; must be handled first.

## Productionize

Done in `bowser-cef` (`adapters/cef/windowed.m`), checked by `make test-cef`
through real processes:

| Blocker | How |
|---|---|
| `<select>` | Chromium 158's WebMenuRunner shows an `NSPopUpButtonCell` menu. A hook on `-[NSPopUpButtonCell performClickWithFrame:inView:]` (and `popUpMenuPositioningItem:` / `popUpContextMenu:`, which Chromium also links) sends the `menu` message, waits for `menu_result` in a nested run loop, then selects the item and sends its action, as the real menu would. AppKit's entry points, not Chromium's, so a WebMenuRunner rewrite still lands in them. |
| Context menus | CEF's `run_context_menu`, both modes: `menu` with `kind: "context"`, then `cont` or `cancel`. |
| Other native UI | No window of the engine is ever ordered in (hooks on NSWindow's ordering methods). Popup widgets (date pickers, `<datalist>`) are `RenderWidgetPopupWindow`s: mirrored over the page and given the input over them, like the page. Drags out of a page end at once. |
| Multiple surfaces | One hidden window per tab. A Chromium `CALayerHost` is found by `setContextId:` or `addSublayer:`; its layer's view leads to its window, and the window to its tab. |
| Displays | `bowser_host_set_display` (ABI) moves the tab's hidden window to the host's display. Untested beyond one display: this machine has one. |
| Hidden tabs | The hidden window answers Chromium's `isOccluded` from "a host is attached", so a tab no host shows is hidden, as a background tab. Hiding the view instead left it unable to take focus. |

Re-measured in the merged engine, 2026-11-23, the CSS animation page, 800×500
pt, `bowser-host` on another Space, 10 s, two runs, CPU as % of one core:

| | Browser process | GPU process | Renderer |
|---|---|---|---|
| OSR | 13.5–15.2 % | 13.6–15.7 % | 8.4–8.8 % |
| Windowed | 2.7–2.8 % | 8.0–8.5 % | 7.2–7.5 % |

Display-rate frame times and latency were not re-measured: the probe needs a
window on the current Space.

Still open:

- The private API surface: `CALayerHost`, swizzled `inputContext`,
  `-[CALayerHost setContextId:]`, NSWindow's `_doOrderWindow:`, and Chromium's
  `isOccluded` and occlusion-notification key.
- Rerun on a 120 Hz display, and with two displays.

## Reproduce

```sh
scripts/bench-latency.sh                       # both modes, every page (~7 min)
scripts/bench-latency.sh "osr windowed" latency
BOWSER_SPACE=3 make test-cef                   # also checks real host windows on Space 3
```

`bench-latency.sh` puts its probe window (alpha 0.01) on the current Space.
The terminal needs the Screen Recording permission. The video page needs
`ffmpeg` once, to write `build/bench/video.webm` (VP9: CEF has no H.264).
