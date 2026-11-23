#!/bin/sh
# Assemble a CEF app bundle: the main executable, the CEF framework, and the
# helper apps Chromium starts its child processes from. Chromium finds the
# helpers by name: "<app> Helper", plus one per process type.
# Usage: bundle.sh <out.app> <main-executable> <helper-executable> <cef-release-dir>
set -eu
app=$1 main=$2 helper=$3 release=$4
name=$(basename "$app" .app)
id=dev.libbowser.cef

plist() { # <path> <executable> <bundle id>
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundleIdentifier</key><string>$3</string>
  <key>CFBundleName</key><string>$2</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
EOF
}

frameworks="$app/Contents/Frameworks"
mkdir -p "$app/Contents/MacOS" "$frameworks"
# Replace executables, never overwrite them: the kernel caches a binary's code
# signature by file, and an exec of a file changed in place can die of SIGKILL.
rm -f "$app/Contents/MacOS/$name"
cp "$main" "$app/Contents/MacOS/$name"
plist "$app/Contents/Info.plist" "$name" "$id"

# The framework is 350 MB: clone it (APFS copy-on-write), and only when the
# downloaded one is newer.
src="$release/Chromium Embedded Framework.framework"
dst="$frameworks/Chromium Embedded Framework.framework"
if [ ! -e "$dst" ] || [ "$src/Chromium Embedded Framework" -nt "$dst/Chromium Embedded Framework" ]; then
  rm -rf "$dst"
  cp -Rc "$src" "$dst"
fi

for kind in "" Alerts GPU Plugin Renderer; do
  helper_name="$name Helper${kind:+ ($kind)}"
  contents="$frameworks/$helper_name.app/Contents"
  mkdir -p "$contents/MacOS"
  rm -f "$contents/MacOS/$helper_name"
  cp "$helper" "$contents/MacOS/$helper_name"
  plist "$contents/Info.plist" "$helper_name" "$id.helper$(echo "${kind:+.$kind}" | tr '[:upper:]' '[:lower:]')"
done
