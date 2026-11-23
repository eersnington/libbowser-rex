#!/usr/bin/env python3
"""Merge a perf-trace.sh run into one trace, and explain each late frame.

  perf-report.py DIR

DIR holds chrome.json (the engine's Chromium trace), client.jsonl (the Rex
client's lane), load.jsonl (GPU and CPU load) and, when the window was on
screen, window.jsonl (what WindowServer composited). Every timestamp is µs of mach time. Writes
DIR/trace.json, for https://ui.perfetto.dev or chrome://tracing, and prints:

  - per tab: frames presented, dropped, and the gaps between presented frames
    while the page was animating
  - every late frame in any lane, with the slices that overlapped it, longest
    first, by process and thread: what was busy while the frame was late
"""
import bisect
import json
import os
import sys

VSYNC = 16_667  # µs at 60 Hz
LATE = 1.5 * VSYNC  # a gap this long means at least one frame was missed
BUSY = 4_000  # overlapping slices shorter than this are noise


def load_jsonl(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def main(d):
    chrome = json.load(open(os.path.join(d, "chrome.json")))["traceEvents"]
    client = load_jsonl(os.path.join(d, "client.jsonl"))
    window = load_jsonl(os.path.join(d, "window.jsonl"))
    load = load_jsonl(os.path.join(d, "load.jsonl"))
    events = chrome + client + window + load
    counters = {}
    for e in load:
        if e.get("ph") == "C":
            counters.setdefault(e["name"], []).append((e["ts"], e["args"]))

    def load_during(start, end):
        # Mean of each counter over the samples that overlap [start, end].
        out = []
        for name, samples in counters.items():
            hit = [a for (ts, a), (nxt, _) in zip(samples, samples[1:] + [(float("inf"), None)]) if ts < end and nxt > start]
            if hit:
                mean = {k: sum(a[k] for a in hit) / len(hit) for k in hit[0]}
                out.append(name + ": " + ", ".join(f"{k} {v:.0f}" for k, v in sorted(mean.items(), key=lambda kv: -kv[1])))
        return out
    json.dump({"traceEvents": events}, open(os.path.join(d, "trace.json"), "w"))

    pname = {e["pid"]: e["args"]["name"] for e in events if e.get("ph") == "M" and e["name"] == "process_name"}
    tname = {(e["pid"], e["tid"]): e["args"]["name"] for e in events if e.get("ph") == "M" and e["name"] == "thread_name"}
    labels = {e["pid"]: e["args"].get("labels") for e in events if e.get("ph") == "M" and e["name"] == "process_labels"}
    t0 = min(e["ts"] for e in events if "ts" in e and e.get("ph") != "M")

    def where(e):
        p = pname.get(e["pid"], str(e["pid"]))
        if labels.get(e["pid"]):
            p += f" ({labels[e['pid']]})"
        return f"{p} / {tname.get((e['pid'], e.get('tid')), e.get('tid'))}"

    def at(ts):
        return f"{(ts - t0) / 1e6:7.3f}s"

    slices = [e for e in events if e.get("ph") == "X" and e.get("dur", 0) >= BUSY and e.get("cat") != "window"]

    by_thread = {}
    for e in slices:
        by_thread.setdefault((e["pid"], e.get("tid")), []).append(e)

    def chain(top):
        # The slices nested in `top` that take most of it: what it was doing.
        names, cur = [top["name"]], top
        inner = by_thread[(top["pid"], top.get("tid"))]
        while len(names) < 9:
            kids = [e for e in inner if e is not cur and e["ts"] >= cur["ts"] and e["ts"] + e["dur"] <= cur["ts"] + cur["dur"]
                    and e["dur"] >= cur["dur"] * 0.5 and e["dur"] < cur["dur"] + 1]
            kids = [k for k in kids if k["dur"] < cur["dur"] or k["ts"] > cur["ts"]]
            if not kids:
                break
            cur = max(kids, key=lambda e: e["dur"])
            arg = cur.get("args", {}).get("data", {})
            names.append(cur["name"] + (f" ({arg.get('functionName') or arg.get('url') or ''})".replace(" ()", "")
                                        if isinstance(arg, dict) else ""))
        # Skip the generic task wrappers; keep where it ended up.
        return " > ".join(names if len(names) <= 4 else [names[0], "…"] + names[-3:])

    def busy(start, end):
        hits = [e for e in slices if e["ts"] < end and e["ts"] + e["dur"] > start]
        # Keep the outermost slice per thread: nested ones repeat it.
        hits.sort(key=lambda e: (-e["dur"], e["ts"]))
        out, seen = [], set()
        for e in hits:
            key = (e["pid"], e.get("tid"))
            if key in seen:
                continue
            seen.add(key)
            out.append(f"      {e['dur'] / 1000:6.1f} ms  {where(e)}: {chain(e)}")
        out = out[:6]
        # A process that logs every frame but went quiet was stopped, starved
        # of CPU, or blocked in the kernel: its slices can't show that.
        for pid, ts in stamps.items():
            i, j = bisect.bisect_left(ts, start), bisect.bisect_right(ts, end)
            window = ts[max(i - 1, 0):j + 1]
            gap = max((b - a for a, b in zip(window, window[1:])), default=0)
            if gap >= max(LATE, 4 * usual_gap[pid]):
                out.append(f"      {gap / 1000:6.1f} ms  {pname.get(pid, pid)} logged nothing "
                           "(stopped, starved of CPU, or blocked in the kernel)")
        return out or ["      (nothing busy and nothing silent in the trace: look outside the engine and Rex)"]

    # Event times per process that logs at least once a frame, for `busy`.
    per_pid = {}
    for e in chrome:
        if "ts" in e and e.get("ph") != "M":
            per_pid.setdefault(e["pid"], []).append(e["ts"])
    span = max(e["ts"] for e in events if "ts" in e) - t0
    stamps = {pid: sorted(ts) for pid, ts in per_pid.items() if len(ts) > span / VSYNC}
    usual_gap = {}
    for pid, ts in stamps.items():
        g = sorted(b - a for a, b in zip(ts, ts[1:]))
        usual_gap[pid] = g[int(len(g) * 0.99)]

    late = []  # (lane, start, end)

    # Tabs: one PipelineReporter per renderer frame, ending at presentation.
    tabs = {}
    for e in chrome:
        if e.get("name") != "PipelineReporter":
            continue
        tab = tabs.setdefault(e["pid"], {"begin": {}, "frames": []})
        key = json.dumps(e.get("id2") or e.get("id"))
        if e["ph"] == "b":
            tab["begin"][key] = e
        elif e["ph"] == "e" and key in tab["begin"]:
            b = tab["begin"].pop(key)
            tab["frames"].append((b["args"]["frame_reporter"], b["ts"], e["ts"]))
    print("Tabs (one renderer each):")
    for pid, tab in tabs.items():
        frames = sorted(tab["frames"], key=lambda f: f[2])
        states = {}
        for fr, _, _ in frames:
            states[fr.get("state")] = states.get(fr.get("state"), 0) + 1
        shown = [(fr, end) for fr, _, end in frames if fr.get("state", "").startswith("STATE_PRESENTED")]
        animating = [
            (a, b) for (fa, a), (fb, b) in zip(shown, shown[1:])
            if fb.get("has_main_animation") or fb.get("has_compositor_animation") or fb.get("scroll_state") != "SCROLL_NONE"
        ]
        gaps = sorted(b - a for a, b in animating)
        name = where({"pid": pid, "tid": None}).split(" / ")[0]
        print(f"  {name} pid {pid}: {len(frames)} frames {states}")
        if gaps:
            p99 = gaps[min(len(gaps) - 1, int(len(gaps) * 0.99))]
            print(f"    presented while animating: p50 {gaps[len(gaps) // 2] / 1000:.1f} ms, p99 {p99 / 1000:.1f} ms, "
                  f"max {gaps[-1] / 1000:.1f} ms, late {sum(g > LATE for g in gaps)}")
        for a, b in animating:
            if b - a > LATE:
                late.append((f"tab {pid}: presented frames", a, b))
        for fr, start, end in frames:
            if fr.get("state") == "STATE_DROPPED":
                late.append((f"tab {pid}: dropped frame", start, end))

    # The GPU process hands each frame to Core Animation here.
    commits = sorted(e["ts"] for e in chrome if e.get("name") == "CommitPresentedFrameToCA")
    if len(commits) > 1:
        g = sorted(b - a for a, b in zip(commits, commits[1:]))
        print(f"GPU → WindowServer commits: {len(commits)}, p50 {g[len(g) // 2] / 1000:.1f} ms, max {g[-1] / 1000:.1f} ms")

    shown = sorted((e["ts"], e["dur"]) for e in window if e.get("name") == "frame")
    if shown:
        g = sorted(d for _, d in shown)
        print(f"Rex window on screen: {len(g)} frames, p50 {g[len(g) // 2] / 1000:.1f} ms, max {g[-1] / 1000:.1f} ms, "
              f"late {sum(x > LATE for x in g)}")
        late += [("Rex window on screen", ts, ts + d) for ts, d in shown if d > LATE]
    else:
        print("Rex window on screen: not measured (window was off screen)")

    for line in load_during(t0, float("inf")):
        print(f"Load over the whole trace: {line}")
    stalls = [e for e in client if e.get("name") == "main thread busy"]
    if stalls:
        print(f"Rex main thread: {len(stalls)} turns of 4 ms or more, longest {max(e['dur'] for e in stalls) / 1000:.1f} ms")

    # One spike per burst: late frames that touch or sit within two vsyncs.
    late.sort(key=lambda x: x[1])
    spikes = []
    for lane, start, end in late:
        if spikes and start <= spikes[-1]["end"] + 2 * VSYNC:
            sp = spikes[-1]
            sp["end"] = max(sp["end"], end)
            sp["lanes"][lane] = sp["lanes"].get(lane, 0) + 1
        else:
            spikes.append({"start": start, "end": end, "lanes": {lane: 1}})
    print(f"\nSpikes: {len(spikes)} ({len(late)} late or dropped frames)")
    for sp in spikes[:25]:
        lanes = ", ".join(f"{n}× {lane}" for lane, n in sp["lanes"].items())
        print(f"  {at(sp['start'])}  {(sp['end'] - sp['start']) / 1000:.0f} ms: {lanes}")
        print("\n".join(busy(sp["start"], sp["end"])))
        for line in load_during(sp["start"], sp["end"]):
            print(f"      load: {line}")
    if len(spikes) > 25:
        print(f"  … {len(spikes) - 25} more in trace.json")
    print(f"\nOpen {os.path.join(d, 'trace.json')} in https://ui.perfetto.dev")


if __name__ == "__main__":
    main(sys.argv[1])
