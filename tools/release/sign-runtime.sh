#!/bin/bash
# Ported from beeware/briefcase@0bdaaf5fd6:src/briefcase/platforms/macOS/__init__.py (BSD-3-Clause, (c) Russell
# Keith-Magee; licence text in ACKNOWLEDGMENTS.md): `sign_file` (l.794) and `sign_app` (l.846), default
# entitlements l.464-467. M6.T16 step 1 (P-files-tools-09); generic for every downloadable runtime component
# (D-026: M5.T01's video-runtime signs through this script too, as a thin wrapper).
# AntiChat changes (see "ANTICHAT:" comments):
#   - a runtime TREE or ZIP instead of an .app; a zip is unzipped, signed and re-zipped deterministically
#     (fixed mtimes, sorted entries, zip -X; byte-reproducible because ad-hoc signatures are deterministic);
#   - Mach-O detection by magic instead of Briefcase's `file`-free extension list + `codesign` probe;
#   - entitlements only on executables (MH_EXECUTE); dylibs/.so get none (Briefcase signs every file with the
#     app's entitlements); framework bundles are sealed after their contents (Briefcase sign_app order);
#   - modes adhoc | dev | devid like tools/release/sign.sh (identity "-" for adhoc, --timestamp=none);
#   - --update-catalog rewrites the sha256 / size_bytes / signature_mode of the entry in catalog/runtimes.yaml.
#
# Usage:
#   tools/release/sign-runtime.sh <runtime-dir | runtime.zip> <entitlements.plist> [--mode adhoc|dev|devid]
#       [--identity ID] [--out signed.zip] [--report FILE] [--update-catalog catalog/runtimes.yaml --name NAME]
#   A zip is signed in place unless --out is given. A directory is signed in place (no zip).
# Env: CODE_SIGN_IDENTITY (dev/devid identity, instead of --identity), ADHOC_LV_EXEMPT=0 to drop the ad-hoc-only
#      library-validation exemption.
set -euo pipefail

fail() { echo "sign-runtime: error: $*" >&2; exit 1; }
log() { echo "sign-runtime: $*"; }

target="" entitlements="" mode=adhoc identity="${CODE_SIGN_IDENTITY:-}" out="" report="" catalog="" name=""
while (($# > 0)); do
    case "$1" in
        --mode) mode="$2"; shift 2 ;;
        --identity) identity="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        --report) report="$2"; shift 2 ;;
        --update-catalog) catalog="$2"; shift 2 ;;
        --name) name="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
        --*) fail "unknown option: $1" ;;
        *) if [[ -z "$target" ]]; then target="$1"; elif [[ -z "$entitlements" ]]; then entitlements="$1"; else fail "extra argument: $1"; fi; shift ;;
    esac
done
[[ -n "$target" && -n "$entitlements" ]] || fail "usage: sign-runtime.sh <runtime-dir|zip> <entitlements.plist> [options]"
[[ -e "$target" ]] || fail "not found: $target"
[[ -f "$entitlements" ]] || fail "entitlements not found: $entitlements"
plutil -lint "$entitlements" >/dev/null || fail "invalid plist: $entitlements"
entitlements="$(cd "$(dirname "$entitlements")" && pwd -P)/$(basename "$entitlements")"
[[ -z "$catalog" || -n "$name" ]] || fail "--update-catalog needs --name"

case "$mode" in
    adhoc) identity="-"; timestamp=(--timestamp=none) ;;
    dev) [[ -n "$identity" ]] || fail "dev mode needs --identity or CODE_SIGN_IDENTITY"; timestamp=(--timestamp=none) ;;
    devid) [[ -n "$identity" ]] || fail "devid mode needs --identity or CODE_SIGN_IDENTITY"; timestamp=(--timestamp) ;;
    *) fail "unknown mode: $mode (adhoc|dev|devid)" ;;
esac

