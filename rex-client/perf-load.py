#!/usr/bin/env python3
"""Load-test browser panes in the dev Rex, one scenario at a time.

  rex-client/perf-load.py [--secs N] [--only NAME,…] [--keep]

Runs in the dev Rex session labeled "loadtest" (dev/restore.sh makes it, in
its own window). Each scenario opens its panes, lets them settle, records a
perf-trace.sh capture, and reduces it to one row: frames per animating tab,
late frames, 1% low, spikes and their causes, GPU and CPU. Captures are
deleted unless --keep. No keys are sent: pages animate and scroll themselves,
so nothing can type into another window.

Two scenarios plant a known cause and check that the report names it, so a
broken tool fails here instead of misleading.
"""
import argparse
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from urllib.parse import quote

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.join(HERE, "dev")
REXDEV = os.path.join(DEV, "rexdev")
spec = importlib.util.spec_from_file_location("perf_report", os.path.join(HERE, "perf-report.py"))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


def page(title, body):
    return "data:text/html," + quote(f"<title>{title}</title><body style='margin:0'>{body}</body>")


ANIM = page("anim", "<div id=b style='width:80px;height:80px;background:#8c4;will-change:transform'></div>"
            "<script>function f(t){b.style.transform='translate('+(t/3%600)+'px,'+(t/7%300)+'px)';"
            "requestAnimationFrame(f)}requestAnimationFrame(f)</script>")
CANVAS = page("canvas", "<canvas id=c style='width:100vw;height:100vh'></canvas><script>"
              "const g=c.getContext('2d');function f(t){c.width=innerWidth*devicePixelRatio;c.height=innerHeight*devicePixelRatio;"
              "for(let i=0;i<3000;i++){g.fillStyle='hsl('+(i*7+t/9)%360+' 70% 60%)';"
              "g.fillRect((i*37+t/4)%c.width,(i*53+t/9)%c.height,30,30)}requestAnimationFrame(f)}requestAnimationFrame(f)</script>")
SCROLL = page("scroll", "<div id=d></div><script>"
              "d.innerHTML=Array.from({length:400},(_,i)=>'<p style=\"font:16px system-ui;padding:8px\">Paragraph '+i+' '"
              "+'lorem ipsum dolor sit amet '.repeat(12)+'</p><div style=\"height:60px;background:hsl('+i*9%360+' 60% 80%)\"></div>').join('');"
              "let down=true;setInterval(()=>{scrollTo({top:down?document.body.scrollHeight:0,behavior:'smooth'});down=!down},2500)</script>")
JANK = page("jank", "<div id=b style='width:80px;height:80px;background:#c84;will-change:transform'></div><script>"
            "function f(t){b.style.transform='translateX('+(t/3%600)+'px)';requestAnimationFrame(f)}requestAnimationFrame(f);"
            "setInterval(function plantedJank(){const e=performance.now()+120;while(performance.now()<e);},2000)</script>")


def rex(*args):
    r = subprocess.run([REXDEV, *args], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr.strip())
    return json.loads(r.stdout) if r.stdout.strip() not in ("", "null") else {}


class Session:
    def __init__(self):
        found = [s for s in rex("ls", "--json")["sessions"] if s.get("label") == "loadtest"]
        if not found:
            sys.exit("no dev Rex session labeled loadtest: run rex-client/dev/restore.sh")
        self.sid = found[0]["session_id"]
        self.mode = None  # the engine's default: windowed on calayerhost

    def blocks(self):
        return [b["block_id"] for b in rex("block", "ls", "-s", self.sid, "--json").get("blocks", [])]

    def show(self, urls, mode=None):
        """Exactly these pages, one pane each, in this engine mode."""
        blocks = self.blocks()
        if mode != self.mode:
            # The mode is fixed when a pane opens: open new ones, close the old.
            fresh = []
            for u in urls:
                out = rex("api", "call", "session.new_split", json.dumps({
                    "session_id": self.sid, "anchor_id": (fresh or blocks)[-1], "direction": "horizontal",
                    "side": "after", "focus": False,
                    "layout": {"block": {"flavor": "dev.libbowser.browser", "options": {"url": u, **({"mode": mode} if mode else {})}}}}))
                fresh.append(out["block_ids"][0])
            for b in blocks:
                rex("block", "close", b)
            self.mode = mode
            return fresh
        while len(blocks) < len(urls):
            out = rex("do", "browser", "-s", self.sid, "-b", blocks[-1], "url=about:blank")
            blocks.append(out["block_ids"][0])
        for b in blocks[len(urls):]:
            rex("block", "close", b)
        blocks = blocks[:len(urls)]
        for b, u in zip(blocks, urls):
            rex("block", "call", "-b", b, "navigate", json.dumps({"url": u}))
        return blocks


