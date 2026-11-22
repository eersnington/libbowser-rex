#!/bin/sh
# Start the test producer and attach the Swift host to it.
# Usage: scripts/demo.sh [calayerhost|iosurface]
set -eu
cd "$(dirname "$0")/.."
make -s
transport="${1:-calayerhost}"
fifo="$(mktemp -u)"; mkfifo "$fifo"
build/bowser-test --transport "$transport" > "$fifo" &
producer=$!
trap 'kill $producer 2>/dev/null; rm -f "$fifo"' EXIT INT TERM
read -r ticket < "$fifo"
build/bowser-host "$ticket"
