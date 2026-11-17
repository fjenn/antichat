#!/usr/bin/env bash
# Fetch the helper binaries (llama-server, sd-server, sd-cli) from the "build inputs" prerelease of the public
# repository instead of rebuilding them (.github/workflows/release.yml). The prerelease holds the exact files whose
# sha256 is recorded in Binaries/checksums.json (the same files every DMG ships); each download is verified against
# checksums.json and the step fails closed on any mismatch. Why not rebuild: sd-server/sd-cli did not reproduce
# bit-for-bit on the GitHub runner (run 44174414767: Ninja + Homebrew cmake 4.4.5 there; Unix Makefiles + cmake 4.4.4
# where the checksums were recorded).
#   tools/binaries/fetch-release.sh --tag            print the release tag for the current checksums.json
#   tools/binaries/fetch-release.sh [REPO]           download into build/binaries/ and verify
# Exit: 0 verified; 3 the release or one of its assets does not exist (caller may build from source);
#       20 a downloaded file does not match checksums.json (never fall back: fail).
# Upload (owner, once per checksums.json change), from a checkout whose build/binaries/ match:
#   tag="$(tools/binaries/fetch-release.sh --tag)"; tools/binaries/stage.sh --verify &&
#   gh release create "$tag" -R fjenn/antichat --prerelease --latest=false --target main \
#     --title "Build inputs — not an app release ($tag)" --notes "..." build/binaries/{llama-server,sd-server,sd-cli}
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
NAMES=(llama-server sd-server sd-cli)

# helper-binaries-<llama.cpp sha8>-<sd.cpp sha8>-<sha8 of the three recorded sha256>: content-addressed, so a new
# checksums.json never matches an old release.
tag="$(python3 -I - Binaries/checksums.json <<'PY'
import hashlib, json, sys
d = json.load(open(sys.argv[1]))
names = ("llama-server", "sd-server", "sd-cli")
key = hashlib.sha256("".join(f"{n} {d[n]['sha256']}\n" for n in names).encode()).hexdigest()[:8]
print(f"helper-binaries-{d['llama-server']['submodule_sha'][:8]}-{d['sd-server']['submodule_sha'][:8]}-{key}")
PY
)"
if [[ "${1:-}" == --tag ]]; then echo "$tag"; exit 0; fi
repo="${1:-${GITHUB_REPOSITORY:-fjenn/antichat}}"

tmp="$ROOT/build/binaries-download"
rm -rf "$tmp"; mkdir -p "$tmp"
have="$(gh release view "$tag" -R "$repo" --json assets -q '.assets[].name' 2>/dev/null || true)"
for n in "${NAMES[@]}"; do
  grep -qx "$n" <<< "$have" || { echo "[miss] $repo release $tag has no asset $n"; rm -rf "$tmp"; exit 3; }
done
args=(); for n in "${NAMES[@]}"; do args+=(-p "$n"); done
gh release download "$tag" -R "$repo" "${args[@]}" -D "$tmp" --clobber

# Verify before anything lands in build/binaries/.
python3 -I - Binaries/checksums.json "$tmp" <<'PY' || { rm -rf "$tmp"; exit 20; }
import hashlib, json, os, sys
want, d = json.load(open(sys.argv[1])), sys.argv[2]
bad = 0
for n in ("llama-server", "sd-server", "sd-cli"):
    p = os.path.join(d, n)
    h = hashlib.sha256(open(p, "rb").read()).hexdigest()
    if h == want[n]["sha256"] and os.path.getsize(p) == want[n]["size"]:
        print(f"[ok] {n} sha256 {h} matches checksums.json")
    else:
        print(f"::error::{n}: downloaded sha256 {h} != checksums.json {want[n]['sha256']}"); bad += 1
sys.exit(1 if bad else 0)
PY
mkdir -p build/binaries
for n in "${NAMES[@]}"; do chmod 755 "$tmp/$n"; mv -f "$tmp/$n" "build/binaries/$n"; done
rm -rf "$tmp"
echo "[ok] helper binaries from release $tag"
