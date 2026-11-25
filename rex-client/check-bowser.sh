#!/bin/sh
# Runs bowser the way an agent does: in a terminal pane of a real Rex server,
# against real browser panes. The server is a throwaway one, with its own
# HOME and socket, removed at the end; no client, no window.
#
#   rex-client/check-bowser.sh       needs make cef
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/.."
srv="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
t=$(mktemp -d /tmp/bwsr.XXXX) # Unix socket paths are short
fails=0

cleanup() {
  [ -f "$t/server.pid" ] && kill "$(cat "$t/server.pid")" 2> /dev/null && sleep 1
  rm -rf "$t"
}
trap cleanup EXIT

mkdir -p "$t/home" "$t/state" "$t/blocks" "$t/bin"
(cd "$root/rex/plugin" && go build -o "$t/blocks/rexplugin" .)
(cd "$root/rex/bowser" && go build -o "$t/bin/bowser" .)
: > "$t/init.lua"
env -u REX_SESSION -u REX_BLOCK -u REX_CLIENT REX_SERVER="unix://$t/s.sock" PATH="$t/bin:$PATH" HOME="$t/home" \
  BOWSER_ENGINE="$root/build/bowser-cef.app/Contents/MacOS/bowser-cef" \
  "$srv" server run --listen "unix://$t/s.sock" --state-dir "$t/state" --config "$t/init.lua" --restore=false \
  --block-dir "$t/blocks" < /dev/null > "$t/server.log" 2>&1 &
echo $! > "$t/server.pid"
rx() { env -u REX_BLOCK -u REX_SESSION rex --autostart=false -S "unix://$t/s.sock" "$@"; }
for _ in $(seq 1 50); do rx ls > /dev/null 2>&1 && break; sleep 0.2; done
term=$(rx new check -c "$t" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["initial_windows"][0]["block_ids"][0])')

# in_pane N CMD: run CMD in the pane's shell; its output lands in $t/out.N.
n=0
in_pane() {
  n=$((n + 1))
  rm -f "$t/rc.$n"
  rx send -b "$term" "($1) > $t/out.$n 2>&1; echo \$? > $t/rc.$n
"
  for _ in $(seq 1 150); do [ -s "$t/rc.$n" ] && return 0; sleep 0.2; done
  echo "timeout" > "$t/rc.$n"
}
out() { cat "$t/out.$n"; }
check() { # check NAME WANT GOT
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "     want: $2"; echo "     got:  $3"; fails=$((fails + 1)); fi
}

cat > "$t/form.html" << 'EOF'
<title>Sign up</title>
<label>Email <input id=email></label>
<button onclick="document.body.insertAdjacentHTML('beforeend', '<p>Welcome, ' + email.value + '</p>')">Join</button>
<a target=_blank href="data:text/html,<title>Docs</title>">Docs</a>
EOF

in_pane "bowser open $t/form.html --split right --size 0.4"
view=$(rx api call session.view "{\"session_id\":\"$(rx ls --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["sessions"][0]["session_id"])')\"}")
width=$(echo "$view" | python3 -c '
import json, sys
def find(n):
    if not n: return None
    if n.get("block_id") == sys.argv[1]: return n["rect"][2]
    s = n.get("split") or {}
    return find(s.get("before")) or find(s.get("after"))
v = json.load(sys.stdin)
print(round(1 - find(v["windows"][0]["layers"][0]["layout"]), 2))' "$term")
check "open puts the page in a pane beside this one, at the size asked" "0, 0.4" "$(cat "$t/rc.$n"), $width"

in_pane "bowser snapshot -i"
check "a snapshot gives the page's controls refs" '- textbox "Email" [ref=e1]|- button "Join" [ref=e2]|- link "Docs" [ref=e3]' "$(out | paste -sd'|' -)"

in_pane "bowser fill e1 ribbet@example.com && bowser click e2 && bowser wait --text Welcome && bowser eval 'document.body.innerText.trim().split(\"\\n\").pop()'"
check "fill, click, and wait act on the page as a person would" '"Welcome, ribbet@example.com"' "$(out)"

in_pane "bowser click e3 && sleep 1 && bowser ls | awk '{print \$2}' | sort | paste -sd' ' -"
check "a link that opens a window opens a second pane; the first stays" "Docs Sign" "$(out)"

in_pane "bowser snapshot"
check "with two panes, bowser asks which" "several browser panes; pick one with -b PANE" "$(out | head -1 | sed 's/^bowser: //')"

# A live server with browser panes, but not this pane: as a dev server's
# shell that reaches the user's own server.
in_pane "REX_BLOCK=block:00000000-0000-4000-8000-000000000000 bowser ls"
check "a pane whose rex reaches another server is refused" "1 rex reaches a Rex server that doesn't" "$(cat "$t/rc.$n") $(out | cut -c9-45)"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
