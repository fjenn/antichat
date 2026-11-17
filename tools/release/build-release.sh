#!/bin/bash
# tools/release/build-release.sh — `make build-release` (M10.T01; ci-release §3/§4; R-305 AC1).
#   1. xcodebuild archive (Release, arm64, CODE_SIGNING_ALLOWED=NO: Xcode signs nothing, sign.sh signs everything
#      once, in order) → build/AntiChat.xcarchive
#   2. ditto --arch arm64 the app → $OUT/AntiChat.app (thins universal third-party binaries such as Sparkle);
#      dSYMs → $OUT/dSYMs (local artefact only, never uploaded, R-218)
#   3. stamp CFBundleShortVersionString=$APP_VERSION, CFBundleVersion=`git rev-list --count HEAD` (monotonic).
#      In the public snapshot (tools/release/export-public.sh) the number comes from SOURCE_REVISION `build=`:
#      the main tree's commit count at export, so builds made on GitHub keep counting where local ones stopped.
#   4. arch check: every Mach-O is arm64 only; no model files in the bundle; no developer test mode compiled in
#      (tools/ci/dev-modes-guard.py + perfharness-guard.py on the built binaries: bench mode, probes, launch options)
#   5. tools/release/sign.sh --mode $SIGNING_MODE (inside out, never --deep)
#   6. verify-signing.sh (devid: --pre-notary first)
#   7. devid + NOTARIZE=1: notarize.sh --app (zip → notarytool → staple → validate), then verify-signing.sh again
#      (Gatekeeper must accept: "source=Notarized Developer ID")
#   8. $OUT/LABEL (UNNOTARIZED | DEVKEYS | empty) and $OUT/build.json (version, build, mode, identity, commit, label)
# Never launches the built app: it carries the shipped bundle ids under this build's signature (M10 card).
# Keys (M10.T04): devid builds pin Config/Keys.release.plist (compile condition ANTICHAT_RELEASE_KEYS + SUPublicEDKey
#      stamped from it) and stop before compiling while it holds test keys; adhoc/dev builds, and devid with
#      ANTICHAT_ALLOW_DEV_KEYS=1 (labelled DEVKEYS), use Config/Keys.dev.plist.
# Env: SIGNING_MODE (adhoc|dev|devid, default adhoc), ANTICHAT_ALLOW_DEV_KEYS (0|1), APP_VERSION (default: project.yml CFBundleShortVersionString),
#      NOTARIZE (devid only; default 1), OUT (default build/release), SKIP_XCODEBUILD=1 (re-sign the last archive),
#      BUILD_NUMBER (CFBundleVersion override for test feeds; refused with devid).
# Owner try-out preview (`make build-tryout`, never a release): TRYOUT_PREVIEW=1 compiles with ANTICHAT_TRYOUT_PREVIEW
#      (every pack on) and bundles the signed runtime zips from TRYOUT_RUNTIMES (sha256 = catalog); refused with
#      Developer ID signing or release keys; labelled PREVIEW. tools/ci/tryout-guard.py (make audit) keeps it so.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$ROOT"
source tools/release/lib/identity.sh
mode="${SIGNING_MODE:-adhoc}"
out="${OUT:-build/release}"
archive="build/AntiChat.xcarchive"
notarize="${NOTARIZE:-1}"
version="${APP_VERSION:-$(sed -n 's/^ *CFBundleShortVersionString: *"\(.*\)"/\1/p' project.yml | head -n 1)}"
# BUILD_NUMBER: test feeds only (AT-FA-12 stamps N-1 below N from one archive); refused for devid below.
source_build="$(sed -n 's/^build=\([0-9][0-9]*\)$/\1/p' SOURCE_REVISION 2>/dev/null | head -n 1)"
build_number="${BUILD_NUMBER:-${source_build:-$(git rev-list --count HEAD)}}"
commit="$(git rev-parse HEAD)"; dirty_at_start="$(git status --porcelain | wc -l | tr -d ' ')"  # what was built
step() { echo "== build-release [$mode] $*"; }
[[ -z "${BUILD_NUMBER:-}" || "$mode" != devid ]] || { echo "error: BUILD_NUMBER is for test feeds; devid uses the commit count" >&2; exit 1; }

