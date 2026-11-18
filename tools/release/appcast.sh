#!/bin/bash
# tools/release/appcast.sh — build + sign the Sparkle feed (M10.T03 step 7–8; R-219 AC1/AC5; ci-release §6.2).
# FEED=dev:    every DMG in build/updates/dev/ (UNNOTARIZED/DEVKEYS allowed), test EdDSA key
#              catalog/test-keys/sparkle-test.key, enclosures under $DEV_BASE_URL → site/public/appcast-dev.xml.
# FEED=stable: refuses UNNOTARIZED/DEVKEYS DMGs, DMGs Gatekeeper does not accept, and the test key; needs the
#              production key file in $SPARKLE_KEY_FILE (never in the repo, KEYS.md) and
#              $RELEASES_URL_PREFIX (GitHub Releases) → site/public/appcast.xml.
# Steps: copy build/release/AntiChat-<ver>*.dmg into build/updates/<feed>/ (the last 3 stay, for deltas) →
# notes/<ver>.md → <dmg>.html (embedded release notes) → generate_appcast --embed-release-notes --maximum-deltas 2
# [--phased-rollout-interval] → appcast-post.py (min OS, arm64, phased, critical/beta) → sign_update (feed signature,
# re-signed after the edit) → appcast-lint.py. Writes files locally only; publishing is M10.T05/T10.
# Env: FEED (dev|stable, default dev), DEV_BASE_URL (default http://192.168.64.1:8765), SPARKLE_BIN, NO_PHASED=1
#      (the VM test feed: no phased rollout, appcast-lint --test-feed), OUT (default site/public), DMG_DIR (default
#      build/release), UPDATES_DIR (default build/updates/<feed>).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$ROOT"
feed="${FEED:-dev}"
bin="${SPARKLE_BIN:-build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin}"
out="${OUT:-site/public}"
dir="${UPDATES_DIR:-build/updates/$feed}"   # UPDATES_DIR / DMG_DIR: an isolated test feed (M10.T09 VM legs)
test_key="catalog/test-keys/sparkle-test.key"
for t in generate_appcast sign_update; do [[ -x "$bin/$t" ]] || { echo "error: $bin/$t missing (build once)" >&2; exit 1; }; done
case "$feed" in
    dev) key="$test_key"; prefix="${DEV_BASE_URL:-http://192.168.64.1:8765}/"; name="appcast-dev.xml" ;;
    stable)
        key="${SPARKLE_KEY_FILE:?stable feed needs SPARKLE_KEY_FILE (production key, KEYS.md)}"
        cmp -s "$key" "$test_key" && { echo "error: stable feed refuses the test key" >&2; exit 1; }
        prefix="${RELEASES_URL_PREFIX:?stable feed needs RELEASES_URL_PREFIX (GitHub Releases download URL)}"
        name="appcast.xml" ;;
    *) echo "error: FEED=dev|stable" >&2; exit 2 ;;
esac

# Gatekeeper on a release archive: a signed + notarized image (up to 0.0.5) is assessed as a whole; the raw
# read-write installer image (package-dmg.sh: unsigned by design) by the stapled app inside it, mounted read-only.
gatekeeper_accepts() {
    spctl -a -t open --context context:primary-signature "$1" >/dev/null 2>&1 && return 0
    local m sp=""
    m="$(mktemp -d "${TMPDIR:-/tmp}/antichat-appcast.XXXXXX")"
    if hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$m" "$1" >/dev/null 2>&1; then
        sp="$(spctl -a -vv -t exec "$m/AntiChat.app" 2>&1 || true)"
        hdiutil detach -quiet "$m" 2>/dev/null || hdiutil detach -force -quiet "$m" 2>/dev/null || true
    fi
    rmdir "$m" 2>/dev/null || true
    [[ "$sp" == *accepted* && "$sp" == *"Notarized Developer ID"* ]]
}

