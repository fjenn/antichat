#!/bin/bash
# tools/release/package-dmg.sh — `make dmg` (M10.T02; ci-release §5; R-225 AC1, NFR-D1).
#   1. dmgbuild (pinned, tools/release/requirements.lock; build/release-venv) packs build/release/AntiChat.app with
#      the Applications link, icon positions (180,200)/(480,200), 660×452 window (660×420 content) and the HiDPI
#      background.tiff into a read-write image; its background bookmark is made absolute (fix-background-bookmark.py)
#      and it becomes build/release/AntiChat-Installer-<ver>[-LABEL].dmg (APFS, read-write UDRW, AntiChat.app
#      decmpfs-compressed, shrunk to fit: the drop-to-install target needs a writable volume). LABEL = build/release/LABEL.
#   2. the DMG itself is not signed (raw image: a signature would be xattrs, stripped by any download).
#   3. NFR-D1 size gate: ≤ 314,572,800 bytes, 0 model files inside (attached read-only, -nobrowse).
#   4. devid + NOTARIZE=1: the drop target is notarized + stapled (the app already is, by build-release).
#   5. tools/release/verify-dmg.sh (layout, drop target, background, signature/staple) → build/at/AT-225/.
# The Applications icon is tools/release/dmg/dropinstall (built + signed here, Apple's folder icon set on the rw image):
# dropping AntiChat on it copies it to /Applications, opens it and ejects the installer.
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
# A mounted "AntiChat Installer" makes the new volume "AntiChat Installer 1", and the background bookmark would point
# there (a blank window for users): eject every mounted installer volume first.
for v in /Volumes/AntiChat\ Installer*; do [[ -d "$v" ]] && { echo "  ejecting $v"; hdiutil detach -quiet "$v" || hdiutil detach -force -quiet "$v"; }; done
if [[ "$mode" != adhoc ]]; then identity_resolve "$mode"; fi
installer="$(tools/release/dmg/dropinstall/build.sh ${IDENTITY:+"$IDENTITY"} | tail -1)"
# The DMG is a raw read-write image: its own signature would live in xattrs that a download strips, so it is neither
# signed nor notarized. Everything that runs inside it carries its own stapled ticket instead: the app (build-release)
# and this drop target (notarized + stapled here, before its custom icon is set on the image).
if [[ "$mode" == devid && "${NOTARIZE:-1}" == 1 ]]; then
    tools/release/notarize.sh --mode devid --out "$out/notary" --app "$installer"
fi
rw="$out/AntiChat-rw.dmg"
rm -f "$rw"
"$venv/bin/dmgbuild" -s tools/release/dmg/settings.py -D app="$app" -D installer="$installer" \
    -D background=tools/release/dmg/background.tiff \
    -D icon=tools/release/dmg/VolumeIcon.icns -D format=UDRW \
    "AntiChat Installer" "$rw"
# Room to re-copy AntiChat.app compressed beside the original (below); the image is shrunk to fit afterwards.
hdiutil resize -quiet -size "$(( $(du -sm "$app" | cut -f1) * 2 + 200 ))m" "$rw"
rwmnt="$(mktemp -d "${TMPDIR:-/tmp}/antichat-dmgrw.XXXXXX")"
hdiutil attach -nobrowse -noautoopen -mountpoint "$rwmnt" "$rw" >/dev/null
"$venv/bin/python" -I tools/release/dmg/fix-background-bookmark.py "$rwmnt/.DS_Store" \
    || { hdiutil detach -force -quiet "$rwmnt"; rm -f "$rw"; exit 1; }
"$out/dropinstall/set-icon" /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns \
    "$rwmnt/Applications.app" || { hdiutil detach -force -quiet "$rwmnt"; rm -f "$rw"; exit 1; }
codesign --verify "$rwmnt/Applications.app"
# The image stays read-write (Finder refuses a drop onto an app on a read-only volume, so a ULFO/UDZO installer's
# Applications target would not take AntiChat). To keep the download small, AntiChat.app is stored with APFS
# transparent compression (decmpfs; ditto --hfsCompression) and the image is shrunk to its contents.
ditto --hfsCompression "$app" "$rwmnt/.AntiChat-compressed.app"
rm -rf "$rwmnt/AntiChat.app"
mv "$rwmnt/.AntiChat-compressed.app" "$rwmnt/AntiChat.app"
codesign --verify --deep --strict "$rwmnt/AntiChat.app"
hdiutil detach -quiet "$rwmnt" || hdiutil detach -force -quiet "$rwmnt"
rmdir "$rwmnt" 2>/dev/null || true
hdiutil resize -quiet -sectors min "$rw"
mv "$rw" "$dmg"


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

tools/release/verify-dmg.sh --mode "$mode" "$dmg"
