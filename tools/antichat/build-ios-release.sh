#!/bin/bash
# Incremental Release build of the iOS app: Hermes bytecode (hermesc -O), dev
# mode off, no Metro. Signs like the debug device build: development signing,
# automatic provisioning, no memory entitlements by default.
#   tools/antichat/build-ios-release.sh sim            -> ios/build/Build/Products/Release-iphonesimulator/PocketPal.app
#   tools/antichat/build-ios-release.sh device         -> ios/build/Build/Products/Release-iphoneos/PocketPal.app
# Never cleans. Full log: ios/build/antichat-release-<target>-build.log
#
# By default the app keeps the dev bundle id (ai.antichat.mobile.dev) so it
# replaces an installed debug build and keeps its data (downloaded models).
# ANTICHAT_BUNDLE_ID=ai.antichat.mobile installs it beside the debug build.
# ANTICHAT_WITH_ENTITLEMENTS=1 signs with the memory entitlements (needs the
# project team's Apple ID in Xcode; a wildcard profile cannot sign them).
# ANTICHAT_RELAY_URL=http://<mac>:8790 bakes a connectors relay into the bundle
# (test builds; tools/antichat/relay-local.sh). Without it: the hosted relay.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="${1:-sim}"
case "$TARGET" in
  sim) ARGS=(-sdk iphonesimulator -destination 'generic/platform=iOS Simulator' ARCHS=arm64) ;;
  # Generic destination: the phone need not be connected while building.
  device) ARGS=(-destination 'generic/platform=iOS' -allowProvisioningUpdates) ;;
  *) echo "usage: $0 sim|device" >&2; exit 2 ;;
esac
# Only the app target reads ANTICHAT_ENTITLEMENTS (a plain CODE_SIGN_ENTITLEMENTS
# override would also reach the pod frameworks).
[ -n "${ANTICHAT_WITH_ENTITLEMENTS:-}" ] || ARGS+=(ANTICHAT_ENTITLEMENTS=AntiChat/AntiChatDevBaseline.entitlements)
ARGS+=("ANTICHAT_BUNDLE_ID=${ANTICHAT_BUNDLE_ID:-ai.antichat.mobile.dev}")
LOG="$ROOT/ios/build/antichat-release-$TARGET-build.log"
mkdir -p "$ROOT/ios/build"
cd "$ROOT/ios"
if SKIP_BUNDLING_METRO_IP=1 xcodebuild \
  -workspace PocketPal.xcworkspace -scheme PocketPal -configuration Release \
  -derivedDataPath build "${ARGS[@]}" build >"$LOG" 2>&1; then
  echo "build ok (release $TARGET)"
else
  grep -E "^/.*: (fatal )?error:|^error:|: error: |requires a provisioning|No profiles|No Account|errSec" "$LOG" | cut -c1-400 | sort -u | head -20 >&2
  echo "build failed; log: $LOG" >&2
  exit 1
fi