mkdir -p "$dir"
shopt -s nullglob
# The previous feed's enclosure URLs (earlier releases live under their own tag; appcast-post --keep-urls).
prev="$(mktemp -t appcast-prev)"; trap 'rm -f "$prev"' EXIT
[[ -f "$dir/appcast.xml" ]] && cp "$dir/appcast.xml" "$prev"
dmgs=("${DMG_DIR:-build/release}"/AntiChat-*.dmg)
((${#dmgs[@]} > 0)) || { echo "error: no DMG in ${DMG_DIR:-build/release} (make dmg)" >&2; exit 1; }
for dmg in "${dmgs[@]}"; do
    base="$(basename "$dmg")"
    if [[ "$feed" == stable ]]; then
        [[ "$base" != *UNNOTARIZED* && "$base" != *DEVKEYS* ]] || { echo "error: $base is labelled; not for the production feed" >&2; exit 1; }
        gatekeeper_accepts "$dmg" || { echo "error: Gatekeeper rejects $base" >&2; exit 1; }
    fi
    # A rebuilt archive with the same name supersedes the old build: its item's signature no longer matches, so
    # the feed is regenerated from the archives (items of other versions are recreated from their DMGs).
    ver="$(sed -E 's/^AntiChat-(Installer-)?([0-9][0-9.]*[0-9a-z.-]*[0-9])(-UNNOTARIZED|-DEVKEYS)?\.dmg$/\2/' <<< "$base")"
    # The installer image also holds the "Applications" drop target, itself an app bundle, and generate_appcast
    # refuses an archive with two bundles ("Too many bundles"). Such an image is fed to Sparkle as a zip of the
    # stapled AntiChat.app alone (AntiChat-<ver>.zip, uploaded next to the DMG); the DMG stays the download.
    m="$(mktemp -d "${TMPDIR:-/tmp}/antichat-appcast.XXXXXX")"
    hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$m" "$dmg" >/dev/null
    bundles=("$m"/*.app)
    if ((${#bundles[@]} > 1)); then
        arch="AntiChat-$ver.zip"
        rm -f "$dir/$base" "${dir:?}/${base%.dmg}.html"
        [[ -f "$dir/$arch" ]] && rm -f "$dir/appcast.xml"
        ditto -c -k --sequesterRsrc --keepParent "$m/AntiChat.app" "$dir/$arch"
        base="$arch"
    else
        if [[ -f "$dir/$base" ]] && ! cmp -s "$dmg" "$dir/$base"; then rm -f "$dir/appcast.xml"; fi
        cp -f "$dmg" "$dir/$base"
    fi
    hdiutil detach -quiet "$m" 2>/dev/null || hdiutil detach -force -quiet "$m" 2>/dev/null || true
    rmdir "$m" 2>/dev/null || true
    if [[ -f "notes/$ver.md" ]]; then
        python3 -I - "notes/$ver.md" "$dir/${base%.*}.html" <<'PY'
import html, sys
lines = open(sys.argv[1]).read().splitlines()
out, in_list = [], False
for l in lines:
    if l.startswith("# "):
        continue  # the title is the sheet's own heading
    if l.startswith("- "):
        if not in_list: out.append("<ul>"); in_list = True
        out.append(f"<li>{html.escape(l[2:].strip())}</li>")
    else:
        if in_list: out.append("</ul>"); in_list = False
        if l.strip(): out.append(f"<p>{html.escape(l.strip())}</p>")
if in_list: out.append("</ul>")
open(sys.argv[2], "w").write("\n".join(out) + "\n")
PY
    fi
done
# Keep the newest 3 archives (deltas are made against them).
ls -t "$dir"/*.dmg "$dir"/*.zip 2>/dev/null | tail -n +4 | while read -r old; do rm -f "$old" "${old%.*}.html"; done

phased=(--phased-rollout-interval 86400)
[[ "${NO_PHASED:-0}" == 1 ]] && phased=()
"$bin/generate_appcast" --ed-key-file "$key" --download-url-prefix "$prefix" --embed-release-notes \
    --maximum-deltas 2 ${phased[@]+"${phased[@]}"} "$dir"
post=(--notes-dir notes --keep-urls "$prev"); [[ "${NO_PHASED:-0}" == 1 ]] && post+=(--no-phased)
python3 -I tools/release/appcast-post.py "$dir/appcast.xml" "${post[@]}"
"$bin/sign_update" --ed-key-file "$key" "$dir/appcast.xml" >/dev/null
mkdir -p "$out"
cp "$dir/appcast.xml" "$out/$name"
lint=(--key "$key" --archives "$dir" --sparkle-bin "$bin")
[[ "$feed" == stable ]] && lint+=(--production)
[[ "${NO_PHASED:-0}" == 1 ]] && lint+=(--test-feed)
python3 -I tools/release/appcast-lint.py "$out/$name" "${lint[@]}"
echo "appcast: $out/$name ($feed feed, $(ls "$dir"/*.dmg | wc -l | tr -d ' ') archive(s)); not published"
