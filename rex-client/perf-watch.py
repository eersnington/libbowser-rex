#!/usr/bin/env python3
"""Watch the dev Rex for stutter, and save the seconds around each one.

  rex-client/perf-watch.py [--gap MS]

Leave it running while you use browser panes. It saves a capture when a
browser pane, or a Rex window, that was animating steadily on screen shows a
frame MS late or more (default 50, about 3 missed frames) and then animates
on, or when you press ⌃⌥⌘J in the dev Rex. A pause (nothing moving) is not a
stutter. Each capture is
dev/perf/<time>/ with trace.json.gz (ui.perfetto.dev) and report.txt, and it
prints one line with the verdict. Captures over 200 MB in total
(PERF_KEEP_MB) are deleted oldest first. Ctrl-C stops it.

What runs meanwhile: Chromium's trace in the engine (restarted every 20 s, so
its buffer never fills), framegaps (frame times of each Rex window), sysmon
(GPU and CPU load), and the Rex client's own lane (dev/perf.jsonl).
"""
import argparse
import collections
import importlib.util
import io
import json
import os
import signal
import subprocess
import sys
import threading
import time
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.join(HERE, "dev")
REXDEV = os.path.join(DEV, "rexdev")
KEEP_US = 40e6  # how much of each lane stays in memory
ROTATE_S = 20  # Chromium's buffer stops recording when full; restart before
BEFORE_US, AFTER_US = 6e6, 1.5e6  # what a capture keeps around its trigger
COOLDOWN_S = 15
SETTLE_US = 1e6  # a window just shown warms up; don't call that a stutter

spec = importlib.util.spec_from_file_location("perf_report", os.path.join(HERE, "perf-report.py"))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


def mach_us():
    return time.clock_gettime_ns(time.CLOCK_UPTIME_RAW) / 1000


def rex(*args):
    r = subprocess.run([REXDEV, *args], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr.strip() or r.stdout.strip())
    return json.loads(r.stdout) if r.stdout.strip() not in ("", "null") else {}


def browser_block():
    for s in rex("ls", "--json")["sessions"]:
        for b in rex("block", "ls", "-s", s["session_id"], "--json").get("blocks", []):
            if b.get("creator_name") == "dev.libbowser":
                return b["block_id"]
    return None


class Lane:
    """The last KEEP_US of a stream of JSON lines."""

    def __init__(self):
        self.items = collections.deque()
        self.lock = threading.Lock()

    def add(self, ts, item):
        with self.lock:
            self.items.append((ts, item))
            while self.items and self.items[0][0] < ts - KEEP_US:
                self.items.popleft()

    def between(self, lo, hi):
        with self.lock:
            return [i for t, i in self.items if lo <= t <= hi]