identity_resolve "$mode" || {
    if [[ "$mode" == dev ]]; then echo "warning: no Apple Development identity; falling back to adhoc (M10.md table)"; mode=adhoc; identity_resolve adhoc
    else exit 1; fi
}
keys=dev
if [[ "${ANTICHAT_ALLOW_DEV_KEYS:-}" == 0 || ( "$mode" == devid && "${ANTICHAT_ALLOW_DEV_KEYS:-0}" != 1 ) ]]; then keys=release; fi
python3 -I tools/release/gen-keys-swift.py --check >/dev/null || { echo "error: PinnedKeys.swift is stale (python3 -I tools/release/gen-keys-swift.py)" >&2; exit 1; }
if [[ "$keys" == release ]] && ! python3 -I tools/release/gen-keys-swift.py --release-ready; then
    echo "error: a release-keys build needs production keys (tools/release/KEYS.md; ANTICHAT_ALLOW_DEV_KEYS=1 builds a DEVKEYS dry run)" >&2
    exit 1
fi
conditions=()
[[ "$keys" == release ]] && conditions=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ANTICHAT_RELEASE_KEYS')
# RC review P2-8: the committed Sparkle test key and the AntiChatFeedURLOverride default work only in Debug and in
# adhoc/dev-signed dev-keys builds (AT-FA-12's VM upgrade); a Developer ID build never compiles them in
# (UpdateFeed.devFeedAllowed). tools/ci/devfeed-guard.py (make audit, preflight) keeps this line as it is.
[[ "$keys" == dev && "$mode" != devid ]] && conditions=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ANTICHAT_DEV_FEED')
tryout="${TRYOUT_PREVIEW:-0}"
if [[ "$tryout" == 1 ]]; then
    if [[ "$mode" == devid || "$keys" == release ]]; then
        echo "error: TRYOUT_PREVIEW is for owner try-outs only (adhoc/dev signing, dev keys), never a release build" >&2
        exit 1
    fi
    conditions=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ANTICHAT_TRYOUT_PREVIEW')
fi
step "identity: $IDENTITY_NAME; keys: $keys; version $version ($build_number)"

if [[ "${SKIP_XCODEBUILD:-0}" != 1 ]]; then
    step "xcodebuild archive"
    rm -rf "$archive"
    set -o pipefail
    beautify="$(command -v xcbeautify >/dev/null 2>&1 && echo 'xcbeautify --quiet' || echo cat)"
    # RELEASE_CDEFS (Makefile): SwiftPM C targets need NDEBUG in Release (DuckDB D_ASSERT).
    xcodebuild -workspace AntiChat.xcworkspace -scheme AntiChat-Release -configuration Release \
        -destination 'generic/platform=macOS' -derivedDataPath build/dd \
        -disableAutomaticPackageResolution -packageAuthorizationProvider netrc \
        CODE_SIGNING_ALLOWED=NO ARCHS=arm64 'GCC_PREPROCESSOR_DEFINITIONS=$(inherited) NDEBUG=1' ${conditions[@]+"${conditions[@]}"} \
        archive -archivePath "$archive" | $beautify
fi
src="$archive/Products/Applications/AntiChat.app"
[[ -d "$src" ]] || { echo "error: $src missing (archive failed?)" >&2; exit 1; }

step "copy (arm64 slices only) → $out/AntiChat.app"
rm -rf "$out/AntiChat.app" "$out/dSYMs" "$out/notary" "$out/verify" "$out/sign-report.tsv" "$out/LABEL" "$out/build.json"
mkdir -p "$out"
ditto --arch arm64 --norsrc "$src" "$out/AntiChat.app"
# `ditto --arch` left Sparkle universal on GitHub's macOS 27 runner: thin any binary still carrying other slices.
while IFS= read -r f; do
    [[ "$(file -b "$f")" == Mach-O* ]] || continue
    a=" $(lipo -archs "$f" 2>/dev/null || true) "
    [[ "$a" != " arm64 " && "$a" == *" arm64 "* ]] || continue
    perms="$(stat -f %Lp "$f")"  # not "mode": that is the signing mode below
    lipo "$f" -thin arm64 -output "$f.thin"
    chmod "$perms" "$f.thin"
    mv -f "$f.thin" "$f"
