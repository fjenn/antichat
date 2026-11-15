#!/bin/bash
# tools/release/package-dmg.sh — `make dmg` (M10.T02; ci-release §5; R-225 AC1, NFR-D1).
#   1. dmgbuild (pinned, tools/release/requirements.lock; build/release-venv) packs build/release/AntiChat.app with
#      the Applications link, icon positions (180,200)/(480,200), 660×452 window (660×420 content) and the HiDPI
#      background.tiff into a read-write image; its background bookmark is made absolute (fix-background-bookmark.py)
#      and it is converted to build/release/AntiChat-Installer-<ver>[-LABEL].dmg (APFS, ULFO). LABEL = build/release/LABEL.
#   2. dev/devid: codesign the DMG (devid with a secure timestamp); adhoc DMGs stay unsigned (meaningless).
#   3. NFR-D1 size gate: ≤ 314,572,800 bytes, 0 model files inside (attached read-only, -nobrowse).
#   4. devid + NOTARIZE=1: notarize.sh --dmg (submit, staple, validate); a failed DMG is deleted.
#   5. tools/release/verify-dmg.sh (layout, symlink, background, signature/staple) → build/at/AT-225/.
# Env: SIGNING_MODE (default: build/release/build.json's mode), NOTARIZE (default 1), OUT (build/release).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$ROOT"
source tools/release/lib/identity.sh
out="${OUT:-build/release}"
app="$out/AntiChat.app"
[[ -d "$app" && -f "$out/build.json" ]] || { echo "error: $app missing; run make build-release first" >&2; exit 1; }
built_mode="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["signing_mode"])' "$out/build.json")"
mode="${SIGNING_MODE:-$built_mode}"
[[ "$mode" == "$built_mode" ]] || { echo "error: SIGNING_MODE=$mode but the app was built as $built_mode" >&2; exit 1; }
version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
label="$(cat "$out/LABEL" 2>/dev/null || true)"
dmg="$out/AntiChat-Installer-$version${label:+-$label}.dmg"
venv="build/release-venv"
if [[ ! -x "$venv/bin/dmgbuild" ]]; then
    uv venv -q --python 3.13 "$venv"
    uv pip install -q --python "$venv/bin/python" --require-hashes -r tools/release/requirements.lock
fi

echo "== dmg [$mode] $dmg"
rm -f "$out"/AntiChat-*.dmg
# dmgbuild writes a read-write image first: its background bookmark is volume-relative, which Finder cannot resolve
# (the window opened plain white; M10 VQ). fix-background-bookmark.py makes it /Volumes/AntiChat Installer/.background.tiff,
# then the image is converted to ULFO (ci-release §5).
rw="$out/AntiChat-rw.dmg"
rm -f "$rw"
"$venv/bin/dmgbuild" -s tools/release/dmg/settings.py -D app="$app" -D background=tools/release/dmg/background.tiff \
    -D icon=tools/release/dmg/VolumeIcon.icns -D format=UDRW \
    "AntiChat Installer" "$rw"
rwmnt="$(mktemp -d "${TMPDIR:-/tmp}/antichat-dmgrw.XXXXXX")"
hdiutil attach -nobrowse -noautoopen -mountpoint "$rwmnt" "$rw" >/dev/null
"$venv/bin/python" -I tools/release/dmg/fix-background-bookmark.py "$rwmnt/.DS_Store" \
    || { hdiutil detach -force -quiet "$rwmnt"; rm -f "$rw"; exit 1; }
hdiutil detach -quiet "$rwmnt" || hdiutil detach -force -quiet "$rwmnt"
rmdir "$rwmnt" 2>/dev/null || true
hdiutil convert -quiet "$rw" -format ULFO -o "$dmg"
rm -f "$rw"

if [[ "$mode" != adhoc ]]; then
    identity_resolve "$mode"
    codesign --force --sign "$IDENTITY" "$TS_ARG" "$dmg"
    codesign --verify --strict --verbose=2 "$dmg"
fi

size="$(stat -f %z "$dmg")"
mnt="$(mktemp -d "${TMPDIR:-/tmp}/antichat-dmg.XXXXXX")"
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$dmg" >/dev/null
models="$(find "$mnt" \( -name '*.gguf' -o -name '*.safetensors' \) | wc -l | tr -d ' ')"
hdiutil detach -quiet "$mnt" || hdiutil detach -force -quiet "$mnt"
rmdir "$mnt" 2>/dev/null || true
mkdir -p build/at/AT-NFR-D1
printf '%s\t%s\tbytes=%s\tlimit=314572800\tmodel_files=%s\n' "$(date -u +%FT%TZ)" "$(basename "$dmg")" "$size" "$models" \
    >> build/at/AT-NFR-D1/sizes.tsv
if ((size > 314572800)) || [[ "$models" != 0 ]]; then
    echo "error: NFR-D1 gate: $size bytes, $models model files" >&2; rm -f "$dmg"; exit 1
fi
echo "  NFR-D1: $size bytes ($(( size / 1048576 )) MB) ≤ 300 MB, 0 model files"

if [[ "$mode" == devid && "${NOTARIZE:-1}" == 1 ]]; then
    tools/release/notarize.sh --mode devid --out "$out/notary" --dmg "$dmg" || { rm -f "$dmg"; exit 1; }
fi
tools/release/verify-dmg.sh --mode "$mode" "$dmg"