work="$(mktemp -d "${TMPDIR:-/tmp}/antichat-sign-runtime.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# ANTICHAT: ad-hoc mode only, merge tools/release/entitlements/adhoc-extra.plist (cs.disable-library-validation;
# A-M0-T12a, same rule as sign.sh): an ad-hoc signature has no Team ID, so library validation under the hardened
# runtime refuses the runtime's own ad-hoc Python.framework ("mapping process and mapped file (non-platform) have
# different Team IDs", S-files-sandbox). dev/devid signatures share a Team ID and never get the key.
extra="$(cd "$(dirname "$0")" && pwd -P)/entitlements/adhoc-extra.plist"
if [[ "$mode" == adhoc && "${ADHOC_LV_EXEMPT:-1}" != 0 && -f "$extra" ]]; then
    merged="$work/$(basename "$entitlements" .plist)+adhoc-extra.plist"
    cp "$entitlements" "$merged"
    for key in $(plutil -convert json -o - "$extra" | python3 -I -c 'import json,sys; print("\n".join(json.load(sys.stdin)))'); do
        /usr/libexec/PlistBuddy -c "Delete :$key" "$merged" >/dev/null 2>&1 || true
        /usr/libexec/PlistBuddy -c "Add :$key bool true" "$merged" >/dev/null
    done
    plutil -lint "$merged" >/dev/null || fail "merged entitlements invalid"
    entitlements="$merged"
fi
zip_in=""
if [[ -f "$target" ]]; then
    zip_in="$(cd "$(dirname "$target")" && pwd -P)/$(basename "$target")"
    tree="$work/tree"
    mkdir -p "$tree"
    ditto -x -k "$zip_in" "$tree"  # keeps symlinks and modes
else
    tree="$(cd "$target" && pwd -P)"
fi
[[ -n "$report" ]] && { mkdir -p "$(dirname "$report")"; printf '# sign-runtime.sh --mode %s %s (%s)\n' "$mode" "$target" "$(date -u +%FT%TZ)" >> "$report"; }
report_line() { [[ -z "$report" ]] || printf '%s\t%s\n' "${1#"$tree"/}" "$2" >> "$report"; }

