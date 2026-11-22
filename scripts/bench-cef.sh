#!/bin/sh
# Measure bowser-cef while a host scrolls a page for 10 s, then resizes it.
# Prints the producer's frame stats (every 2 s) and CPU per process type.
# Usage: scripts/bench-cef.sh [calayerhost|iosurface] [url] [producer flags...]
set -eu
cd "$(dirname "$0")/.."
make -s cef
transport="${1:-calayerhost}"
url="${2:-https://en.wikipedia.org/wiki/Chromium_(web_browser)}"
[ $# -ge 2 ] && shift 2 || shift $#
out="$(mktemp -d)"
build/bowser-cef.app/Contents/MacOS/bowser-cef --transport "$transport" --url "$url" "$@" \
  > "$out/producer.out" 2> "$out/producer.err" &
producer=$!
bench=
trap 'kill $producer $bench 2>/dev/null; wait; rm -rf "$out"' EXIT INT TERM
until [ -s "$out/producer.out" ]; do sleep 0.1; done
build/cef/bowser-cef-bench "$(head -1 "$out/producer.out")" --wait 5 --scroll 10 --wait 1 --resize 4 \
  > "$out/bench.out" &
bench=$!

# CPU seconds used so far, per process type: browser, gpu, renderer, other
# helpers, host.
cpu() {
  ps -A -o pid=,ppid=,time=,args= | awk -v p="$producer" -v b="$bench" '
    function secs(t, f, n) { n = split(t, f, ":"); return n == 3 ? f[1]*3600 + f[2]*60 + f[3] : f[1]*60 + f[2] }
    $1 == p { c["browser"] += secs($3) }
    $1 == b { c["host"] += secs($3) }
    $2 == p { k = /--type=gpu-process/ ? "gpu" : /--type=renderer/ ? "renderer" : "utility"; c[k] += secs($3) }
    END { printf "%f %f %f %f %f\n", c["browser"], c["gpu"], c["renderer"], c["utility"], c["host"] }'
}
now() { perl -MTime::HiRes=time -e "printf q(%.3f), time"; }
wait_for() { until grep -qs "$1" "$out/bench.out"; do sleep 0.05; done; }

wait_for "^window="
echo "$(grep "^window=" "$out/bench.out")  transport=$transport  url=$url"
wait_for "^scroll begin"
before=$(cpu); t0=$(now)
wait_for "^scroll end"
after=$(cpu); t1=$(now)
echo "CPU while scrolling, % of one core:"
echo "$before $after $t0 $t1" | awk '{ w = $12 - $11; n = split("browser gpu renderer utility host", k, " ");
  for (i = 1; i <= n; i++) printf "  %-9s %5.1f%%\n", k[i], ($(i+5) - $i) / w * 100 }'
wait "$bench" || true
echo "Producer stats (2 s windows; the last ones cover the resize):"
sed 's/^/  /' "$out/producer.err"
