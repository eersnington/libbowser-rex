#!/bin/sh
# Run an isolated Rex server with the dev.libbowser plugin, in the foreground.
# Everything lives in rex/dev/: socket, state, logs, and a fake HOME, because the
# server keeps a lock dir under $HOME that --state-dir does not cover.
# sandbox.sb denies writes to the real Rex state and connects to the real socket.
set -e
R=$(cd "$(dirname "$0")" && pwd)
D="$R/dev"
REX_APP="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
mkdir -p "$D/blocks" "$D/state" "$D/home" "$D/logs"
: > "$D/init.lua"
(cd "$R/plugin" && go build -o "$D/blocks/rexplugin" .)
cd "$D"
exec env -u REX_SERVER -u REX_SESSION -u REX_BLOCK -u REX_CLIENT \
  HOME="$D/home" REX_CONFIG="$D/init.lua" REXPLUGIN_LOG="$D/logs/plugin.log" \
  BOWSER_PRODUCER="${BOWSER_PRODUCER:-$(dirname "$R")/build/bowser-test}" \
  sandbox-exec -D HOME="$HOME" -f "$R/sandbox.sb" \
  "$REX_APP" server run --listen "unix://$D/server.sock" --state-dir "$D/state" \
  --config "$D/init.lua" --restore=false --block-dir "$D/blocks" "$@"
