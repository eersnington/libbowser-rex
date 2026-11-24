#!/bin/sh
# Trace the dev Rex's browser panes for SECS seconds, then explain every late
# frame. Use it while the stutter happens: scroll, play the video, switch
# Spaces. Needs run.sh server and run.sh client, and one open browser pane.
#
#   rex-client/perf-trace.sh [SECS]
#
# Four lanes on one clock (µs of mach time):
#   chrome.json   Chromium in every engine process: each frame from the
#                 page's main thread to the GPU process's hand-off to
#                 WindowServer (the engine's trace_start/trace_stop)
#   client.jsonl  Rex's main thread: each run loop turn of 4 ms or more, pane
#                 layouts, mounts and attaches (BOWSER_REX_PERF)
#   screen.jsonl  each frame WindowServer composited for each Rex window and,
#                 from its pixels, for each browser pane, while the window is
#                 on the current Space (framegaps stream)
#   load.jsonl    GPU busy per process and CPU, every 50 ms (sysmon)
# Writes rex-client/dev/perf/<time>/trace.json.gz, also for ui.perfetto.dev.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
dev="$here/dev"
rexdev="$dev/rexdev"
secs="${1:-10}"
out="$dev/perf/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"

block=$("$rexdev" ls --json | python3 -c '
import json, subprocess, sys
for s in json.load(sys.stdin)["sessions"]:
    r = subprocess.run([sys.argv[1], "block", "ls", "-s", s["session_id"], "--json"], capture_output=True, text=True)
    for b in json.loads(r.stdout or "{}").get("blocks", []):
        if b.get("creator_name") == "dev.libbowser":
            print(b["block_id"]); sys.exit()
' "$rexdev")
[ -n "$block" ] || { echo "open a browser pane first" >&2; exit 1; }

for tool in framegaps sysmon; do
  if [ ! -x "$dev/$tool" ] || [ "$here/$tool.swift" -nt "$dev/$tool" ]; then
    swiftc -O "$here/$tool.swift" -o "$dev/$tool" 2> /dev/null
  fi
done
engine=$("$rexdev" block call -b "$block" state | python3 -c 'import json,sys;print(json.load(sys.stdin)["engine_pid"])')
windows=$("$dev/framegaps" windows "$(cat "$dev/client.pid")")
# Pane names for the report: each browser block's page title.
python3 - "$rexdev" "$out/names.json" << 'EOF'
import json, subprocess, sys
rex, out = sys.argv[1], sys.argv[2]
run = lambda *a: json.loads(subprocess.run([rex, *a], capture_output=True, text=True).stdout or "{}")
names = {}
for s in run("ls", "--json").get("sessions", []):
    for b in run("block", "ls", "-s", s["session_id"], "--json").get("blocks", []):
        if b.get("creator_name") == "dev.libbowser":
            names[b["block_id"]] = run("block", "call", "-b", b["block_id"], "state").get("title") or b["block_id"][-6:]
json.dump(names, open(out, "w"))
EOF

"$rexdev" block call -b "$block" trace_start > "$out/clock.json"
start=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["mach_us"])' "$out/clock.json")
"$dev/sysmon" "$secs" "$out/load.jsonl" "$(cat "$dev/client.pid")" "$engine" &
load=$!
if [ -n "$windows" ]; then
  "$dev/framegaps" stream "$windows" "$dev/panes.json" > "$out/screen.jsonl" 2> /dev/null &
  gaps=$!
fi
echo "tracing for ${secs}s…"
perl -e "select(undef,undef,undef,$secs)"
"$rexdev" block call -b "$block" trace_stop "{\"path\":\"$out/chrome.json\"}" > /dev/null
if [ -n "${gaps:-}" ]; then kill "$gaps"; wait "$gaps"; fi 2> /dev/null || true
wait "$load" || true

# The client's lane: its names, and its events during the trace.
python3 - "$dev/perf.jsonl" "$out/client.jsonl" "$start" << 'EOF'
import json, sys
src, dst, start = sys.argv[1], sys.argv[2], float(sys.argv[3])
with open(src) as f, open(dst, "w") as o:
    for line in f:
        e = json.loads(line)
        if e.get("ph") == "M" or e.get("ts", 0) + e.get("dur", 0) >= start:
            o.write(line)
EOF

i=0
while [ ! -f "$out/chrome.json" ] && [ $i -lt 150 ]; do perl -e 'select(undef,undef,undef,0.2)'; i=$((i + 1)); done
[ -f "$out/chrome.json" ] || { echo "the engine wrote no trace" >&2; exit 1; }
rm -f "$out/clock.json"
python3 "$here/perf-capture.py" "$out"
"$here/perf-prune.sh"
python3 "$here/perf-report.py" "$out"
