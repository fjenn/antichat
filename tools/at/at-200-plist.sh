#!/usr/bin/env bash
# AT-200 leg 4 (M2.T01; R-200 AC4 in its D-014 form): LSMinimumSystemVersion = 26.0, arm64 only, minos 26.0.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="${APP:-$root/build/AntiChat.app}"
min=$(plutil -extract LSMinimumSystemVersion raw "$app/Contents/Info.plist")
arch=$(plutil -extract LSArchitecturePriority.0 raw "$app/Contents/Info.plist")
archs=$(lipo -archs "$app/Contents/MacOS/AntiChat")
minos=$(xcrun vtool -show-build "$app/Contents/MacOS/AntiChat" | awk '/minos/{print $2; exit}')
echo "LSMinimumSystemVersion=$min LSArchitecturePriority=$arch lipo=$archs minos=$minos"
[[ $min == 26.0 && $arch == arm64 && $archs == arm64 && $minos == 26.0 ]]
