#!/usr/bin/env python3
"""Explain the late frames in one capture from perf-trace.sh or perf-watch.

  perf-report.py CAPTURE_DIR

The capture holds trace.json.gz: Chromium's trace from every engine process,
merged with the Rex client's main thread (pid "Rex client"), what WindowServer
composited for the Rex window (when it was on screen), and GPU and CPU load.
All timestamps are µs of mach time. Open the same file in ui.perfetto.dev.

Prints, in order: a strip per lane (the worst frame in each time slot, so a
stutter lines up across lanes), each tab's frame stats, and each spike (a
burst of late or dropped frames) with a verdict, the pipeline stages that
took longer than usual, what was busy, what went silent, and the load.
"""
import bisect
import gzip
import json
import os
import statistics
import sys
from urllib.parse import urlparse

VSYNC = 16_667  # µs at 60 Hz
LATE = 1.5 * VSYNC  # a frame interval this long missed at least one vsync
BUSY = 4_000  # overlapping slices shorter than this are noise
STRIP = 72  # characters per strip
# Chromium's frame stages (PipelineReporter), in the words a reader needs.
STAGES = {
    "BeginImplFrameToSendBeginMainFrame": "the compositor waited to start the page's frame",
    "SendBeginMainFrameToCommit": "the page's main thread: script, style, layout, paint",
    "Commit": "handing the page's frame to the compositor",
    "EndCommitToActivation": "rasterizing tiles before the frame could show",
    "Activation": "activating the new frame",
    "EndActivateToSubmitCompositorFrame": "the compositor drawing the frame",
    "SubmitCompositorFrameToPresentationCompositorFrame": "from the page's frame to the screen",
    "ReceiveCompositorFrameToStartDraw": "the GPU process waited to draw: busy, or holding for its deadline",
    "StartDrawToSwapStart": "the GPU process drawing the frame",
    "SwapStartToSwapEnd": "the GPU process swapping the frame to Core Animation",
    "SwapStartToBufferAvailable": "waiting for a free buffer (the GPU still used the old ones)",
    "BufferAvailableToBufferReady": "the GPU finishing the frame",
    "BufferReadyToLatch": "waiting for the display to take the frame",
    "LatchToSwapEnd": "the swap after the display took the frame",
    "SwapEndToPresentationCompositorFrame": "waiting for WindowServer to put the frame on screen",
}
STATE_RANK = {"STATE_PRESENTED_ALL": 3, "STATE_PRESENTED_PARTIAL": 2, "STATE_DROPPED": 1}


def load(d):
    with gzip.open(os.path.join(d, "trace.json.gz"), "rt") as f:
        return json.load(f)["traceEvents"]


