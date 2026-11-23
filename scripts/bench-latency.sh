#!/bin/sh
# Compare bowser-cef's two modes on CALAYERHOST, OSR (a Metal copy per frame)
# and windowed (zero copy), as the host sees them: displayed fps and frame
# times, input-to-display latency, resize gutters, and CPU, GPU, energy, and
# memory per process. See adapters/cef/probe.m for the method, docs/perf.md
# for results.
#
# Usage: scripts/bench-latency.sh [modes] [pages]
#   modes: "osr windowed" (default)
#   pages: "latency anim canvas video wiki" (default)
# The probe window is invisible (alpha 0.01) on the current Space; see probe.m.
set -eu
cd "$(dirname "$0")/.."
make -s cef build/cef/bowser-cef-probe
modes="${1:-osr windowed}"
pages="${2:-latency anim canvas video wiki}"
out="$(mktemp -d)"

# The video is generated once, so the page needs no network. VP9: CEF's
# builds have no H.264.
video="build/bench/video.webm"
if [ ! -s "$video" ] && command -v ffmpeg > /dev/null; then
  mkdir -p build/bench
  ffmpeg -loglevel error -f lavfi -i testsrc2=size=1920x1080:rate=60 -t 10 -pix_fmt yuv420p -c:v libvpx-vp9 \
    -deadline realtime -cpu-used 8 -b:v 8M "$video"
fi
mkdir -p build/bench
cat > build/bench/video.html <<EOF
<body style="margin:0;background:black"><video src="video.webm" autoplay muted loop style="width:100vw;height:100vh"></video>
EOF

# data: URLs, percent-encoded.
encode() { perl -MURI::Escape -e 'print "data:text/html," . uri_escape($ARGV[0])' "$1"; }
page_url() {
  case "$1" in
  latency) encode '<body style="margin:0;height:100vh;background:rgb(0,0,0)"><script>
let n = 0;
const flip = () => { n++; document.body.style.background = n % 2 ? "rgb(255,0,0)" : "rgb(0,0,255)"; };
addEventListener("keydown", flip); addEventListener("mousedown", flip);
</script>' ;;
  anim) encode '<style>@keyframes s { to { transform: rotate(360deg) } }
@keyframes c { to { background: rgb(0,128,255) } }</style>
<body style="margin:0;height:100vh;overflow:hidden;background:rgb(255,200,0);animation:c 1s linear infinite alternate">
<div style="position:absolute;left:25vw;top:15vh;width:50vw;height:70vh;background:linear-gradient(red,blue);animation:s 2s linear infinite"></div>' ;;
  canvas) encode '<body style="margin:0;overflow:hidden"><canvas id=c></canvas><script>
const c = document.getElementById("c"), x = c.getContext("2d");
c.width = innerWidth * devicePixelRatio; c.height = innerHeight * devicePixelRatio;
c.style.width = "100vw"; c.style.height = "100vh";
function draw(t) {
  for (let i = 0; i < 400; i++) {
    x.fillStyle = `hsl(${(t / 5 + i * 9) % 360},80%,50%)`;
    x.fillRect((i * 37 + t / 3) % c.width, (i * 53 + t / 7) % c.height, 120, 120);
  }
  requestAnimationFrame(draw);
}
requestAnimationFrame(draw);
</script>' ;;
  video) echo "file://$PWD/build/bench/video.html" ;;
  wiki) echo "https://en.wikipedia.org/wiki/Chromium_(web_browser)" ;;
  esac
}
page_steps() {
  case "$1" in
  latency) echo "--wait 3 --frames 5 --keys 100 --clicks 100" ;;
  anim) echo "--wait 3 --frames 10 --resize 4" ;;
  canvas | video) echo "--wait 3 --frames 10" ;;
  wiki) echo "--wait 6 --scroll 10" ;;
  esac
}

producer=
probe=
stop() {
  [ -n "$probe" ] && kill "$probe" 2> /dev/null || true
  if [ -n "$producer" ]; then
    kids=$(pgrep -P "$producer" || true)
    kill "$producer" 2> /dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$producer" 2> /dev/null || break; sleep 0.5; done
    kill -9 "$producer" $kids 2> /dev/null || true
  fi
  producer= probe=
}
trap 'stop; rm -rf "$out"' EXIT INT TERM

for page in $pages; do
  for mode in $modes; do
    case "$mode" in
    osr | windowed) exe="build/bowser-cef.app/Contents/MacOS/bowser-cef --transport calayerhost --mode $mode" ;;
    esac
    rm -f "$out/producer.out"
    rm -rf "$out/profile"
    $exe --profile "$out/profile" --url "$(page_url "$page")" > "$out/producer.out" 2> "$out/producer.err" &
    producer=$!
    until [ -s "$out/producer.out" ]; do sleep 0.1; done
    # shellcheck disable=SC2046
    build/cef/bowser-cef-probe "$(head -1 "$out/producer.out")" --producer "$producer" $(page_steps "$page") \
      > "$out/probe.out" 2> "$out/probe.err" &
    probe=$!
    wait "$probe" || { echo "probe failed: $(cat "$out/probe.err")" >&2; }
    probe=
    grep '^step' "$out/probe.out" | sed "s/^step /$mode $page /"
    stop
  done
done
