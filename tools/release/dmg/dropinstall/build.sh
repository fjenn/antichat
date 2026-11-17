#!/usr/bin/env bash
# Builds the DMG's "Applications" drop target (see main.swift): build/release/dropinstall/Applications.app.
# Usage: build.sh [codesign identity]  (no identity = ad-hoc). Called by tools/release/package-dmg.sh.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../../.." && pwd)"
out="$root/build/release/dropinstall/Applications.app"
rm -rf "$out"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
cp "$here/Info.plist" "$out/Contents/Info.plist"
cp /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns "$out/Contents/Resources/"
xcrun swiftc -O -target arm64-apple-macos26.0 -o "$out/Contents/MacOS/Applications" "$here/main.swift" \
  -framework AppKit -framework Security
if [[ -n "${1:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$1" "$out"
else
  codesign --force --sign - "$out"
fi
codesign --verify --strict "$out"
xcrun swiftc -O -o "$root/build/release/dropinstall/set-icon" "$here/set-icon.swift" -framework AppKit
echo "$out"
