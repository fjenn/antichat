#!/bin/bash
# tools/release/verify-dmg.sh — AT-225 AC1 (layout) + AC4 (D-014 plist key) + NFR-D1 on a built DMG (M10.T02).
# Read-only: attaches the image read-only and hidden (-nobrowse; never opens Finder, never launches the app).
# Checks: volume name "AntiChat Installer"; AntiChat.app + the Applications drop target (Applications.app: the
# installer helper, Apple folder custom icon, valid signature, devid: our team); the background TIFF with
# 660×420 and 1320×840 representations, referenced by the .DS_Store bookmark (/Volumes/AntiChat Installer/<file>) and alias;
# .DS_Store icon positions (180,200)/(480,200), window 660×452 (420 content), icon size 128;
# LSMinimumSystemVersion 26.0; size ≤ 300 MB; devid: AntiChat.app and the drop target each stapled and accepted by
# Gatekeeper (`spctl -a -t exec`) as Notarized Developer ID (the raw read-write DMG itself carries no signature).
# Usage: tools/release/verify-dmg.sh [--mode adhoc|dev|devid] DMG    Evidence: build/at/AT-225/verify-<date>.log
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
mode="${SIGNING_MODE:-adhoc}"
[[ "${1:-}" == --mode ]] && { mode="$2"; shift 2; }
dmg="$1"
[[ -f "$dmg" ]] || { echo "usage: $0 [--mode m] DMG" >&2; exit 2; }
mkdir -p "$ROOT/build/at/AT-225"
log="$ROOT/build/at/AT-225/verify-$(date +%Y%m%d-%H%M%S).log"
fails=0
ok() { echo "[ok]   $*" | tee -a "$log"; }
bad() { echo "[FAIL] $*" | tee -a "$log"; fails=$((fails + 1)); }
echo "# verify-dmg $dmg mode=$mode $(date -u +%FT%TZ)" > "$log"

mnt="$(mktemp -d "${TMPDIR:-/tmp}/antichat-vdmg.XXXXXX")"
cleanup() { hdiutil detach -quiet "$mnt" 2>/dev/null || hdiutil detach -force -quiet "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; }
trap cleanup EXIT
info="$(hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$dmg" -plist)"
vol="$(hdiutil imageinfo "$dmg" 2>/dev/null | sed -n 's/^ *Format: //p' | head -n 1)"
name="$(diskutil info "$mnt" | sed -n 's/^ *Volume Name: *//p')"
[[ "$name" == "AntiChat Installer" ]] && ok "volume name AntiChat Installer (format ${vol:-?})" || bad "volume name '$name'"
[[ -d "$mnt/AntiChat.app" ]] && ok "AntiChat.app present" || bad "AntiChat.app missing"
[[ -f "$mnt/.VolumeIcon.icns" ]] && ok "volume icon .VolumeIcon.icns present" || bad "volume icon missing"
drop="$mnt/Applications.app"
if [[ -d "$drop" ]] && [[ "$(plutil -extract CFBundleIdentifier raw -o - "$drop/Contents/Info.plist")" == app.antichat.Installer ]]; then
    ok "Applications drop target (app.antichat.Installer) present"
    [[ -f "$drop/Icon"$'\r' ]] && ok "drop target wears the Applications folder custom icon" || bad "drop target custom icon missing"
    codesign --verify "$drop" 2>>"$log" && ok "drop target signature valid" || bad "drop target signature"
    if [[ "$mode" == devid ]]; then
        [[ "$(codesign -dvv "$drop" 2>&1)" == *TeamIdentifier=446XT9839S* ]] && ok "drop target signed by team 446XT9839S" || bad "drop target team"
    fi
else bad "Applications drop target missing"; fi
extra="$(ls -A "$mnt" | grep -v -E '^(AntiChat.app|Applications.app|\.background|\.background\.tiff|\.VolumeIcon\.icns|\.DS_Store|\.fseventsd|\.Trashes)$' || true)"
[[ -z "$extra" ]] && ok "no other items" || bad "unexpected items: $extra"
# dmgbuild stores it as /.background.tiff (create-dmg used .background/background.tiff; A-M10-T02a).
tiff="$mnt/.background.tiff"; [[ -f "$tiff" ]] || tiff="$mnt/.background/background.tiff"
if [[ -f "$tiff" ]]; then
    dims="$(tiffutil -info "$tiff" | sed -n 's/.*Image Width: \([0-9]*\) Image Length: \([0-9]*\).*/\1x\2/p' | sort | tr '\n' ' ')"
    [[ "$dims" == "1320x840 660x420 " ]] && ok "background.tiff representations: $dims" || bad "background.tiff representations: $dims"