class Capture:
    def __init__(self, events):
        self.events = events
        self.pname = {e["pid"]: e["args"]["name"] for e in events if e.get("ph") == "M" and e["name"] == "process_name"}
        self.tname = {(e["pid"], e.get("tid")): e["args"]["name"] for e in events
                      if e.get("ph") == "M" and e["name"] == "thread_name"}
        timed = [e["ts"] for e in events if e.get("ph") != "M" and e.get("ts", 0) > 0]
        self.t0, self.t1 = min(timed), max(timed)
        self.slices = [e for e in events if e.get("ph") == "X" and e.get("dur", 0) >= BUSY and e.get("cat") != "window"]
        self.by_thread = {}
        for e in self.slices:
            self.by_thread.setdefault((e["pid"], e.get("tid")), []).append(e)
        self.counters = {}
        sampler = {p for p, n in self.pname.items() if n.startswith("Mac load")}
        for e in events:
            if e.get("ph") == "C" and e["pid"] in sampler:
                self.counters.setdefault(e["name"], []).append((e["ts"], e["args"]))
        self.urls = self.tab_urls()
        self.tabs = self.tab_frames()
        self.stamps, self.usual_gap = self.heartbeats()

    # ---- who is who ----------------------------------------------------

    def tab_urls(self):
        # CEF's trace has no page-to-process record, but script slices carry
        # their script's URL: name each renderer after its most common one.
        seen = {}
        for e in self.events:
            data = e.get("args", {}).get("data") if isinstance(e.get("args"), dict) else None
            if isinstance(data, dict) and isinstance(data.get("url"), str) and data["url"]:
                per = seen.setdefault(e["pid"], {})
                per[data["url"]] = per.get(data["url"], 0) + 1
        return {pid: max(c, key=c.get) for pid, c in seen.items()}

    def tab_name(self, pid):
        url = self.urls.get(pid, "")
        if url.startswith("data:"):
            return "data: page"
        if url.startswith("file:"):
            return os.path.basename(urlparse(url).path) or url
        return urlparse(url).netloc or url or f"renderer {pid}"

    def where(self, e):
        return f"{self.pname.get(e['pid'], e['pid'])} / {self.tname.get((e['pid'], e.get('tid')), e.get('tid'))}"

    def at(self, ts):
        return f"{(ts - self.t0) / 1e6:6.2f}s"

    # ---- frames ----------------------------------------------------------

    def tab_frames(self):
        """Per renderer: one record per frame, with its stages."""
        open_, frames = {}, {}
        for e in self.events:
            if e.get("ph") not in ("b", "e") or "id2" not in e and "id" not in e:
                continue
            key = (e["pid"], json.dumps(e.get("id2") or e.get("id")))
            if e["name"] == "PipelineReporter":
                if e["ph"] == "b":
                    open_[key] = {"fr": e["args"].get("frame_reporter", {}), "start": e["ts"], "stages": {}, "open": {}}
                elif key in open_:
                    r = open_.pop(key)
                    r["end"] = e["ts"]
                    fr = r["fr"]
                    seq = (fr.get("layer_tree_host_id"), fr.get("frame_sequence"))
                    tab = frames.setdefault(e["pid"], {})
                    old = tab.get(seq)
                    if not old or (STATE_RANK.get(fr.get("state"), 0), r["end"]) > (STATE_RANK.get(old["fr"].get("state"), 0), old["end"]):
                        tab[seq] = r
            elif key in open_:
                r = open_[key]
                if e["ph"] == "b":
                    r["open"][e["name"]] = e["ts"]
                elif e["name"] in r["open"]:
                    r["stages"][e["name"]] = r["stages"].get(e["name"], 0) + e["ts"] - r["open"].pop(e["name"])
        out = {}
        for pid, tab in frames.items():
            fr = sorted(tab.values(), key=lambda r: r["end"])
            shown = [r for r in fr if r["fr"].get("state", "").startswith("STATE_PRESENTED")]
            for prev, r in zip(shown, shown[1:]):
                f = r["fr"]
                if f.get("has_main_animation") or f.get("has_compositor_animation") or f.get("scroll_state") not in (None, "SCROLL_NONE"):
                    r["interval"] = r["end"] - prev["end"]
            typical = {}
            for r in fr:
                for s, d in r["stages"].items():
                    typical.setdefault(s, []).append(d)
            out[pid] = {"frames": fr, "typical": {s: statistics.median(v) for s, v in typical.items()}}
        return out

    def heartbeats(self):
        per = {}
        for e in self.events:
            if e.get("ph") not in ("M", "C") and e.get("ts", 0) > 0 and e.get("cat") not in ("rex", "window"):
                per.setdefault(e["pid"], []).append(e["ts"])
        span = self.t1 - self.t0
        stamps = {p: sorted(t) for p, t in per.items() if len(t) > span / VSYNC}
        usual = {}
        for p, t in stamps.items():
            g = sorted(b - a for a, b in zip(t, t[1:]))
            usual[p] = g[int(len(g) * 0.99)]
        return stamps, usual

    # ---- what happened during [start, end] ------------------------------

    def chain(self, top):
        names, cur = [top["name"]], top
        inner = self.by_thread[(top["pid"], top.get("tid"))]
        while len(names) < 9:
            kids = [e for e in inner if e is not cur and e["ts"] >= cur["ts"] and e["ts"] + e["dur"] <= cur["ts"] + cur["dur"]
                    and e["dur"] >= cur["dur"] * 0.5 and (e["dur"] < cur["dur"] or e["ts"] > cur["ts"])]
            if not kids:
                break
            cur = max(kids, key=lambda e: e["dur"])
            data = cur.get("args", {}).get("data", {}) if isinstance(cur.get("args"), dict) else {}
            extra = (data.get("functionName") or data.get("url") or "") if isinstance(data, dict) else ""
            names.append(cur["name"] + (f" ({extra[:60]})" if extra else ""))
        return " > ".join(names if len(names) <= 4 else [names[0], "…"] + names[-3:])

    def busy(self, start, end):
        hits = sorted((e for e in self.slices if e["ts"] < end and e["ts"] + e["dur"] > start), key=lambda e: (-e["dur"], e["ts"]))
        out, seen = [], set()
        for e in hits:
            k = (e["pid"], e.get("tid"))
            if k not in seen:
                seen.add(k)
                out.append(e)
        return out[:5]

    def silent(self, start, end):
        out = []
        for pid, ts in self.stamps.items():
            i, j = bisect.bisect_left(ts, start), bisect.bisect_right(ts, end)
            w = ts[max(i - 1, 0):j + 1]
            gap = max((b - a for a, b in zip(w, w[1:])), default=0)
            if gap >= max(LATE, 4 * self.usual_gap[pid]):
                out.append((pid, gap))
        return out

    def load(self, start, end):
        out = {}
        for name, samples in self.counters.items():
            hit = [a for (ts, a), (nxt, _) in zip(samples, samples[1:] + [(float("inf"), None)]) if ts < end and nxt > start]
            if hit:
                out[name] = {k: sum(a[k] for a in hit) / len(hit) for k in hit[0]}
        return out

    # ---- spikes -----------------------------------------------------------

    def late_frames(self):
        late = []
        for pid, tab in self.tabs.items():
            for r in tab["frames"]:
                if r["fr"].get("state") == "STATE_DROPPED":
                    late.append(("tab", pid, r["start"], r["end"], r, "dropped"))
                elif r.get("interval", 0) > LATE:
                    late.append(("tab", pid, r["end"] - r["interval"], r["end"], r, "late"))
        for e in self.events:
            if e.get("cat") == "window" and e.get("ph") == "X" and e["dur"] > LATE:
                late.append(("window", None, e["ts"], e["ts"] + e["dur"], None, "late"))
        return sorted(late, key=lambda x: x[2])

    def spikes(self):
        out = []
        for lane, pid, start, end, r, kind in self.late_frames():
            if out and start <= out[-1]["end"] + 2 * VSYNC:
                sp = out[-1]
                sp["end"] = max(sp["end"], end)
            else:
                sp = {"start": start, "end": end, "frames": []}
                out.append(sp)
            sp["frames"].append((lane, pid, r, kind))
        return out

    def stage_cause(self, sp):
        """The innermost stage that grew the most, as a cause."""
        grown = self.grown_stages(sp)
        inner = [g for g in grown if g[0][1] != "SubmitCompositorFrameToPresentationCompositorFrame"]
        if not (inner or grown):
            return None
        (pid, s), (extra, took, typ) = (inner or grown)[0]
        return f"{STAGES.get(s, s)}: {took / 1000:.0f} ms, usually {typ / 1000:.0f}"

    def grown_stages(self, sp):
        """Stages of the spike's frames that took longer than the tab's usual."""
        grown = {}
        for lane, pid, r, _ in sp["frames"]:
            if not r:
                continue
            typical = self.tabs[pid]["typical"]
            for s, d in r["stages"].items():
                extra = d - typical.get(s, 0)
                if extra > 8_000 and extra > grown.get((pid, s), (0, 0))[0]:
                    grown[(pid, s)] = (extra, d, typical.get(s, 0))
        return sorted(grown.items(), key=lambda kv: -kv[1][0])[:4]

    def verdict(self, sp, busy, silent, load):
        lanes = {f[0] for f in sp["frames"]}
        gpu = load.get("GPU busy %", {})
        cpu = load.get("CPU %", {})
        if silent:
            pid, gap = max(silent, key=lambda s: s[1])
            mac = cpu.get("whole Mac, % of all cores", 0)
            why = "the Mac's CPUs were saturated" if mac > 85 else "stopped, or blocked in the kernel"
            return f"{self.pname.get(pid, pid)} went silent for {gap / 1000:.0f} ms ({why})"
        if gpu and sum(gpu.values()) > 90:
            top = max(gpu.items(), key=lambda kv: kv[1])
            return f"GPU saturated ({sum(gpu.values()):.0f}%, most from {top[0]})"
        if lanes == {"window"}:
            rex = [e for e in busy if self.pname.get(e["pid"]) == "Rex client"]
            if rex:
                return f"after Chromium: Rex's main thread was busy {rex[0]['dur'] / 1000:.0f} ms"
            return "after Chromium: the page presented on time, but the Rex window didn't update (WindowServer or Rex)"
        stage = self.stage_cause(sp)
        if stage and (not busy or busy[0]["dur"] < 0.5 * (sp["end"] - sp["start"])):
            return stage
        if busy:
            e = busy[0]
            who = self.where(e)
            if "Renderer" in who and "CrRendererMain" in who:
                return f"the page's main thread ({self.chain(e).split(' > ')[-1]}) ran {e['dur'] / 1000:.0f} ms"
            if "GPU Process" in who:
                return f"Chromium's GPU process was busy {e['dur'] / 1000:.0f} ms ({self.chain(e).split(' > ')[-1]})"
            return f"{who} was busy {e['dur'] / 1000:.0f} ms"
        return "no single cause in the trace: several small costs added up, or the wait was outside these processes"

    # ---- strips ------------------------------------------------------------

    def strip(self, points):
        """points: (ts, value_ms). The worst value in each slot as a block."""
        slots = [0.0] * STRIP
        width = (self.t1 - self.t0) / STRIP or 1
        for ts, v in points:
            i = min(STRIP - 1, max(0, int((ts - self.t0) / width)))
            slots[i] = max(slots[i], v)
        blocks = " ▁▂▃▄▅▆▇█"
        def block(v):
            if v <= 0:
                return " "
            if v <= 18:
                return "▁"
            return blocks[min(8, 2 + int((v - 18) / 12))]
        return "".join(block(v) for v in slots)

    def counter_strip(self, name, key=None):
        pts = []
        for ts, a in self.counters.get(name, []):
            v = sum(a.values()) if key is None else a.get(key, 0)
            pts.append((ts, 18 + v * 0.82))  # 0..100% onto the same blocks
        return self.strip(pts)


