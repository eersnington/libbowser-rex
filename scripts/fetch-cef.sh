#!/bin/sh
# Download the pinned CEF minimal distribution into third_party/cef/ and point
# third_party/cef/current at it. Versions and hashes come from
# https://cef-builds.spotifycdn.com/index.json (macosarm64, stable, minimal).
set -eu
cd "$(dirname "$0")/.."
version="158.0.3+g8c29be2+chromium-158.0.8127.18"
sha1="25c8a98f652214b852f06ec943b504415d115e74"
name="cef_binary_${version}_macosarm64_minimal"
dir="third_party/cef/$version"

if [ ! -d "$dir/$name" ]; then
  download="third_party/cef/download"
  mkdir -p "$download" "$dir"
  url="https://cef-builds.spotifycdn.com/$(printf %s "$name" | sed 's/+/%2B/g').tar.bz2"
  curl -fL --progress-bar -o "$download/$name.tar.bz2" "$url"
  echo "$sha1  $download/$name.tar.bz2" | shasum -a 1 -c -
  tar -xjf "$download/$name.tar.bz2" -C "$dir"
  rm "$download/$name.tar.bz2"
fi
ln -sfn "$version/$name" third_party/cef/current
