#!/usr/bin/env python3
"""Merge one capture's lanes into DIR/trace.json.gz, then delete the inputs.

  perf-capture.py DIR [FROM_US TO_US]

Inputs in DIR: chrome.json (the engine's trace), client.jsonl (the Rex client
lane, any length), load.jsonl, and screen.jsonl: framegaps' stream of window
and pane frames, which becomes one slice per frame interval (per window, and
per pane, named from names.json), leaving out the time a window was hidden. Only events between FROM_US
and TO_US (µs of mach time) are kept, plus every name and thread record, so
a capture stays a few MB however long the recorders ran.
"""
import gzip
import json
import os
import sys


def lines(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(l) for l in f if l.strip()]


def screen(lines, names):
    hidden, series = {}, {}
    for e in lines:
        if "on" in e:
            hidden.setdefault(e["w"], []).append((e["ts"], e["on"]))
        else:
            series.setdefault((e["w"], e.get("p")), []).append(e["ts"])

    def was_hidden(w, a, b):
        state = True
        for ts, on in hidden.get(w, []):
            if ts > b:
                break
            if ts > a and not on:
                return True
            state = on
        return not state

    out = [{"name": "process_name", "ph": "M", "pid": 1, "args": {"name": "Rex windows on screen"}},
           {"name": "process_name", "ph": "M", "pid": 3, "args": {"name": "Panes on screen"}}]
    panes = sorted({p for _, p in series if p})
    for (w, p), ts in sorted(series.items(), key=lambda kv: (kv[0][0], kv[0][1] or "")):
        pid, tid = (3, panes.index(p) + 1) if p else (1, w)
        label = f"pane {names.get(p, p[-6:])}" if p else f"window {w}"
        out.append({"name": "thread_name", "ph": "M", "pid": pid, "tid": tid, "args": {"name": label}})
        ts.sort()
        for a, b in zip(ts, ts[1:]):
            if not was_hidden(w, a, b):
                out.append({"name": "frame", "cat": "pane" if p else "window", "ph": "X", "pid": pid, "tid": tid,
                            "ts": a, "dur": b - a})
    return out


def main(d, lo=float("-inf"), hi=float("inf")):
    with open(os.path.join(d, "chrome.json")) as f:
        events = json.load(f)["traceEvents"]
    for lane in ("client.jsonl", "window.jsonl", "load.jsonl"):
        events += lines(os.path.join(d, lane))
    names_path = os.path.join(d, "names.json")
    names = json.load(open(names_path)) if os.path.exists(names_path) else {}
    events += screen(lines(os.path.join(d, "screen.jsonl")), names)
    keep = [e for e in events
            if e.get("ph") == "M" or (lo <= e.get("ts", 0) + e.get("dur", 0) and e.get("ts", 0) <= hi)]
    with gzip.open(os.path.join(d, "trace.json.gz"), "wt", compresslevel=6) as f:
        json.dump({"traceEvents": keep}, f, separators=(",", ":"))
    for name in ("chrome.json", "client.jsonl", "window.jsonl", "load.jsonl", "screen.jsonl", "names.json"):
        p = os.path.join(d, name)
        if os.path.exists(p):
            os.remove(p)


if __name__ == "__main__":
    a = sys.argv[1:]
    main(a[0], *(float(x) for x in a[1:3]))
