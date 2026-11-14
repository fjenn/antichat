#!/bin/bash
# M5.T01 step 5 (D-026): thin wrapper over tools/release/sign-runtime.sh (M6.T16, the generic runtime signer).
# Signs build/runtimes/video-runtime-<ver>.zip inside-out (every Mach-O, hardened runtime; the executables —
# python3.12 and video-runtime-launcher — get tools/release/entitlements/video-runtime.plist: allow-unsigned-
# executable-memory + disable-library-validation, ci-release §2.3 / S-10), re-zips deterministically into
# build/runtimes/signed/, writes sha256 / size_bytes / signature_mode into catalog/runtimes.yaml (name video-runtime),
# copies the zip to site/public/runtimes/ (served by `make site-dev` until M10 hosting) and verifies the unzipped
# tree with `codesign --verify --deep --strict`.
# Usage: tools/runtime/sign_video_runtime.sh [--mode adhoc|dev|devid]   (default: $SIGNING_MODE or adhoc)
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
mode="${SIGNING_MODE:-adhoc}"
[[ "${1:-}" == "--mode" ]] && mode="$2"
ver="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$root/build/runtimes/video-runtime/RUNTIME.json")"
zip="video-runtime-$ver.zip"
day="$(date -u +%F)"
report="$root/build/at/M5.T01/$day/signing.log"
mkdir -p "$root/build/runtimes/signed" "$root/site/public/runtimes" "$(dirname "$report")"
: > "$report"
"$root/tools/release/sign-runtime.sh" "$root/build/runtimes/$zip" "$root/tools/release/entitlements/video-runtime.plist" \
    --mode "$mode" --out "$root/build/runtimes/signed/$zip" --report "$report" \
    --update-catalog "$root/catalog/runtimes.yaml" --name video-runtime
cp "$root/build/runtimes/signed/$zip" "$root/site/public/runtimes/$zip"
# The signed tree as installed: unzip and verify deep + strict (the task check).
check="$root/build/runtimes/video-runtime-signed"
rm -rf "$check" && mkdir -p "$check" && ditto -x -k "$root/build/runtimes/signed/$zip" "$check"
n=0; bad=0
while IFS= read -r -d '' f; do
    if head -c 4 "$f" | xxd -p | grep -qE '^(cffaedfe|feedfacf|cafebabe|bebafeca)$'; then
        n=$((n + 1))
        codesign --verify --strict "$f" 2>>"$report" || { bad=$((bad + 1)); echo "FAIL $f" >> "$report"; }
    fi
done < <(find "$check" -type f -print0)
codesign --verify --deep --strict "$check/bin/video-runtime-launcher" "$check/bin/python3.12" 2>>"$report" || bad=$((bad + 1))
echo "# codesign --verify --strict on the unzipped signed tree: $n Mach-O, $bad failed" | tee -a "$report"
[[ $bad -eq 0 ]]
