#!/bin/sh
# Run an isolated Rex dev server and an injected dev copy of the Rex client.
#
# Nothing here touches the user's real Rex: the server gets a fake HOME, and
# the client gets its own bundle ID and REX_SERVER and runs inside sandbox.sb,
# which denies writes to the real Rex state and config and denies connecting
# to the real server socket. Client windows go to Space $SPACE
# (default 3) and the client never activates.
#
# Usage: rex-client/run.sh {server|client|stop}
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
dev="$here/dev"
space="${SPACE:-3}"
srv="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
app="${REX_DEV_APP:-$dev/Rex Bowser Dev.app}"
mkdir -p "$dev/home" "$dev/state"
# The dev config loads the repo's browser actions (rex/browser.lua).
printf 'dofile("%s")\n' "$here/../rex/browser.lua" > "$dev/init.lua"

# Every dev client, by its path: a pid file misses one started by hand.
stop_clients() {
  pkill -f "$app/Contents/MacOS/Rex" 2>/dev/null || true
  while pgrep -f "$app/Contents/MacOS/Rex" > /dev/null; do sleep 0.1; done
}

build() {
  clang -O2 "$here/launch.c" -o "$dev/launch"
  clang -fobjc-arc -c "$here/rexinject.m" -o "$dev/rexinject.o"
  make -s -C "$here/.." build/libbowser.a
  swiftc -O -parse-as-library -emit-library -import-objc-header "$here/../include/bowser.h" \
    "$here/mirror.swift" "$here/RexBowser.swift" "$here/BrowserChrome.swift" "$dev/rexinject.o" "$here/../build/libbowser.a" \
    -Xlinker -framework -Xlinker AppKit -Xlinker -framework -Xlinker Carbon \
    -Xlinker -framework -Xlinker QuartzCore -Xlinker -framework -Xlinker IOSurface -o "$dev/rexinject.dylib"
  printf '#!/bin/sh\nexec rex --autostart=false -S unix://%s/s.sock "$@"\n' "$dev" > "$dev/rexdev"
  chmod +x "$dev/rexdev"
}

make_app() {
  [ -d "$app" ] && return
  cp -R "/Applications/Rex Beta.app" "$app"
  plist="$app/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string com.superlogical.rex.bowserdev "$plist"
  plutil -replace CFBundleName -string "Rex Bowser Dev" "$plist"
  plutil -remove SUFeedURL "$plist" 2>/dev/null || true
  plutil -replace SUEnableAutomaticChecks -bool NO "$plist"
  codesign --force --deep --sign - "$app"
  defaults write com.superlogical.rex.bowserdev Onboarding.firstRun -string not-needed
  defaults write com.superlogical.rex.bowserdev SUEnableAutomaticChecks -bool false
  defaults write com.superlogical.rex.bowserdev SUAutomaticallyUpdate -bool false
  defaults write com.superlogical.rex.bowserdev rex.client.remoteControl -bool true
}

case "${1:-}" in
server)
  build
  # The dev.libbowser block plugin (rex/plugin), discovered from --block-dir.
  mkdir -p "$dev/blocks" "$dev/logs"
  (cd "$here/../rex/plugin" && go build -o "$dev/blocks/rexplugin" .)
  make -s -C "$here/.." cef
  # The server is isolated by its fake HOME (Go reads $HOME for every path
  # it keeps, and so does the engine for its profile), not by sandbox.sb:
  # Chromium's own sandbox can't start inside another one, and neither can
  # the setuid /usr/bin/login that shells use. REX_* from a shell inside the
  # user's Rex name the real server; the plugin and its shells must not see them.
  env -u REX_SERVER -u REX_SESSION -u REX_BLOCK -u REX_CLIENT \
    HOME="$dev/home" REX_CONFIG="$dev/init.lua" REXPLUGIN_LOG="$dev/logs/plugin.log" BOWSER_TICKET_SOCKET="$dev/tickets.sock" \
    BOWSER_ENGINE="${BOWSER_ENGINE:-$here/../build/bowser-cef.app/Contents/MacOS/bowser-cef}" "$srv" server run \
    --listen "unix://$dev/s.sock" --state-dir "$dev/state" --config "$dev/init.lua" --restore=false \
    --block-dir "$dev/blocks" < /dev/null > "$dev/server.log" 2>&1 &
  echo $! > "$dev/server.pid"
  ;;
client)
  # Two dev clients would both mount every pane and take the page from each
  # other, so a new one replaces any that is running.
  stop_clients
  build
  make_app
  rm -f "$dev/trace.log"
  REX_SERVER="unix://$dev/s.sock" BOWSER_REX_CLI="$(command -v rex)" BOWSER_REX_SOCKET="$dev/s.sock" BOWSER_SPACE="$space" \
    BOWSER_REX_TICKETS="$dev/tickets.sock" \
    BOWSER_REX_TRACE="$dev/trace.log" BOWSER_REX_DUMP="$dev/views.txt" BOWSER_REX_KEYS="$dev/keys.txt" \
    BOWSER_REX_PERF="$dev/perf.jsonl" \
    DYLD_INSERT_LIBRARIES="$dev/rexinject.dylib" \
    "$dev/launch" "$here/sandbox.sb" "$app/Contents/MacOS/Rex" < /dev/null > "$dev/client.log" 2>&1 &
  pid=$!
  # The injected library keeps windows off the user's Spaces. If it didn't
  # load, kill the client. (Rex opens no window until it's asked to.)
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    grep -q loaded "$dev/trace.log" 2>/dev/null && break
    sleep 0.2
  done
  if ! grep -q loaded "$dev/trace.log" 2>/dev/null; then
    kill "$pid"
    echo "injection failed; client killed" >&2
    exit 1
  fi
  echo "$pid" > "$dev/client.pid"
  ;;
stop)
  for f in client server; do
    [ -f "$dev/$f.pid" ] && kill "$(cat "$dev/$f.pid")" 2>/dev/null || true
    rm -f "$dev/$f.pid"
  done
  stop_clients
  ;;
*)
  echo "usage: $0 {server|client|stop}" >&2
  exit 2
  ;;
esac
