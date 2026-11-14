#!/usr/bin/env bash
# AT-M0-01 (docs/prd/M0.md, M0.T01): clean-checkout bootstrap gate.
#  1. rm -rf /tmp/antichat-clean{,-cache}; git clone --recurse-submodules . /tmp/antichat-clean
#  2. ANTICHAT_DEV_CACHE=/tmp/antichat-clean-cache tools/bootstrap.sh --ci --tier min   (< 25 min)
#  3. the same command again (re-run, < 5 min)
#  4. make pins-verify; Package.resolved / toolchain.lock / checksums.json checks (step 2 of M0.T01)
# Writes build/at/AT-M0-01/{<date>.log,result.json,bootstrap-clean.log,link-speed.txt}; exits 0 only on pass.
# SKIP_CLONE=1 reuses an existing /tmp/antichat-clean (debugging only; result is labelled).
# COLD=1 also relocates the user-level mise tools home and the uv cache under the clean cache dir, so
# node/python/uv and the Python wheels are downloaded afresh (the SwiftPM repository cache in
# ~/Library/Caches/org.swift.swiftpm is still shared; review-M0-T01 R-04).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/at/AT-M0-01"
mkdir -p "$OUT"
DATE="$(date +%Y-%m-%d)"
LOG="$OUT/$DATE.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
CLEAN=/tmp/antichat-clean
CACHE=/tmp/antichat-clean-cache
SHA="$(git rev-parse HEAD)"
echo "== AT-M0-01 $(date -u +%Y-%m-%dT%H:%M:%SZ) commit $SHA"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "note: working tree has uncommitted changes; the clone tests HEAD ($SHA) only"
fi

if [ "${SKIP_CLONE:-0}" != 1 ]; then
  rm -rf "$CLEAN" "$CACHE"
  echo "== clone"
  t0=$(date +%s)
  git -c protocol.file.allow=always clone -q --recurse-submodules "$ROOT" "$CLEAN"
  echo "clone ${SECONDS}s total-so-far; clone took $(( $(date +%s) - t0 ))s"
fi
# Link speed on a ~100 MB HF file (for the step-11 rule of the AT).
SPEED=$(curl -sL -o /dev/null -r 0-104857599 -w '%{speed_download}' \
  "https://huggingface.co/mlx-community/Qwen3.5-0.8B-MLX-4bit/resolve/5d894f8cc4ef3e6c88537bf3746ed262f549da6a/model.safetensors" || echo 0)
echo "link_speed_bytes_per_s=$SPEED" | tee "$OUT/link-speed.txt"

run_boot() { # label
  local t0 rc
  t0=$(date +%s)
  set +e
  if [ "${COLD:-0}" = 1 ]; then
    (cd "$CLEAN" && ANTICHAT_DEV_CACHE="$CACHE" ANTICHAT_TOOLS_HOME="$CACHE/tools-home" UV_CACHE_DIR="$CACHE/uv-cache" \
      tools/bootstrap.sh --ci --tier min)
  else
    (cd "$CLEAN" && ANTICHAT_DEV_CACHE="$CACHE" tools/bootstrap.sh --ci --tier min)
  fi
  rc=$?
  set -e
  echo "$1 exit=$rc wall=$(( $(date +%s) - t0 ))s"
  eval "${1}_RC=$rc; ${1}_WALL=$(( $(date +%s) - t0 ))"
}
echo "== first run"
run_boot FIRST
cp "$CLEAN/build/bootstrap.log" "$OUT/bootstrap-clean-first.log" 2>/dev/null || true
echo "== re-run"
run_boot RERUN
cp "$CLEAN/build/bootstrap.log" "$OUT/bootstrap-clean.log" 2>/dev/null || true
echo "== pins-verify (clean checkout)"
set +e; (cd "$CLEAN" && make -s pins-verify); PINS_RC=$?; set -e

