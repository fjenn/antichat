#!/usr/bin/env bash
# Stage + verify the upstream helper binaries (llama-server, sd-server, sd-cli) against Binaries/checksums.json.
# Called by `make build` / `make build-release` / the test targets before xcodebuild (integration M1 W2+T12):
# a checkout's build/binaries/ can hold an older build (e.g. from before the A-M0-07 portable flags) that the
# Xcode "Copy Helpers" phase would otherwise embed silently. For each binary whose sha256 differs from
# checksums.json, the matching file is restaged from the shared build cache ($ANTICHAT_DEV_CACHE/binaries/*/,
# filled by `make binaries`); with no match it fails and asks for `make binaries`.
#   tools/binaries/stage.sh            restage if needed, then verify (exit 20 on a mismatch that cannot be fixed)
#   tools/binaries/stage.sh --verify   verify only (the Xcode phase uses this, it cannot write build/binaries)
#   tools/binaries/stage.sh --verify-dir <dir>   verify the copies in <dir> (the app's Contents/Helpers)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="${ANTICHAT_DEV_CACHE:-$HOME/Library/Caches/AntiChat-dev}/binaries"
mode=stage dir="$ROOT/build/binaries"
case "${1:-}" in
  --verify) mode=verify ;;
  --verify-dir) mode=verify; dir="${2:?--verify-dir needs a directory}" ;;
  "") ;;
  *) echo "usage: $0 [--verify | --verify-dir <dir>]" >&2; exit 64 ;;
esac
exec python3 -I - "$ROOT/Binaries/checksums.json" "$dir" "$CACHE" "$mode" <<'PY'
import glob, hashlib, json, os, shutil, sys
checksums, out, cache, mode = sys.argv[1:5]
want = json.load(open(checksums))
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
    return h.hexdigest()
bad = 0
for name in ("llama-server", "sd-server", "sd-cli"):
    exp = want[name]["sha256"]
    dst = os.path.join(out, name)
    have = sha(dst) if os.path.isfile(dst) else None
    if have == exp:
        print(f"[ok] {name} sha256 matches checksums.json"); continue
    if mode == "stage":
        src = next((c for c in sorted(glob.glob(os.path.join(cache, "*", name)))
                    if os.path.getsize(c) == want[name].get("size", os.path.getsize(c)) and sha(c) == exp), None)
        if src:
            os.makedirs(out, exist_ok=True)
            tmp = f"{dst}.tmp.{os.getpid()}"
            shutil.copy2(src, tmp); os.chmod(tmp, 0o755); os.replace(tmp, dst)
            print(f"[fix] {name}: restaged from {src} (was {have or 'missing'})"); continue
    print(f"error: {dst} sha256 {have or 'missing'} != checksums.json {exp} "
          f"({'run make binaries' if mode == 'stage' else 'run tools/binaries/stage.sh or make binaries'})")
    bad += 1
sys.exit(20 if bad else 0)
PY
