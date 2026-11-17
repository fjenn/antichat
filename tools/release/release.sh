#!/bin/bash
# tools/release/release.sh — the release pipeline (M10.T08; ci-release §2, §8). Releases run it on a GitHub macOS
# runner (.github/workflows/release.yml, with SKIP_TESTS=1 in the public snapshot); the same script works locally
# for adhoc/dev rehearsals. Artefacts stay in build/release/ (the workflow makes the draft GitHub Release; deploys are
# owner steps, docs/prd/M10-owner-steps.md). Usage: SIGNING_MODE=devid APP_VERSION=1.0.0 tools/release/release.sh
# Env: SIGNING_MODE (default dev), APP_VERSION (default project.yml), SKIP_TESTS=1 (pipeline only),
#      ANTICHAT_ALLOW_DEV_KEYS=1 (devid dry run with the test keys → DEVKEYS), SPARKLE_KEY_FILE (stable feed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$ROOT"
mode="${SIGNING_MODE:-dev}"
ver="${APP_VERSION:-$(sed -n 's/^ *CFBundleShortVersionString: *"\(.*\)"/\1/p' project.yml | head -n 1)}"
log="build/release/release-$(date +%Y%m%d-%H%M%S).log"
mkdir -p build/release
step() { echo "== release [$mode $ver] $*" | tee -a "$log"; }
exec > >(tee -a "$log") 2>&1

step "0 checks: clean tree, notes, checklist, workflows"
[[ -z "$(git status --porcelain)" ]] || { echo "error: working tree not clean"; exit 1; }
python3 -I tools/release/notes-check.py "$ver"
python3 -I tools/release/checklist-check.py
actionlint .github/workflows/*.yml
if [[ "${SKIP_TESTS:-0}" != 1 ]]; then
    step "1 tests + audit"
    make test-unit
    make audit
fi
step "2 build, sign, verify (+ notarize/staple in devid)"
make build-release SIGNING_MODE="$mode" APP_VERSION="$ver" ANTICHAT_ALLOW_DEV_KEYS="${ANTICHAT_ALLOW_DEV_KEYS:-}"
step "3 DMG (+ notarize/staple in devid)"
make dmg SIGNING_MODE="$mode"
step "4 SHA256SUMS (+ .sig with the Sparkle key of the build's channel)"
keys="$(python3 -I -c 'import json; print(json.load(open("build/release/build.json"))["keys"])')"
key="${SPARKLE_KEY_FILE:-catalog/test-keys/sparkle-test.key}"
[[ "$keys" == release && -z "${SPARKLE_KEY_FILE:-}" ]] && { echo "error: release keys need SPARKLE_KEY_FILE"; exit 1; }
(cd build/release && shasum -a 256 AntiChat-*.dmg > SHA256SUMS)
build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update --ed-key-file "$key" -p build/release/SHA256SUMS > build/release/SHA256SUMS.sig
step "5 appcast ($([[ "$keys" == release ]] && echo stable || echo dev) feed, local file only)"
if [[ "$keys" == release ]]; then
    FEED=stable SPARKLE_KEY_FILE="$key" RELEASES_URL_PREFIX="${RELEASES_URL_PREFIX:-$(/usr/libexec/PlistBuddy -c 'Print :ReleasesURLPrefix' Config/Endpoints.plist)v$ver/}" make appcast
else
    FEED=dev make appcast
fi
step "6 publish preflight (what still blocks a public release)"
python3 -I tools/release/preflight.py || true
step "done: artefacts in build/release/ (nothing published). Owner steps: docs/prd/M10-owner-steps.md"
