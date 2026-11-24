#!/bin/sh
# End to end through the real Rex client: open a page in a browser pane, type
# into it one key at a time like a person, and check what the page got.
# Needs the dev Rex running (run.sh server, run.sh client). Keys go through
# the client's own NSApp.sendEvent (rexinject.m), so they take the same path
# as a keyboard: Rex, the pane's NSTextInputContext, libbowser, the engine.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
dev="$here/dev"
rexdev="$dev/rexdev"
pid=$(cat "$dev/client.pid")
# The load-test session (dev/restore.sh), never someone's own: else the first.
session=$("$rexdev" api call session.list '{}' | python3 -c 'import sys,json;s=json.load(sys.stdin)["sessions"];print(next((x["session_id"] for x in s if x.get("label")=="loadtest"),s[0]["session_id"]))')

key() { printf '%s\n' "$1" > "$dev/keys.txt"; kill -INFO "$pid"; sleep 0.09; }
type_slow() { s="$1"; while [ -n "$s" ]; do c="${s%"${s#?}"}"; s="${s#?}"; key "type:$c"; done; }

# check NAME HTML KEYS WANT: the page's title is the field's value.
check() {
  url=$(python3 -c 'import sys,urllib.parse;print("url=data:text/html,"+urllib.parse.quote(sys.argv[1]))' "$2")
  block=$("$rexdev" do browser -s "$session" "$url" | python3 -c 'import sys,json;print(json.load(sys.stdin)["block_ids"][0])')
  sleep 1.5
  type_slow "$3"
  sleep 0.8
  got=$("$rexdev" block call -b "$block" state | python3 -c 'import sys,json;print(json.load(sys.stdin)["title"])')
  "$rexdev" block close "$block" > /dev/null 2>&1 || true
  if [ "$got" = "$4" ]; then echo "ok   $1"; else echo "FAIL $1: got '$got', want '$4'"; failed=1; fi
}

failed=0
show='oninput="document.title=this.value"'
check "each key types once, none dropped" \
  "<title>-</title><input autofocus $show>" "crab rave fast typing" "crab rave fast typing"
check "a key the page cancels types nothing" \
  "<title>-</title><input id=i $show><script>addEventListener('keydown',e=>{if(e.key=='/'&&document.activeElement!==i){e.preventDefault();i.focus()}})</script>" \
  "/crab" "crab"
exit $failed
