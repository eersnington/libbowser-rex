#!/usr/bin/env python3
"""Merge one capture's lanes into DIR/trace.json.gz, then delete the inputs.

  perf-capture.py DIR [FROM_US TO_US]

Inputs in DIR: chrome.json (the engine's trace), client.jsonl (the Rex client
lane, any length), window.jsonl and load.jsonl. Only events between FROM_US
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


def main(d, lo=float("-inf"), hi=float("inf")):
    with open(os.path.join(d, "chrome.json")) as f:
        events = json.load(f)["traceEvents"]
    for lane in ("client.jsonl", "window.jsonl", "load.jsonl"):
        events += lines(os.path.join(d, lane))
    keep = [e for e in events
            if e.get("ph") == "M" or (lo <= e.get("ts", 0) + e.get("dur", 0) and e.get("ts", 0) <= hi)]
    with gzip.open(os.path.join(d, "trace.json.gz"), "wt", compresslevel=6) as f:
        json.dump({"traceEvents": keep}, f, separators=(",", ":"))
    for name in ("chrome.json", "client.jsonl", "window.jsonl", "load.jsonl"):
        p = os.path.join(d, name)
        if os.path.exists(p):
            os.remove(p)


if __name__ == "__main__":
    a = sys.argv[1:]
    main(a[0], *(float(x) for x in a[1:3]))
