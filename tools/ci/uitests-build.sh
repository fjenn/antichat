#!/usr/bin/env bash
# `make audit` check (Q-015 follow-up): the AntiChat-UITests target must keep compiling (XCUITest runs since
# 2026-11-10, docs/prd/XCUITEST-REPORT.md). build-for-testing only; prints the compiler errors on failure.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
source tools/env.sh
log=build/audit/uitests-build.log
mkdir -p build/audit
xcodebuild build-for-testing -workspace AntiChat.xcworkspace -scheme AntiChat-UITests \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd -disableAutomaticPackageResolution \
  -packageAuthorizationProvider netrc CODE_SIGN_IDENTITY=- >"$log" 2>&1
rc=$?
if [[ $rc -ne 0 ]] || ! grep -q 'TEST BUILD SUCCEEDED' "$log"; then
  grep -E 'error:' "$log" | sort -u | head -40
  echo "AntiChat-UITests build-for-testing failed (full log: $log)"
  exit 1
fi
echo "AntiChat-UITests build-for-testing ok"
