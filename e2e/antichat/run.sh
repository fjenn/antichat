#!/bin/bash
# Runs the AntiChat Maestro flows and collects paired screenshots.
#
#   e2e/antichat/run.sh [ios|android|both] [light|dark|both] [flow ...]
#
# Screenshots land in e2e/antichat/screenshots/<platform>-<theme>[-large]/.
# The apps must already be installed (see docs/antichat/m1/README.md); debug
# apps load JS from Metro on $METRO_PORT.
#
# Environment:
#   IOS_UDID        simulator to use (default: the one named AntiChat-M1)
#   ANDROID_SERIAL  emulator to use (default: emulator-5560, AVD antichat-m1)
#   METRO_PORT      default 8091
#   FONT_SCALE=max  also set the largest text size; folder gets "-large"
#
# Flows named real-* run against the real engine and need a model on the
# device (docs/antichat/m2/README.md); every other flow uses the in-memory
# backend.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/tools/android-env.sh"
export MAESTRO_CLI_NO_ANALYTICS=1

PLATFORMS="${1:-both}"; THEMES="${2:-both}"; shift $(( $# > 2 ? 2 : $# )) || true
FLOWS=("$@"); [ ${#FLOWS[@]} -gt 0 ] || FLOWS=(theme shell streaming chat-send chat-actions chat-composer)
[ "$PLATFORMS" = both ] && PLATFORMS="ios android"
[ "$THEMES" = both ] && THEMES="light dark"

METRO_PORT="${METRO_PORT:-8091}"
IOS_APP=ai.antichat.mobile.dev
ANDROID_APP=com.pocketpalai.antichatdev
ANDROID_SERIAL="${ANDROID_SERIAL:-emulator-5560}"
IOS_UDID="${IOS_UDID:-$(xcrun simctl list devices | sed -n 's/.*AntiChat-M1 (\([0-9A-F-]*\)).*/\1/p' | head -1)}"
SUFFIX=""; [ "${FONT_SCALE:-}" = max ] && SUFFIX="-large"
# M6: an extra folder suffix, e.g. SHOT_SUFFIX=-small for a small phone.
SHOT_SUFFIX="${SHOT_SUFFIX:-}"
ADB=(adb -s "$ANDROID_SERIAL")

appearance() { # platform theme
  if [ "$1" = ios ]; then
    xcrun simctl ui "$IOS_UDID" appearance "$2"
    xcrun simctl ui "$IOS_UDID" content_size \
      "$([ -n "$SUFFIX" ] && echo accessibility-extra-extra-extra-large || echo large)"
  else
    "${ADB[@]}" shell cmd uimode night "$([ "$2" = dark ] && echo yes || echo no)" >/dev/null
    "${ADB[@]}" shell settings put system font_scale "$([ -n "$SUFFIX" ] && echo 2.0 || echo 1.0)"
  fi
}

prepare() { # platform
  if [ "$1" = android ]; then
    "${ADB[@]}" shell am force-stop "$ANDROID_APP"
    # Emulators look for Metro on 10.0.2.2:8081 unless told otherwise.
    printf "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n    <string name=\"debug_http_host\">10.0.2.2:%s</string>\n</map>\n" "$METRO_PORT" \
      | "${ADB[@]}" shell "run-as $ANDROID_APP sh -c 'mkdir -p shared_prefs && cat > shared_prefs/${ANDROID_APP}_preferences.xml'"
  fi
}

FAILED=0
for platform in $PLATFORMS; do
  if [ "$platform" = ios ]; then DEVICE="$IOS_UDID"; APP="$IOS_APP"; else DEVICE="$ANDROID_SERIAL"; APP="$ANDROID_APP"; fi
  for theme in $THEMES; do
    OUT="$HERE/screenshots/$platform-$theme$SUFFIX$SHOT_SUFFIX"
    mkdir -p "$OUT"
    appearance "$platform" "$theme"
    for flow in "${FLOWS[@]}"; do
      prepare "$platform"
      echo "== $platform $theme$SUFFIX: $flow"
      DEBUG="$HERE/.maestro-debug/$platform-$theme$SUFFIX-$flow"
      rm -rf "$DEBUG"
      BACKEND=fake; case "$flow" in real-*) BACKEND=real;; esac
      # Tokens per second of the in-memory model. chat-send watches an answer
      # while it is written, so it gets a slow one.
      RATE=60; [ "$flow" = chat-send ] && RATE=15
      if ! maestro --device "$DEVICE" test -e APP_ID="$APP" -e METRO="127.0.0.1:$METRO_PORT" -e BACKEND="$BACKEND" -e RATE="$RATE" \
            --debug-output "$DEBUG" "$HERE/flows/$flow.yaml"; then
        FAILED=1
      fi
      # Maestro 2 keeps takeScreenshot output inside the debug folder.
      find "$DEBUG" -path '*takeScreenshot*' -name '*.png' -exec cp {} "$OUT/" \;
    done
  done
  appearance "$platform" light
done
[ -z "$SUFFIX" ] || { SUFFIX=""; for platform in $PLATFORMS; do appearance "$platform" light; done; }
exit $FAILED