else bad "background TIFF missing"; fi
layout="$("$ROOT/build/release-venv/bin/python" -I "$ROOT/tools/release/dsstore-read.py" "$mnt/.DS_Store")"
echo "# layout $layout" >> "$log"
python3 -I - "$layout" <<'PY' && ok "Finder layout: icons (180,200)/(480,200), window 660×452 (420 content), icon 128" || bad "Finder layout: $layout"
import json, sys
d = json.loads(sys.argv[1])
assert d["icons"].get("AntiChat.app") == [180, 200], d
assert d["icons"].get("Applications.app") == [480, 200], d
w = d["window"]; assert w and w[2:] == [660, 452], d
assert d["icon_size"] == 128, d
PY
# The background must be referenced the way Finder resolves it (M10 VQ: a volume-relative bookmark drew a plain white
# window while the file and the layout were present): picture type (2); the bookmark (pBBk) path is
# /Volumes/<volume name>/<file> and that file is in the image; the legacy alias names the same file.
python3 -I - "$layout" "$mnt" <<'PY' && ok "background referenced: picture, bookmark + alias → a file in the image" \
    || bad "background not referenced as Finder resolves it: $layout"
import json, os, sys
d, mnt = json.loads(sys.argv[1]), sys.argv[2]
assert d["background"] == 2, "backgroundType is not picture"
bm, vol = d["background_bookmark"], d["background_bookmark_volume"]
assert bm and vol == "/Volumes/AntiChat Installer", f"bookmark volume {vol}"
assert bm.startswith(vol + "/"), f"bookmark path {bm} is not under {vol} (volume-relative?)"
rel = bm[len(vol) + 1:]
assert os.path.isfile(os.path.join(mnt, rel)), f"bookmark target {rel} not in the image"
assert d["background_alias"] and d["background_alias"].lstrip("/") == rel, f"alias {d['background_alias']} != {rel}"
PY
# The app as a user copies it out: no extended attributes on the bundle root (Finder info would fail strict
# verification), and the signature verifies strictly (M10.T09 AT-FA-01).
[[ -z "$(xattr "$mnt/AntiChat.app" | grep -v -x com.apple.provenance || true)" ]] && ok "no Finder info / xattrs on AntiChat.app" \
    || bad "xattrs on AntiChat.app: $(xattr "$mnt/AntiChat.app" | tr '\n' ' ')"
if [[ "$mode" != adhoc ]]; then
    codesign --verify --deep --strict "$mnt/AntiChat.app" 2>>"$log" && ok "app inside the DMG verifies (--deep --strict)" \
        || bad "app inside the DMG fails codesign --verify --deep --strict"
fi
minos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$mnt/AntiChat.app/Contents/Info.plist")"
[[ "$minos" == 26.0 ]] && ok "LSMinimumSystemVersion 26.0 (AC4 per D-014)" || bad "LSMinimumSystemVersion $minos"
if [[ "$mode" == devid ]]; then
    for item in AntiChat.app Applications.app; do
        xcrun stapler validate "$mnt/$item" >/dev/null 2>&1 && ok "$item has a stapled ticket" || bad "$item not stapled"
        sp="$(spctl -a -vv -t exec "$mnt/$item" 2>&1 || true)"
        echo "$sp" >> "$log"
        [[ "$sp" == *accepted* && "$sp" == *"Notarized Developer ID"* ]] && ok "$item: Gatekeeper accepts (Notarized Developer ID)" \
            || bad "$item Gatekeeper: $sp"
    done
fi
cleanup; trap - EXIT

size="$(stat -f %z "$dmg")"
((size <= 314572800)) && ok "NFR-D1 size $size bytes ≤ 314572800" || bad "NFR-D1 size $size"
# The DMG itself is unsigned: a raw read-write image keeps a signature only in xattrs, which any download strips.
echo "verify-dmg: $([[ $fails == 0 ]] && echo pass || echo "$fails failure(s)") — $log"
((fails == 0))
