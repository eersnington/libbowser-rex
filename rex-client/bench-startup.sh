#!/bin/sh
# Opens N browser panes in the dev Rex and prints p50/p90 per stage, in ms.
# Needs the dev Rex, with engine logs: BOWSER_LOG=1 run.sh server; run.sh client.
cd "$(dirname "$0")"
N=${1:-20}
S=$(./dev/rexdev api call session.list '{}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["sessions"][0]["session_id"])')
out=dev/startup-runs.txt; : > "$out"
for i in $(seq 1 "$N"); do
  : > dev/trace.log; n=$(wc -l < dev/logs/plugin.log)
  t0=$(python3 -c 'import time;print("%.6f"%time.time())')
  R=$(./dev/rexdev do browser -s "$S" "url=data:text/html,<title>t$i</title>hi")
  sleep 1.2
  python3 - "$t0" "$n" "$R" >> "$out" <<'PY'
import sys,re,json
t0,n=float(sys.argv[1]),int(sys.argv[2]); blk=json.loads(sys.argv[3])["block_ids"][0]
open_t=ctx=None; sid=None
for i,l in enumerate(open('dev/logs/plugin.log')):
    if i<n: continue
    m=re.match(r'(\d+\.\d+) bowser-cef: (.*)',l)
    if not m: continue
    t,s=float(m.group(1)),m.group(2)
    if s.startswith('open ') and open_t is None: open_t=t
    m2=re.match(r'(\d+): chromium page context 0',s)
    if m2 and ctx is None: ctx=t
mount=att=None
for l in open('dev/trace.log'):
    m=re.match(r'(\d+\.\d+) block (\S+): (mounting|attached)',l)
    if not m: continue
    if m.group(3)=='mounting' and mount is None: mount=float(m.group(1))
    if m.group(3)=='attached' and att is None: att=float(m.group(1))
f=lambda a,b: (b-a)*1e3 if a and b else -1
print(json.dumps({"mount_to_attached":f(mount,att),"open_to_drawn":f(open_t,ctx),"request_to_attached":f(t0,att),"request_to_open":f(t0,open_t),"open_to_mount":f(open_t,mount)}))
PY
  # Close it again, so the window doesn't fill up.
  ./dev/rexdev block close "$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['block_ids'][0])" "$R")" >/dev/null 2>&1 || ./dev/rexdev api call session.close_block "{\"session_id\":\"$S\",\"block_id\":$(python3 -c "import json,sys;print(json.dumps(json.loads(sys.argv[1])['block_ids'][0]))" "$R")}" >/dev/null 2>&1
  sleep 0.5
done
python3 - "$out" <<'PY'
import sys,json
rows=[json.loads(l) for l in open(sys.argv[1])]
for k in rows[0]:
    v=sorted(r[k] for r in rows if r[k]>=0)
    if not v: print(k,"no data"); continue
    q=lambda p: v[min(len(v)-1,int(round(p*(len(v)-1))))]
    print("%-20s p50 %7.1f  p90 %7.1f  max %7.1f  (n=%d)"%(k,q(.5),q(.9),v[-1],len(v)))
PY
