#!/bin/bash
# tools/release/key-ceremony.sh — the production key ceremony (M10.T04 step 4; R-305 AC2; ci-release §6.1).
# THE OWNER RUNS THIS (docs/prd/M10-owner-steps.md). Agents only run --dry-run.
#
#   tools/release/key-ceremony.sh --out /Volumes/<encrypted USB>/antichat-keys   (Wi-Fi off, see KEYS.md)
#   tools/release/key-ceremony.sh --dry-run                                       (temp dir, repo untouched)
#
# Generates four Ed25519 keys with `catalog-tool keygen` (CryptoKit, no Keychain, no network): sparkle-primary,
# sparkle-backup, catalog-a, catalog-b. Private seeds (*.priv, base64, the format `sign_update --ed-key-file`
# reads) go ONLY to --out; public keys go into Config/Keys.release.plist (SparklePublicEDKey, …Backup,
# CatalogPublicKeyA/B), then PinnedKeys.swift is regenerated and --release-ready must pass. Writes a ceremony
# log without secrets (fingerprints, date) to --out/ceremony-log.txt and tools/release/keys-ceremony-log.md.
# Refuses an --out inside the repository or on a volume that is not encrypted (diskutil: FileVault/Encrypted).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$ROOT"
out="" dry=0
while (($# > 0)); do
    case "$1" in
        --out) out="$2"; shift 2 ;;
        --dry-run) dry=1; shift ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown argument $1" >&2; exit 2 ;;
    esac
done
work_root="$ROOT"
if ((dry)); then
    out="$(mktemp -d "${TMPDIR:-/tmp}/antichat-ceremony-dry.XXXXXX")"
    work_root="$out/repo"; mkdir -p "$work_root/Config" "$work_root/catalog/test-keys" "$work_root/Packages/Platform/Sources/AntiChatPlatform/Catalog"
    cp Config/Keys.dev.plist Config/Keys.release.plist "$work_root/Config/"; cp catalog/test-keys/FINGERPRINTS "$work_root/catalog/test-keys/"
    trap 'rm -r "$out"' EXIT   # throwaway keys never outlive the dry run
    echo "key-ceremony: DRY RUN in $out (repo untouched; removed on exit)"
else
    [[ -n "$out" ]] || { echo "error: --out /Volumes/<encrypted volume>/antichat-keys is required" >&2; exit 2; }
    mkdir -p "$out"; out="$(cd "$out" && pwd -P)"
    [[ "$out" != "$ROOT" && "$out" != "$ROOT"/* ]] || { echo "error: --out must not be inside the repository" >&2; exit 1; }
    mnt="$(df "$out" | tail -n 1 | awk '{print $NF}')"
    enc="$(diskutil info "$mnt" 2>/dev/null | grep -E 'FileVault|Encrypted' | grep -c -i yes || true)"
    [[ "$enc" -gt 0 ]] || { echo "error: $out is not on an encrypted volume (diskutil info: FileVault/Encrypted)" >&2; exit 1; }
    for f in sparkle-primary sparkle-backup catalog-a catalog-b; do
        [[ ! -e "$out/$f.priv" ]] || { echo "error: $out/$f.priv exists; never overwrite a key" >&2; exit 1; }
    done
fi
umask 077
for f in sparkle-primary sparkle-backup catalog-a catalog-b; do
    swift run --disable-keychain --force-resolved-versions -q catalog-tool keygen --out "$out/$f" >/dev/null
done
pub() { head -n 1 "$out/$1.pub"; }
plist="$work_root/Config/Keys.release.plist"
/usr/libexec/PlistBuddy -c "Set :SparklePublicEDKey $(pub sparkle-primary)" -c "Set :SparklePublicEDKeyBackup $(pub sparkle-backup)" \
    -c "Set :CatalogPublicKeyA $(pub catalog-a)" -c "Set :CatalogPublicKeyB $(pub catalog-b)" "$plist"
python3 -I tools/release/gen-keys-swift.py --root "$work_root" >/dev/null
python3 -I tools/release/gen-keys-swift.py --root "$work_root" --release-ready
log="$(date -u +%FT%TZ) key ceremony$( ((dry)) && echo ' (DRY RUN)')
  sparkle-primary  $(pub sparkle-primary)
  sparkle-backup   $(pub sparkle-backup)
  catalog-a        $(pub catalog-a)
  catalog-b        $(pub catalog-b)
  private seeds: $out (copy to the second encrypted volume + paper; never into the repo or CI except key A + Sparkle primary as release-environment secrets)"
printf '%s\n' "$log" > "$out/ceremony-log.txt"
if ((dry)); then
    echo "$log"; echo "key-ceremony: dry run ok; nothing in the repo changed"
else
    printf '\n```\n%s\n```\n' "$log" >> tools/release/keys-ceremony-log.md
    echo "$log"
    echo "key-ceremony: done. Next (KEYS.md §After): copy $out to the second encrypted volume, write the paper copy, commit Config/Keys.release.plist + PinnedKeys.swift + keys-ceremony-log.md."
fi
