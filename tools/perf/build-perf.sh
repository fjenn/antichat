#!/usr/bin/env bash
# M9.T05: the optimized perf-harness app (`make build-perf`) → build/perf-app/AntiChat.app.
# Release configuration (-O, NDEBUG, no DEBUG) + ANTICHAT_PERF_HARNESS, which compiles in only the test hooks the T05
# probes use (`#if DEBUG || ANTICHAT_PERF_HARNESS`: -ANTICHAT_DEV_CONTAINER and the other launch options, -Bench, probes;
# the container defaults to AntiChat-Dev). Bundle id app.antichat.AntiChat.perf, so its preferences never mix with the
# owner's Release/try-out app (app.antichat.AntiChat) or the Debug app (….dev). Ad-hoc signed, no hardened runtime.
# Never a release: tools/ci/perfharness-guard.py (make audit, release preflight) keeps ANTICHAT_PERF_HARNESS to this
# script and fails any release build that carries it. tools/perf/run.py files a measurement from this app as valid
# only when `AntiChat -Bench buildinfo` reports optimized, non-DEBUG and the perf flag.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT="${PERF_APP_DIR:-build/perf-app}"
DD=build/dd-perf
beautify="$(command -v xcbeautify >/dev/null 2>&1 && echo 'xcbeautify --quiet' || echo cat)"
set -o pipefail
xcodebuild -workspace AntiChat.xcworkspace -scheme AntiChat-Release -configuration Release -derivedDataPath "$DD" \
  -disableAutomaticPackageResolution -packageAuthorizationProvider netrc CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO \
  ARCHS=arm64 'GCC_PREPROCESSOR_DEFINITIONS=$(inherited) NDEBUG=1' \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ANTICHAT_PERF_HARNESS' build | $beautify
mkdir -p "$OUT"
rm -rf "$OUT/AntiChat.app"
cp -R "$DD/Build/Products/Release/AntiChat.app" "$OUT/AntiChat.app"
app="$OUT/AntiChat.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.antichat.AntiChat.perf" "$app/Contents/Info.plist"
codesign --force --sign - --preserve-metadata=entitlements,flags "$app"
info="$("$app/Contents/MacOS/AntiChat" -Bench buildinfo)"
echo "buildinfo: $info"
python3 -I - "$info" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
ok = d.get("perf_harness") is True and d.get("optimized") is True and d.get("debug") is False
print("[ok] perf build: optimized, non-DEBUG, perf-harness flag on" if ok else f"[fail] not a perf build: {d}")
sys.exit(0 if ok else 1)
PY
printf '{"commit": "%s", "buildinfo": %s}\n' "$(git rev-parse HEAD)" "$info" > "$OUT/build.json"
echo "[ok] $app"