def run_capture(secs, during=None):
    p = subprocess.Popen([os.path.join(HERE, "perf-trace.sh"), str(secs)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if during:
        during()
    out = p.communicate()[0]
    m = re.search(r"Timeline: (\S+)/trace\.json\.gz", out)
    if not m:
        raise RuntimeError("perf-trace.sh: " + out[-400:])
    return m.group(1)


def summarize(d):
    c = report.Capture(report.load(d))
    rows = []
    for pid, tab in c.tabs.items():
        iv = sorted(r["interval"] for r in tab["frames"] if "interval" in r)
        if len(iv) < 20:
            continue  # not animating
        worst = iv[int(len(iv) * 0.99):]
        rows.append({"tab": c.tab_name(pid), "fps": len(iv) / (sum(iv) / 1e6),
                     "p99": iv[int(len(iv) * 0.99)] / 1000, "low": 1e6 / (sum(worst) / len(worst)),
                     "late": sum(i > report.LATE for i in iv),
                     "dropped": sum(r["fr"].get("state") == "STATE_DROPPED" for r in tab["frames"])})
    verdicts = {}
    for sp in c.spikes():
        v = c.verdict(sp, c.busy(sp["start"], sp["end"]), c.silent(sp["start"], sp["end"]), c.load(sp["start"], sp["end"]))
        v = re.sub(r"\d+ ms", "N ms", v)
        verdicts[v] = verdicts.get(v, 0) + 1
    load = c.load(c.t0, c.t1)
    wf = sorted(e["dur"] for e in c.events if e.get("cat") == "window" and e.get("ph") == "X")
    window = None
    if len(wf) > 20:
        worst = wf[int(len(wf) * 0.99):]
        window = {"low": 1e6 / (sum(worst) / len(worst)), "late": sum(d > report.LATE for d in wf)}
    return rows, verdicts, load, window, len(c.spikes())


def stop_gpu(ms):
    def go():
        time.sleep(3)
        gpu = subprocess.run(["pgrep", "-f", "bowser-cef.*--type=gpu-process"], capture_output=True, text=True).stdout.split()
        if gpu:
            os.kill(int(gpu[0]), signal.SIGSTOP)
            time.sleep(ms / 1000)
            os.kill(int(gpu[0]), signal.SIGCONT)
    return go


def churn(sess, base, secs):
    # Open and close a pane next to the animating one, once a second.
    def go():
        end = time.time() + secs
        while time.time() < end:
            b = rex("do", "browser", "-s", sess.sid, "-b", base, "url=about:blank")["block_ids"][0]
            time.sleep(0.5)
            rex("block", "close", b)
            time.sleep(0.5)
    return go


SCENARIOS = [
    # name, pages, what runs during the capture, check on the verdicts
    ("1 pane, light", [ANIM], None, None),
    ("4 panes, light", [ANIM] * 4, None, None),
    ("8 panes, light", [ANIM] * 8, None, None),
    ("1 pane, heavy canvas", [CANVAS], None, None),
    ("4 panes, heavy canvas", [CANVAS] * 4, None, None),
    ("4 panes, light, OSR", [ANIM] * 4, None, None, "osr"),
    ("4 panes, heavy canvas, OSR", [CANVAS] * 4, None, None, "osr"),
    ("smooth scrolling", [SCROLL], None, None),
    ("pane open/close beside", [ANIM], "churn", None),
    ("check: planted page jank", [JANK], None, lambda v: any("plantedJank" in k for k in v)),
    ("check: GPU process stopped", [ANIM], "gpu", lambda v: any("GPU Process went silent" in k for k in v)),
]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--secs", type=int, default=10)
    ap.add_argument("--only", default="", help="scenario names, separated by ;")
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    sess = Session()
    failed = False
    print(f"{'scenario':28s} {'tab':12s} {'fps':>5s} {'p99':>6s} {'1%low':>6s} {'late':>5s} {'drop':>5s}  {'GPU%':>5s} {'CPU%':>5s}  window")
    for name, urls, during, check, *mode in SCENARIOS:
        if a.only and name not in [o.strip() for o in a.only.split(";")]:
            continue
        blocks = sess.show(urls, mode[0] if mode else None)
        time.sleep(4)
        act = {"churn": churn(sess, blocks[0], a.secs - 1), "gpu": stop_gpu(150)}.get(during)
        d = run_capture(a.secs, act)
        rows, verdicts, load, window, spikes = summarize(d)
        gpu = sum(load.get("GPU busy %", {}).values())
        cpu = load.get("CPU %", {}).get("whole Mac, % of all cores", 0)
        if not rows:
            rows = [{"tab": "(none animating)", "fps": 0, "p99": 0, "low": 0, "late": 0, "dropped": 0}]
        worst = min(rows, key=lambda r: r["low"])
        print(f"{name:28s} {worst['tab'][:12]:12s} {worst['fps']:5.1f} {worst['p99']:6.1f} {worst['low']:6.0f} "
              f"{sum(r['late'] for r in rows):5d} {sum(r['dropped'] for r in rows):5d}  {gpu:5.0f} {cpu:5.0f}  "
              + (f"1% low {window['low']:.0f}, {window['late']} late" if window else "off screen"))
        for v, n in sorted(verdicts.items(), key=lambda kv: -kv[1])[:3]:
            print(f"{'':28s}   {n}× {v}")
        if check:
            ok = check(verdicts)
            failed |= not ok
            print(f"{'':28s}   {'ok' if ok else 'FAIL'}: the report names the planted cause")
        if not a.keep:
            shutil.rmtree(d, ignore_errors=True)
    sess.show([ANIM], None)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
