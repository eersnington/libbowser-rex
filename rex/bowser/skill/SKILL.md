---
name: bowser
description: Drive a Rex browser pane with the bowser CLI: open a page beside your terminal, read it, click and type in it, and see the result. Use when asked to open, check, test, or click through a web page or a local web app in Rex, or when a UI change needs proof in a real browser.
---

# bowser

`bowser` drives the browser panes of the Rex session your terminal is in. The
person sees every pane you drive. `bowser --help` lists every command and its
arguments; this file is how to use them well.

## The loop

Work in a loop of **look, act, look**. Each step is done only when a fresh
look shows the result you expected.

1. **Have a pane.** `bowser ls`. With none, or only ones the person opened
   for themselves: `bowser open URL --split right`. URL can be
   `localhost:3000`, a path to an HTML file, or words to search for. It returns
   when the page has loaded and prints the new pane's id.
2. **Look.** `bowser snapshot -i` lists what you can act on, one element per
   line, each with a ref: `- button "Save" [ref=e4]`. A plain `bowser snapshot`
   adds the page's text and structure.
3. **Act** on refs from the newest snapshot: `bowser click e4`,
   `bowser fill e2 "ribbet@example.com"`, `bowser press Enter`. A CSS selector
   works where no ref fits: `bowser click "#save"`.
4. **Look again**: `bowser wait --text "Saved"`, `bowser snapshot -i`, or
   `bowser eval "document.title"`. An exit code of 0 from `click` only proves
   the click happened, not that the page did what you wanted.

## Refs

- A ref belongs to the newest snapshot of its pane. Take a new snapshot after
  each navigation, and after the page redraws the part you act on. A stale ref
  fails with "take a new snapshot"; that is the cue, not a bug.
- The snapshot covers the page's main frame. Reach into an iframe with
  `bowser eval`.

## Waiting

- `open`, `goto`, `back`, `forward`, and `reload` return once the page has
  loaded.
- `click`, `fill`, `type`, and `press` return at once. After one that loads
  something, wait for what it leads to: `bowser wait --text TEXT`,
  `bowser wait SELECTOR`, or `bowser wait` for a page load. One wait lasts at
  most 8 s; repeat it for slower work.

## Seeing

`bowser screenshot` saves a PNG and prints its path; read that file to see the
page. Use it for layout, color, and anything visual. Use `snapshot` for what
the page holds and what you can act on.

## Several panes

Commands act on the session's only browser pane, or the only one in your
window. With more, add `-b PANE`, an id from `bowser ls`. A link that opens a
new window opens a new pane beside its own, so a click can add a pane; run
`bowser ls` after one.

## What the person sends you

The browser's right-click menu has Send to Agent. It pastes a message that
starts `From the browser pane:`, with the page's title and URL, any selected
text (`> ` lines), and the element clicked: an `Element:` selector, then its
HTML. That selector is a `bowser` target, so `bowser click "SELECTOR"` acts on
the very element the person means.

## The page's limits

- `alert`, `confirm`, and `prompt` never show: `confirm` returns false and
  `prompt` returns null. Test flows behind them with `bowser eval`.
- File pickers never open. Upload with `bowser cdp DOM.setFileInputFiles`.
- Pages share one browser profile: a site the person signed in to is signed
  in for you too. Stay on the sites the task names.

## Errors

| Error starts with | Do |
|---|---|
| `no browser pane in this session` | `bowser open URL` |
| `several browser panes` | Pick one: `bowser -b PANE …` |
| `rex reaches a Rex server that doesn't have this pane` | Your terminal's Rex server isn't the one `rex` reaches. Run in a terminal pane of the Rex that shows the browser (the dev Rex sets `REX_SERVER` for its panes). |
| `bowser: command not found` | Browser panes run in the libbowser dev Rex; its panes have `bowser` on PATH. |