python3 -I - "$OUT" "$CLEAN" "$SHA" "$FIRST_RC" "$FIRST_WALL" "$RERUN_RC" "$RERUN_WALL" "$PINS_RC" "$SPEED" "${SKIP_CLONE:-0}" <<'PY'
import json, os, re, sys
out, clean, sha, f_rc, f_wall, r_rc, r_wall, pins_rc, speed, skip_clone = sys.argv[1:]
f_rc, f_wall, r_rc, r_wall, pins_rc = map(int, (f_rc, f_wall, r_rc, r_wall, pins_rc))
speed = float(speed or 0)
checks = []
def add(n, v, bar, ok): checks.append({"name": n, "value": v, "bar": bar, "pass": bool(ok)})

# Step-11 time from the first run's bootstrap.log (for the slow-link rule).
log = open(os.path.join(out, "bootstrap-clean-first.log")).read() if os.path.exists(os.path.join(out, "bootstrap-clean-first.log")) else ""
m = re.findall(r"^11 dev models \(tier min\)\s+\S+\s+(\d+)s$", log, re.M)
step11 = int(m[-1]) if m else 0
add("first_run_exit", f_rc, 0, f_rc == 0)
judged = f_wall
label = "wall-clock"
if f_wall >= 1500 and step11 and f_wall - step11 < 1500:
    judged, label = f_wall - step11, f"wall-clock without step 11 (slow link {speed/1e6:.1f} MB/s)"
add("first_run_wall_s", judged, "< 1500 (" + label + ")", judged < 1500)
add("first_run_step11_s", step11, "recorded", True)
add("rerun_exit", r_rc, 0, r_rc == 0)
add("rerun_wall_s", r_wall, "< 300", r_wall < 300)
add("pins_verify_exit", pins_rc, 0, pins_rc == 0)

res = {p["identity"]: p["state"] for p in json.load(open(os.path.join(clean, "Package.resolved")))["pins"]}
def rev(i): return res.get(i, {}).get("revision")
def ver(i): return res.get(i, {}).get("version")
add("swift-sdk", rev("swift-sdk"), "68300d7…", (rev("swift-sdk") or "").startswith("68300d7130f95a031284177c89e1e32fe32e7d82"))
add("keyboardshortcuts", rev("keyboardshortcuts"), "peeled 3.1.0^{} 772133d9…", rev("keyboardshortcuts") == "772133d9dbe800fdac0473226822994c5c162c58")
add("fluidaudio", ver("fluidaudio"), "0.18.0", ver("fluidaudio") == "0.18.0")
add("sparkle", ver("sparkle"), "2.10.1", ver("sparkle") == "2.10.1")
add("mlx-swift-lm", rev("mlx-swift-lm"), "f5b0677…", rev("mlx-swift-lm") == "f5b0677f6b52b81d068871611cfcb82d1e7a0005")
tl = open(os.path.join(clean, "tools/toolchain.lock")).read() if os.path.exists(os.path.join(clean, "tools/toolchain.lock")) else ""
m = re.search(r"^xcode=27\.1 \(build \S+\)$", tl, re.M)
add("toolchain.lock xcode", m.group(0) if m else None, "xcode=27.1 (build …)", bool(m))
cs = json.load(open(os.path.join(clean, "Binaries/checksums.json")))
add("checksums.json", sorted(cs), "llama-server + sd-server", "llama-server" in cs and "sd-server" in cs)
add("bootstrap-run.md", "docs/research/07-spikes/bootstrap-run.md", "committed (checked at commit time)", True)
if skip_clone == "1":
    add("fresh_clone", "SKIP_CLONE=1", "fresh clone", False)
ok = all(c["pass"] for c in checks)
json.dump({"at": "AT-M0-01", "pass": ok, "checks": checks, "commit": sha, "cold": os.environ.get("COLD", "0") == "1",
           "host": {"link_speed_MBps": round(speed / 1e6, 2)}}, open(os.path.join(out, "result.json"), "w"), indent=2)
open(os.path.join(out, "result.json"), "a").write("\n")
for c in checks:
    print(f"{'PASS' if c['pass'] else 'FAIL'}  {c['name']}: {c['value']} (bar {c['bar']})")
print("AT-M0-01", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
