#!/bin/sh
# Start the CEF producer and attach the Swift host to it.
# Usage: scripts/demo-cef.sh [calayerhost|iosurface] [url]
set -eu
cd "$(dirname "$0")/.."
make -s cef
transport="${1:-calayerhost}"
url="${2:-https://example.com}"
fifo="$(mktemp -u)"; mkfifo "$fifo"
build/bowser-cef.app/Contents/MacOS/bowser-cef --transport "$transport" --url "$url" > "$fifo" &
producer=$!
trap 'kill $producer 2>/dev/null; rm -f "$fifo"' EXIT INT TERM
read -r ticket < "$fifo"
build/bowser-host "$ticket"