done < <(find "$out/AntiChat.app" -type f)
[[ -d "$archive/dSYMs" ]] && ditto "$archive/dSYMs" "$out/dSYMs"
app="$out/AntiChat.app"
xattr -cr "$app"

step "stamp version"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" -c "Set :CFBundleVersion $build_number" \
    -c "Set :SUPublicEDKey $(python3 -I tools/release/gen-keys-swift.py --sparkle-key "$keys")" "$app/Contents/Info.plist"

if [[ "$tryout" == 1 ]]; then
    step "try-out preview: bundle the signed runtime zips (sha256 = catalog)"
    python3 -I tools/release/tryout-runtimes.py --from "${TRYOUT_RUNTIMES:-build/runtimes/signed}" \
        --into "$app/Contents/Resources/TryoutRuntimes"
fi

step "arch + contents check"
bad=0; n=0
while IFS= read -r f; do
    [[ "$(file -b "$f")" == Mach-O* ]] || continue
    n=$((n + 1))
    archs="$(lipo -archs "$f" 2>/dev/null || echo '?')"
    [[ "$archs" == arm64 ]] || { echo "  not arm64-only: ${f#"$app"/} ($archs)"; bad=$((bad + 1)); }
done < <(find "$app" -type f)
((bad == 0)) || { echo "error: $bad Mach-O not arm64-only" >&2; exit 1; }
models="$(find "$app" \( -name '*.gguf' -o -name '*.safetensors' -o -name '*.mlpackage' \) | wc -l | tr -d ' ')"
[[ "$models" == 0 ]] || { echo "error: $models model files inside the app bundle (NFR-D1)" >&2; exit 1; }
echo "  $n Mach-O, all arm64; 0 model files; app $(du -sh "$app" | cut -f1)"
# Owner decision: no developer test mode ships (bench, spike, probes, dev launch options). Refused before signing; the
# refused app is removed so it can never be signed, packaged or tried out by mistake.
if ! python3 -I tools/ci/dev-modes-guard.py --app "$app" || ! python3 -I tools/ci/perfharness-guard.py --app "$app"; then
    rm -rf "$app"
    echo "error: the build carries developer test modes (see above); not a release" >&2
    exit 1
fi

step "sign"
CODE_SIGN_IDENTITY="$([[ "$mode" == adhoc ]] && echo "" || echo "$IDENTITY")" \
    tools/release/sign.sh --mode "$mode" --app "$app" --report "$out/sign-report.tsv"

step "verify"
if [[ "$mode" == devid ]]; then
    tools/release/verify-signing.sh --mode devid --pre-notary --out "$out/verify-pre" "$app"
else
    tools/release/verify-signing.sh --mode "$mode" --out "$out/verify" "$app"
fi

notarized=false
if [[ "$mode" == devid && "$notarize" == 1 ]]; then
    step "notarize + staple app"
    if ! tools/release/notarize.sh --mode devid --out "$out/notary" --app "$app"; then
        rm -rf "$app"   # card contract 2: a devid artefact that failed notarization never stays next to good ones
        exit 1
    fi
    notarized=true
    step "verify (after stapling: Gatekeeper must accept)"
    tools/release/verify-signing.sh --mode devid --out "$out/verify" "$app"
fi

label="$(release_label "$mode" "$app")"
[[ "$mode" == devid && "$notarized" == false ]] && label="UNNOTARIZED"
[[ "$tryout" == 1 ]] && label="PREVIEW${label:+ $label}"
printf '%s\n' "$label" > "$out/LABEL"
python3 -I - "$out/build.json" "$version" "$build_number" "$mode" "$IDENTITY_NAME" "$commit" \
    "$label" "$notarized" "$dirty_at_start" "$keys" "$tryout" <<'PY'
import json, sys
path, version, build, mode, ident, commit, label, notarized, dirty, keys, tryout = sys.argv[1:]
json.dump({"version": version, "build": int(build), "signing_mode": mode, "identity": ident, "commit": commit, "keys": keys,
           "dirty_files": int(dirty), "label": label or None, "notarized": notarized == "true",
           "tryout_preview": tryout == "1"},
          open(path, "w"), indent=2)
PY
step "done: $app (label: ${label:-none}, notarized: $notarized)"
