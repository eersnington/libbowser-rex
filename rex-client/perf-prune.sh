#!/bin/sh
# Keep the newest captures in rex-client/dev/perf under a size cap (default
# 200 MB, PERF_KEEP_MB), deleting the oldest first. Every capture tool runs it.
set -eu
dir="$(cd "$(dirname "$0")" && pwd)/dev/perf"
cap=$((${PERF_KEEP_MB:-200} * 1024))
[ -d "$dir" ] || exit 0
total=0
for d in $(ls -1d "$dir"/*/ 2> /dev/null | sort -r); do
  total=$((total + $(du -sk "$d" | cut -f1)))
  [ $total -gt $cap ] && rm -rf "$d"
done
exit 0