# ANTICHAT: Mach-O by magic (thin 32/64-bit either endianness, or FAT), one python pass over the tree; prints
# "<kind>\t<depth>\t<path>" with kind = exe | lib, deepest first (Briefcase signs leaves before their containers).
list_macho() {
    python3 -I - "$1" <<'PY'
import os, struct, sys
root = sys.argv[1]
THIN = {b"\xcf\xfa\xed\xfe": "<", b"\xce\xfa\xed\xfe": "<", b"\xfe\xed\xfa\xcf": ">", b"\xfe\xed\xfa\xce": ">"}
FAT = (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf")
rows = []
for d, _dirs, names in os.walk(root):
    for n in names:
        p = os.path.join(d, n)
        if os.path.islink(p):
            continue
        with open(p, "rb") as f:
            head = f.read(16)
        if len(head) < 16:
            continue
        magic = head[:4]
        if magic in FAT:
            if not 0 < struct.unpack(">I", head[4:8])[0] < 8:
                continue  # Java class files share the FAT magic
            with open(p, "rb") as f:
                f.seek(8)
                off = struct.unpack(">IIIII", f.read(20))[2]
                f.seek(off)
                head = f.read(16)
                magic = head[:4]
        if magic not in THIN:
            continue
        filetype = struct.unpack(THIN[magic] + "I", head[12:16])[0]
        rows.append(("exe" if filetype == 2 else "lib", p.count(os.sep), p))
for kind, depth, p in sorted(rows, key=lambda r: (-r[1], r[2])):
    print(f"{kind}\t{depth}\t{p}")
PY
}

sign_one() {  # sign_one <path> <entitlements|none>
    local args=(--force --sign "$identity" --options runtime "${timestamp[@]}")
    [[ "$2" == none ]] || args+=(--entitlements "$2")
    codesign --remove-signature "$1" 2>/dev/null || true  # wheels ship stray signatures (Briefcase strips too)
    codesign "${args[@]}" "$1" 2>"$work/codesign.err" || { cat "$work/codesign.err" >&2; fail "codesign failed: $1"; }
    report_line "$1" "$([[ "$2" == none ]] && echo none || basename "$2")"
}

count=0 exe=0
while IFS=$'\t' read -r kind _depth path; do
    [[ -n "$path" ]] || continue
    if [[ "$kind" == exe ]]; then sign_one "$path" "$entitlements"; exe=$((exe + 1)); else sign_one "$path" none; fi
    count=$((count + 1))
done < <(list_macho "$tree")
((count > 0)) || fail "no Mach-O files under $tree"
((exe > 0)) || fail "no executable under $tree (nothing carries the entitlements)"

# Framework bundles after their contents (Briefcase sign_app: "sign the framework, then the app").
while IFS= read -r version_dir; do
    [[ -n "$version_dir" ]] || continue
    codesign --force --sign "$identity" --options runtime "${timestamp[@]}" "$version_dir" 2>"$work/codesign.err" \
        || { cat "$work/codesign.err" >&2; fail "codesign failed: $version_dir"; }
    report_line "$version_dir" "bundle"
done < <(find "$tree" -type d -path '*.framework/Versions/*' -prune -not -name Current | LC_ALL=C sort)

# Verify: every Mach-O strictly, every framework bundle deep + strict.
failed=0
while IFS=$'\t' read -r _kind _depth path; do
    [[ -n "$path" ]] || continue
    codesign --verify --strict "$path" 2>>"$work/verify.err" || { echo "verify failed: $path" >&2; failed=$((failed + 1)); }
done < <(list_macho "$tree")
while IFS= read -r version_dir; do
    [[ -n "$version_dir" ]] || continue
    codesign --verify --strict --deep -vv "$version_dir" 2>>"$work/verify.err" || { echo "verify failed: $version_dir" >&2; failed=$((failed + 1)); }
done < <(find "$tree" -type d -path '*.framework/Versions/*' -prune -not -name Current | LC_ALL=C sort)
[[ -z "$report" ]] || { sed "s#$tree/##g" "$work/verify.err" >> "$report"; }
((failed == 0)) || { cat "$work/verify.err" >&2; fail "$failed signatures failed codesign --verify --strict"; }
log "signed and verified $count Mach-O files ($exe executables with $(basename "$entitlements")), mode $mode"

if [[ -n "$zip_in" ]]; then
    dest="${out:-$zip_in}"
    case "$dest" in /*) ;; *) dest="$PWD/$dest" ;; esac
    find "$tree" -exec touch -h -t 202601010000 {} +
    rm -f "$work/out.zip"
    (cd "$tree" && find . \( -type f -o -type l \) | LC_ALL=C sort | zip -X -y -q -9 -@ "$work/out.zip")
    mv -f "$work/out.zip" "$dest"
    sha="$(shasum -a 256 "$dest" | cut -d' ' -f1)"
    size="$(stat -f %z "$dest")"
    log "zip $dest sha256 $sha size $size"
    [[ -z "$report" ]] || printf '# zip %s sha256 %s size %s\n' "$(basename "$dest")" "$sha" "$size" >> "$report"
    if [[ -n "$catalog" ]]; then
        python3 -I - "$catalog" "$name" "$sha" "$size" "$mode" <<'PY'
import re, sys
path, name, sha, size, mode = sys.argv[1:6]
text = open(path).read()
# One entry = "- name: <name>" up to the next "- name:" or EOF; rewrite its three signed-artefact fields only.
m = re.search(rf"(?ms)^(\s*)- name: {re.escape(name)}\s*$.*?(?=^\s*- name: |\Z)", text)
if not m:
    sys.exit(f"sign-runtime: {name} not in {path}")
block = m.group(0)
for key, val in (("sha256", sha), ("size_bytes", size), ("signature_mode", mode)):
    block, n = re.subn(rf"(?m)^(\s*){key}:.*$", rf"\g<1>{key}: {val}", block)
    if n != 1:
        sys.exit(f"sign-runtime: {name}: field {key} missing in {path}")
open(path, "w").write(text[:m.start()] + block + text[m.end():])
print(f"sign-runtime: updated {name} in {path}")
PY
    fi
fi
