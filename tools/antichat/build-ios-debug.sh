#!/bin/bash
# Incremental Debug build of the iOS app ("AntiChat Dev", ai.antichat.mobile.dev)
# with the JS bundle embedded, so it runs without Metro.
#   tools/antichat/build-ios-debug.sh sim            -> ios/build/Build/Products/Debug-iphonesimulator/PocketPal.app
#   tools/antichat/build-ios-debug.sh device [udid]  -> ios/build/Build/Products/Debug-iphoneos/PocketPal.app
# Never cleans. Full log: ios/build/antichat-<target>-build.log
#
# FORCE_BUNDLING embeds the bundle in simulator builds too (plain JS, see
# ios/.xcode.env). SKIP_BUNDLING_METRO_IP keeps the phone from looking for a
# Metro server on this Mac.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="${1:-sim}"
case "$TARGET" in
  sim) ARGS=(-sdk iphonesimulator -destination 'generic/platform=iOS Simulator' ARCHS=arm64) ;;
  device) ARGS=(-destination "id=${2:-${ANTICHAT_DEVICE:?pass a device udid}}" -allowProvisioningUpdates) ;;
  *) echo "usage: $0 sim|device [udid]" >&2; exit 2 ;;
esac
# ANTICHAT_NO_ENTITLEMENTS=1 signs without the memory entitlements (protocol
# step 0 baseline; also the only build a wildcard profile can sign).
[ -z "${ANTICHAT_NO_ENTITLEMENTS:-}" ] || ARGS+=(CODE_SIGN_ENTITLEMENTS=AntiChat/AntiChatDevBaseline.entitlements)
LOG="$ROOT/ios/build/antichat-$TARGET-build.log"
mkdir -p "$ROOT/ios/build"
cd "$ROOT/ios"
if FORCE_BUNDLING=1 SKIP_BUNDLING_METRO_IP=1 xcodebuild \
  -workspace PocketPal.xcworkspace -scheme PocketPal -configuration Debug \
  -derivedDataPath build "${ARGS[@]}" build >"$LOG" 2>&1; then
  echo "build ok ($TARGET)"
else
  grep -E "^/.*: (fatal )?error:|^error:|: error: |requires a provisioning|No profiles|No Account|errSec" "$LOG" | cut -c1-400 | sort -u | head -20 >&2
  echo "build failed; log: $LOG" >&2
  exit 1
fi