class Watch:
    def __init__(self, gap_ms):
        self.gap_us = gap_ms * 1000
        self.frames, self.load, self.client = Lane(), Lane(), Lane()
        self.client_meta = []
        self.names = {}
        self.trigger = None  # (ts, why)
        self.cond = threading.Condition()
        self.block = None
        self.captures = 0
        self.procs = []

    # ---- lanes --------------------------------------------------------------

    def spawn(self, *cmd):
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.procs.append(p)
        return p

    def read_frames(self, p):
        # Per window and per pane: the last frame times. Interval k is a
        # stutter when it is long, the three before it were steady, and the
        # one after it is steady again (report.animating, applied live).
        times, shown = {}, {}
        for line in p.stdout:
            e = json.loads(line)
            w = e["w"]
            self.frames.add(e["ts"], e)
            if "on" in e:
                shown[w] = e["ts"] if e["on"] else None
                for k in [k for k in times if k[0] == w]:
                    del times[k]
                print(f"{time.strftime('%H:%M:%S')}  window {w} {'on screen' if e['on'] else 'off screen'}", flush=True)
                continue
            key = (w, e.get("p"))
            t = times.setdefault(key, collections.deque(maxlen=6))
            t.append(e["ts"])
            if len(t) < 6 or not shown.get(w) or t[0] - shown[w] < SETTLE_US:
                continue
            d = [b - a for a, b in zip(t, list(t)[1:])]  # 5 intervals; the 4th is the candidate
            if d[3] >= self.gap_us and all(x < report.STEADY for x in d[:3]) and d[4] < report.STEADY:
                what = f"pane {self.names.get(e['p'], e['p'][-6:])}" if e.get("p") else f"window {w}"
                self.fire(t[3], f"{what} froze {d[3] / 1000:.0f} ms")

    def read_load(self, p):
        for line in p.stdout:
            e = json.loads(line)
            if e.get("ph") == "M":
                self.load_meta = e
            else:
                self.load.add(e["ts"], e)

    def read_client(self):
        path = os.path.join(DEV, "perf.jsonl")
        f, inode = None, None
        while True:
            try:
                st = os.stat(path)
                if f is None or st.st_ino != inode or st.st_size < f.tell():
                    f = open(path)  # new client, or the log started over
                    inode = st.st_ino
                    self.client_meta = []
                line = f.readline()
            except FileNotFoundError:
                line = ""
            if not line:
                time.sleep(0.05)
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("ph") == "M":
                self.client_meta.append(e)
                continue
            self.client.add(e.get("ts", 0), e)
            if e.get("name") == "stutter marked":
                self.fire(e["ts"], "you pressed ⌃⌥⌘J")

    # ---- trace --------------------------------------------------------------

    def call(self, method, args=None):
        for _ in range(2):
            try:
                if not self.block:
                    self.block = browser_block()
                if not self.block:
                    raise RuntimeError("no browser pane is open")
                return rex("block", "call", "-b", self.block, method, *([json.dumps(args)] if args else []))
            except RuntimeError:
                self.block = None
        raise RuntimeError(f"{method}: no browser pane answered")

    def refresh_names(self):
        """Pane names for the report and the trigger line: each page's title."""
        names = {}
        try:
            for s in rex("ls", "--json")["sessions"]:
                for b in rex("block", "ls", "-s", s["session_id"], "--json").get("blocks", []):
                    if b.get("creator_name") == "dev.libbowser":
                        names[b["block_id"]] = rex("block", "call", "-b", b["block_id"], "state").get("title") or b["block_id"][-6:]
        except RuntimeError:
            return
        self.names = names

    def start_trace(self):
        for _ in range(50):
            try:
                self.call("trace_start")
                return True
            except RuntimeError:
                time.sleep(0.1)  # the last stop is still finishing
        return False

    # ---- triggers -----------------------------------------------------------

    def fire(self, ts, why):
        with self.cond:
            if self.trigger is None:
                self.trigger = (ts, why)
                self.cond.notify()

    def run(self):
        clients = open(os.path.join(DEV, "client.pid")).read().strip()
        windows = subprocess.run([os.path.join(DEV, "framegaps"), "windows", clients], capture_output=True, text=True).stdout.strip()
        self.block = browser_block()
        if not self.block:
            sys.exit("open a browser pane in the dev Rex first")
        engine = str(self.call("state")["engine_pid"])
        self.refresh_names()
        self.load_meta = None
        threading.Thread(target=self.read_frames, args=(self.spawn(os.path.join(DEV, "framegaps"), "stream", windows,
                                                                   os.path.join(DEV, "panes.json")),), daemon=True).start()
        threading.Thread(target=self.read_load, args=(self.spawn(os.path.join(DEV, "sysmon"), "0", "-", clients, engine),), daemon=True).start()
        threading.Thread(target=self.read_client, daemon=True).start()
        if not self.start_trace():
            sys.exit("the engine would not start tracing")
        started = time.monotonic()
        print(f"watching windows {windows}: a frame ≥{self.gap_us / 1000:.0f} ms on screen, or ⌃⌥⌘J, saves a capture",
              flush=True)
        last_capture = 0
        while True:
            with self.cond:
                self.cond.wait(timeout=1)
                trig, self.trigger = self.trigger, None
            if trig and time.monotonic() - last_capture > COOLDOWN_S:
                self.capture(*trig)
                last_capture = time.monotonic()
                started = time.monotonic()
            elif time.monotonic() - started > ROTATE_S:
                self.refresh_names()
                try:
                    self.call("trace_stop")
                except RuntimeError:
                    pass
                self.start_trace()
                started = time.monotonic()

    def capture(self, ts, why):
        time.sleep(max(0, (ts + AFTER_US - mach_us()) / 1e6))
        name = time.strftime("%Y%m%d-%H%M%S")
        d = os.path.join(DEV, "perf", name)
        os.makedirs(d, exist_ok=True)
        lo, hi = ts - BEFORE_US, ts + AFTER_US
        try:
            self.call("trace_stop", {"path": os.path.join(d, "chrome.json")})
        except RuntimeError as e:
            print(f"{time.strftime('%H:%M:%S')}  {why}: no trace ({e})", flush=True)
            self.start_trace()
            return
        with open(os.path.join(d, "screen.jsonl"), "w") as f:
            for e in self.frames.between(lo - 1e6, hi):
                f.write(json.dumps(e) + "\n")
        with open(os.path.join(d, "names.json"), "w") as f:
            json.dump(self.names, f)
        with open(os.path.join(d, "load.jsonl"), "w") as f:
            for e in ([self.load_meta] if self.load_meta else []) + self.load.between(lo - 1e6, hi):
                f.write(json.dumps(e) + "\n")
        with open(os.path.join(d, "client.jsonl"), "w") as f:
            for e in self.client_meta + self.client.between(lo - 2e6, hi):
                f.write(json.dumps(e) + "\n")
            f.write(json.dumps({"name": "trigger: " + why, "cat": "rex", "ph": "i", "s": "g", "pid": 1, "tid": 0, "ts": ts}) + "\n")
        for _ in range(300):
            if os.path.exists(os.path.join(d, "chrome.json")):
                break
            time.sleep(0.1)
        self.start_trace()  # the next capture's history starts now
        if not os.path.exists(os.path.join(d, "chrome.json")):
            print(f"{time.strftime('%H:%M:%S')}  {why}: the engine wrote no trace", flush=True)
            return
        subprocess.run([sys.executable, os.path.join(HERE, "perf-capture.py"), d, str(lo), str(hi)], check=True)
        subprocess.run([os.path.join(HERE, "perf-prune.sh")], check=True)
        out = io.StringIO()
        with redirect_stdout(out):
            report.main(d)
        with open(os.path.join(d, "report.txt"), "w") as f:
            f.write(f"Trigger: {why}\n\n" + out.getvalue())
        c = report.Capture(report.load(d))
        near = [sp for sp in c.spikes() if sp["start"] - 2 * report.VSYNC <= ts <= sp["end"] + 2 * report.VSYNC]
        verdict = c.verdict(near[0], c.busy(near[0]["start"], near[0]["end"]), c.silent(near[0]["start"], near[0]["end"]),
                            c.load(near[0]["start"], near[0]["end"])) if near else "no late frame in the trace around it"
        self.captures += 1
        print(f"{time.strftime('%H:%M:%S')}  {why} ⇒ {verdict}\n          {os.path.join(d, 'report.txt')}", flush=True)

    def stop(self):
        for p in self.procs:
            p.kill()
        try:
            self.call("trace_stop")
        except RuntimeError:
            pass


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gap", type=float, default=50, help="a window frame this many ms or longer is a stutter")
    w = Watch(ap.parse_args().gap)
    try:
        w.run()
    except KeyboardInterrupt:
        pass
    finally:
        w.stop()
