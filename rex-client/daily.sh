#!/bin/sh
# Browser panes in your everyday Rex: an injected copy of Rex.app, against
# your own Rex server, which loads the browser plugin.
#
#   rex-client/daily.sh install   build; put the plugin in your server's plugin
#                                 folder, bowser in ~/.local/bin, and the injected
#                                 copy in ~/Applications. Changes nothing running.
#   rex-client/daily.sh switch    quit Rex, restart your server so it loads the
#                                 plugin, and open the injected copy. Programs
#                                 running in your terminals end; your sessions
#                                 and layouts come back.
#   rex-client/daily.sh revert    quit the copy, take the plugin out, restart your
#                                 server, and open Rex.app again.
#
# The copy keeps Rex's bundle ID, so it is your Rex: same settings, same
# server. It never updates itself; run install again after Rex updates.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/.."
stock="/Applications/Rex.app"
app="$HOME/Applications/Rex Bowser.app"
lib="$HOME/Library/Application Support/libbowser"
blocks="$HOME/Library/Application Support/rex/blocks" # the server's own plugin folder
plugin="$blocks/libbowser"
config="${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua"
load_line="dofile(\"$root/rex/browser.lua\") -- libbowser: browser panes (rex-client/daily.sh)"
rex="$(command -v rex)"

install() {
  make -s -C "$root" build/libbowser.a cef
  mkdir -p "$lib" "$blocks" "$HOME/.local/bin" "$HOME/Applications"
  clang -fobjc-arc -c "$here/rexinject.m" -o "$lib/rexinject.o"
  swiftc -O -parse-as-library -emit-library -import-objc-header "$root/include/bowser.h" \
    "$here/mirror.swift" "$here/RexBowser.swift" "$here/BrowserChrome.swift" "$lib/rexinject.o" "$root/build/libbowser.a" \
    -Xlinker -framework -Xlinker AppKit -Xlinker -framework -Xlinker Carbon \
    -Xlinker -framework -Xlinker QuartzCore -Xlinker -framework -Xlinker IOSurface -o "$lib/rexinject.dylib.new"
  mv "$lib/rexinject.dylib.new" "$lib/rexinject.dylib"
  rm -f "$lib/rexinject.o"
  # Built aside and moved in: never change a binary that may be running.
  (cd "$root/rex/plugin" && go build -o "$plugin.new" .) && mv "$plugin.new" "$plugin"
  (cd "$root/rex/bowser" && go build -o "$HOME/.local/bin/bowser.new" .) && mv "$HOME/.local/bin/bowser.new" "$HOME/.local/bin/bowser"

  # A copy that may load our library: signed ad hoc, and with no update feed,
  # so it never replaces itself with an uninjectable Rex.
  rm -rf "$app.new"
  cp -R "$stock" "$app.new"
  plutil -remove SUFeedURL "$app.new/Contents/Info.plist" 2> /dev/null || true
  plutil -replace CFBundleName -string "Rex Bowser" "$app.new/Contents/Info.plist"
  codesign --force --deep --sign - "$app.new" 2> /dev/null
  rm -rf "$app" && mv "$app.new" "$app"
  echo "installed: $(defaults read "$app/Contents/Info" CFBundleVersion) from $stock"
}

open_copy() {
  open -n "$app" --env DYLD_INSERT_LIBRARIES="$lib/rexinject.dylib" \
    --env BOWSER_REX_TICKETS="$lib/tickets.sock" --env BOWSER_REX_CLI="$rex"
}

quit_rex() {
  osascript -e 'tell application id "com.superlogical.rex" to quit' 2> /dev/null || true
  for _ in $(seq 1 50); do pgrep -f "$1/Contents/MacOS/Rex" > /dev/null || return 0; sleep 0.2; done
  pkill -f "$1/Contents/MacOS/Rex" || true
}

stop_server() { "$rex" --autostart=false server stop || true; }

# The app starts your server, with its own options, when it opens. If it
# hasn't within 20 s, start one.
await_server() {
  for _ in $(seq 1 100); do "$rex" --autostart=false ls > /dev/null 2>&1 && return 0; sleep 0.2; done
  "$rex" server start
}

# switch and revert end every program in Rex's terminals, this script's own
# shell too: launchd runs them, outside that tree, and logs to $lib/daily.log.
detach() {
  launchctl remove libbowser.daily 2> /dev/null || true
  launchctl submit -l libbowser.daily -o "$lib/daily.log" -e "$lib/daily.log" -- /bin/sh "$here/daily.sh" "$1"
  echo "running $1 outside Rex; log: $lib/daily.log"
}

case "${1:-}" in
install) install ;;
switch | revert)
  [ -d "$app" ] || { echo "run install first" >&2; exit 1; }
  mkdir -p "$lib"
  detach "_$1"
  ;;
_switch)
  echo "$(date) switch"
  launchctl remove libbowser.daily 2> /dev/null || true # it ran; don't run again at login
  grep -qF "$load_line" "$config" 2> /dev/null || { mkdir -p "$(dirname "$config")"; echo "$load_line" >> "$config"; }
  quit_rex "$stock"
  stop_server
  open_copy
  await_server
  echo "$(date) switched"
  ;;
_revert)
  echo "$(date) revert"
  launchctl remove libbowser.daily 2> /dev/null || true
  quit_rex "$app"
  rm -f "$plugin"
  [ -f "$config" ] && grep -vF "$load_line" "$config" > "$config.new" && mv "$config.new" "$config"
  stop_server
  open "$stock"
  await_server
  echo "$(date) reverted"
  ;;
*)
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
  ;;
esac
