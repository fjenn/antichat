#!/usr/bin/env bash
# Wraps a single-file repro in a minimal .app bundle so XCUIApplication(url:) can launch and audit it.
#   make-repro-app.sh <repro.swift> <out.app> <bundle id>
set -euo pipefail
src=$1; out=$2; id=$3
here="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$src" ]] || src="$here/$src"
name="$(basename "$out" .app)"
rm -rf "$out"
mkdir -p "$out/Contents/MacOS"
swiftc -swift-version 5 -O -o "$out/Contents/MacOS/$name" "$src"
cat >"$out/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign -s - --force "$out" >/dev/null
echo "$out"