def main(d):
    c = Capture(load(d))
    span = (c.t1 - c.t0) / 1e6
    window_frames = [(e["ts"] + e["dur"], e["dur"] / 1000) for e in c.events if e.get("cat") == "window" and e.get("ph") == "X"]
    print(f"Capture {os.path.basename(d.rstrip('/'))}: {span:.1f} s, {len(c.tabs)} tab(s), "
          f"Rex window {'on screen' if window_frames else 'off screen (no WindowServer lane)'}")
    print(f"\nWorst frame per {span / STRIP * 1000:.0f} ms   ▁ on time   ▃ 1 missed   ▅ 2–3 missed   █ ≥100 ms")
    for pid, tab in c.tabs.items():
        pts = [(r["end"], r.get("interval", 0) / 1000) for r in tab["frames"]]
        pts += [(r["end"], 100) for r in tab["frames"] if r["fr"].get("state") == "STATE_DROPPED"]
        print(f"  {c.tab_name(pid)[:22]:22s} │{c.strip(pts)}│")
    if window_frames:
        print(f"  {'Rex window on screen':22s} │{c.strip(window_frames)}│")
    rex = [(e["ts"] + e["dur"], e["dur"] / 1000) for e in c.events if e.get("cat") == "rex" and e.get("ph") == "X"]
    print(f"  {'Rex main thread busy':22s} │{c.strip(rex)}│")
    if "GPU busy %" in c.counters:
        print(f"  {'GPU busy (all)':22s} │{c.counter_strip('GPU busy %')}│  0–100%")
        print(f"  {'CPU (whole Mac)':22s} │{c.counter_strip('CPU %', 'whole Mac, % of all cores')}│  0–100%")
    ticks = "".join("┬" if i % 12 == 0 else "─" for i in range(STRIP))
    print(f"  {'':22s} └{ticks}┘")
    print(f"  {'':22s}  " + "".join(f"{span * i / STRIP:<12.1f}"[:12] for i in range(0, STRIP, 12)) + "s")

    print("\nTabs")
    for pid, tab in c.tabs.items():
        fr = tab["frames"]
        dropped = sum(r["fr"].get("state") == "STATE_DROPPED" for r in fr)
        iv = sorted(r["interval"] for r in fr if "interval" in r)
        line = f"  {c.tab_name(pid)}: {len(fr)} frames, {dropped} dropped"
        if iv:
            worst = iv[int(len(iv) * 0.99):]
            line += (f", while animating p50 {iv[len(iv) // 2] / 1000:.1f} ms, p99 {iv[int(len(iv) * 0.99)] / 1000:.1f} ms, "
                     f"1% low {1e6 / statistics.mean(worst):.0f} fps, {sum(i > LATE for i in iv)} late")
        print(line)

    spikes = c.spikes()
    print(f"\nSpikes: {len(spikes)}")
    for n, sp in enumerate(spikes[:15], 1):
        busy, silent, load_ = c.busy(sp["start"], sp["end"]), c.silent(sp["start"], sp["end"]), c.load(sp["start"], sp["end"])
        what = {}
        for lane, pid, _, kind in sp["frames"]:
            k = f"{kind} in {'the Rex window' if lane == 'window' else c.tab_name(pid)}"
            what[k] = what.get(k, 0) + 1
        print(f"\n  #{n} at {c.at(sp['start'])}, {(sp['end'] - sp['start']) / 1000:.0f} ms: "
              + ", ".join(f"{v} {k}" for k, v in what.items()))
        print(f"     ⇒ {c.verdict(sp, busy, silent, load_)}")
        for (pid, s), (extra, took, typ) in c.grown_stages(sp):
            print(f"     stage {s}: {took / 1000:.1f} ms, usually {typ / 1000:.1f}: {STAGES.get(s, '')}")
        for e in busy:
            print(f"     busy {e['dur'] / 1000:5.1f} ms  {c.where(e)}: {c.chain(e)}")
        for pid, gap in silent:
            print(f"     silent {gap / 1000:5.1f} ms  {c.pname.get(pid, pid)}")
        for name, vals in load_.items():
            print(f"     {name}: " + ", ".join(f"{k} {v:.0f}" for k, v in sorted(vals.items(), key=lambda kv: -kv[1]) if v >= 1))
    if len(spikes) > 15:
        print(f"\n  … {len(spikes) - 15} more; open the trace in ui.perfetto.dev")
    print(f"\nTimeline: {os.path.join(d, 'trace.json.gz')} → https://ui.perfetto.dev")


if __name__ == "__main__":
    main(sys.argv[1])
