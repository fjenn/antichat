#!/usr/bin/env bash
# AT-M0-07 (M0.T07; selection §9 S-10): `make m0-gate AT=AT-M0-07`.
#  1. builds the video runtime (`make runtime-video` + ad-hoc inside-out signing), zips it, unzips it to
#     build/runtimes/video-runtime-unzipped/ (the path AT-M0-12 re-signs) and verifies every Mach-O
#     (`codesign --verify --strict`) before and after the zip round trip → codesign.txt;
#  2. torch-free parity of the driver (tests/test_parity.py, dev venv with torch; optional: PARITY_PY);
#  3. runs the Release app's `-Bench video` through the real XPC path: T2V 480p × 3 at the T3-48 cap (VID1, VID2,
#     R1), T2V 720p × 3 (S2–S4 default), one I2V clip via sd-cli, one cancel run — all on the UNZIPPED runtime;
#  4. scales VID1/VID2 with tools/perf/vid-scale.py and evaluates the pass conditions → result.json.
# Clips go to build/at/AT-M0-07/out/ only (hashes in the log; nothing is shown in a UI, M0 safety floor).
# Env: SKIP_BENCH=1 (evaluate existing raw rows), NO_BUILD=1 (reuse build/dd-bench + runtime), RUNS (3),
#      SKIP_720=1, PARITY_PY=<python with torch+transformers+diffusers+mlx>, INIT_IMAGE (default fixtures/images/
#      photos-cc0/019.jpg, "Lake Superior in early April", CC0, no people).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT=build/at/AT-M0-07
RAWD=build/perf/raw
mkdir -p "$OUT/out" "$RAWD"
DATE="$(date +%Y-%m-%d)"
LOG="$OUT/$DATE.log"
exec > >(tee -a "$LOG") 2>&1
echo "== AT-M0-07 $(date -u +%FT%TZ) commit $(git rev-parse --short HEAD)"
RUNS="${RUNS:-3}"
LOCK=/tmp/antichat-gpu.lock
APP=build/dd-bench/Build/Products/Release/AntiChat.app
BIN="$APP/Contents/MacOS/AntiChat"
MODELS="${ANTICHAT_DEV_CACHE:+$ANTICHAT_DEV_CACHE/Models}"
MODELS="${MODELS:-$HOME/Library/Application Support/AntiChat-Dev/Models}"
RT_UNZ=build/runtimes/video-runtime-unzipped
TAEHV_PTH_SHA=d053e216ca50e2bb837bbcd79b85f0366bea00e5938025572382a773b74c559a
TAEHV_SHA=b84609b2a133d48434bd9636bfcb44bf05168dc436e2d3cecf26256faa1f5325

# ---- models (C6): vid-5b, vid-i2v, vid-te via hf-fetch. TAEHV taew2_2 ("Lingonberry Tart", madebyollin/taehv, MIT):
# FastVideo@d9e6c3e pins `taew2_2.pth` @563f40b (sha256 d053e2...); its safetensors twin was only refreshed in the next
# commit fa579a9 ("Update safetensors (oops)") - @563f40b the .safetensors is the OLD TAEW2.2. The runtime and sd-cli
# `--taesd` load `safetensors/taew2_2.safetensors@fa579a9`; the parity check proves it equals the pinned .pth.
python3 -I tools/dev/hf-fetch.py --set m0-t07
mkdir -p "$MODELS/vid-taehv"
TAEHV_URL=https://raw.githubusercontent.com/madebyollin/taehv
fetch_pinned() {  # fetch_pinned <url> <dest> <sha256>
  [ -f "$2" ] && [ "$(shasum -a 256 "$2" | cut -d' ' -f1)" = "$3" ] && return 0
  curl -fsSL -o "$2.part" "$1" && mv "$2.part" "$2"
  [ "$(shasum -a 256 "$2" | cut -d' ' -f1)" = "$3" ] || { echo "[fail] sha256 $2"; exit 20; }
}
fetch_pinned "$TAEHV_URL/fa579a9a726b0a55951998d73e309bfdf0abd342/safetensors/taew2_2.safetensors" "$MODELS/vid-taehv/taew2_2.safetensors" "$TAEHV_SHA"
fetch_pinned "$TAEHV_URL/563f40bdc820ed86bcad72ea515ee48f06bd22ec/taew2_2.pth" "$MODELS/vid-taehv/taew2_2.pth" "$TAEHV_PTH_SHA"

# ---- 1. runtime build + signing + zip round trip
if [ "${NO_BUILD:-0}" != 1 ] || [ ! -x "$RT_UNZ/video-runtime/bin/python3" ]; then
  : > "$OUT/codesign.txt"
  python3 -I Runtimes/video-runtime/build.py --sign --codesign-report "$OUT/codesign.txt"
  rm -rf "$RT_UNZ" && mkdir -p "$RT_UNZ"
  ditto -x -k build/runtimes/video-runtime-0.1.0.zip "$RT_UNZ"
  python3 -I - "$RT_UNZ/video-runtime" "$OUT/codesign.txt" <<'PY'
import sys, importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location("b", "Runtimes/video-runtime/build.py")
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
n, bad = b.verify(Path(sys.argv[1]), Path(sys.argv[2]))
print(f"[..] after zip round trip: {n - bad}/{n} Mach-O verify --strict ok")
sys.exit(1 if bad else 0)
PY
fi
cat build/runtimes/video-runtime-size.json
PY_RT="$RT_UNZ/video-runtime/bin/python3"


# ---- 2. parity (dev-only torch venv)
if [ -n "${PARITY_PY:-}" ]; then
  lockf "$LOCK" "$PARITY_PY" -I Packages/Engines/Python/tests/test_parity.py --model "$MODELS/vid-5b" \
    --taehv-pth "$MODELS/vid-taehv/taew2_2.pth" --taehv "$MODELS/vid-taehv/taew2_2.safetensors" --out "$OUT/parity.json"
fi

# ---- 3. bench (app → XPC → helper → child)
if [ "${SKIP_BENCH:-0}" != 1 ]; then
  if [ "${NO_BUILD:-0}" != 1 ] || [ ! -x "$BIN" ]; then
    xcodebuild -workspace AntiChat.xcworkspace -scheme AntiChat-Release -configuration Release -derivedDataPath build/dd-bench ARCHS=arm64 'GCC_PREPROCESSOR_DEFINITIONS=$(inherited) NDEBUG=1' \
      -disableAutomaticPackageResolution -packageAuthorizationProvider netrc CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ANTICHAT_PERF_HARNESS' build -quiet  # -Bench is not in a release build (tools/ci/dev-modes-guard.py)
  fi
  test -x "$APP/Contents/Helpers/sd-cli" || { echo "[fail] sd-cli not bundled"; exit 1; }
  echo "[..] bundled sd-cli sha256 $(shasum -a 256 "$APP/Contents/Helpers/sd-cli" | cut -c1-64)"
  rm -f "$OUT"/out/*.mp4 "$OUT/events.jsonl"
  run() {  # run <raw-name> <bench args…>
    local raw="$RAWD/$1.jsonl"; shift
    lockf "$LOCK" "$BIN" -Bench video "$@" --runtime "$ROOT/$RT_UNZ/video-runtime" --out-dir "$ROOT/$OUT/out" \
      --raw "$raw" --events "$ROOT/$OUT/events-$(basename "$raw" .jsonl).jsonl"
  }
  run video-t2v-480p --mode t2v --res 480p --frames 73 --runs "$RUNS" --tier-cap T3-48
  [ "${SKIP_720:-0}" = 1 ] || run video-t2v-720p --mode t2v --res 720p --frames 81 --runs "$RUNS" --tier-cap T3-48
  run video-i2v-480p --mode i2v --res 480p --frames 73 --steps 20 --runs 1 --tier-cap T3-48 \
    --init-image "${INIT_IMAGE:-$ROOT/fixtures/images/photos-cc0/019.jpg}"
  run video-t2v-cancel --mode t2v --res 480p --frames 73 --runs 1 --tier-cap T3-48 --cancel-at-step 1
  cat "$OUT"/events-video-*.jsonl > "$OUT/events.jsonl"
fi

echo "== output hashes (clips are not displayed; M0 safety floor)"
for f in "$OUT"/out/*.mp4; do [ -f "$f" ] && echo "$(shasum -a 256 "$f" | cut -c1-64)  $(basename "$f") $(stat -f %z "$f") B"; done
python3 -I tools/perf/vid-scale.py --raw-dir "$RAWD" --report build/perf/report.json $([ "${REPLACE:-0}" = 1 ] && echo --replace) > "$OUT/scale.log"
cat "$OUT/scale.log"

python3 -I - "$OUT" "$RAWD" "$(git rev-parse HEAD)" <<'PY'
import json, os, platform, re, subprocess, sys
out, rawd, commit = sys.argv[1:4]
rep = json.load(open("build/perf/report.json"))
def rows(name):
    p = os.path.join(rawd, name + ".jsonl")
    return [json.loads(l) for l in open(p) if l.strip()] if os.path.exists(p) else []
checks = []
def add(name, value, bar, ok):
    checks.append({"name": name, "value": value, "bar": bar, "pass": bool(ok)})

t2v = [r for r in rows("video-t2v-480p") if r.get("run", -1) >= 0]
ok = [r for r in t2v if r.get("status") == "completed" and r.get("out_width") == 832 and r.get("out_height") == 480
      and r.get("out_frames") == r.get("frames") and r.get("mp4_bytes", 0) > 0]
add("T2V 480p clip produced at the T3-48 cap (MP4, 832×480, all frames)", f"{len(ok)}/{len(t2v)}", "n = 3, all", len(t2v) >= 3 and len(ok) == len(t2v))
steps_ok = [r for r in t2v if r.get("step_events", 0) >= r.get("h_total_steps", 99) > 0 and r.get("preview_events", 0) >= 1]
add(">= 1 progress event per sampler step and >= 1 preview frame (every T2V run)",
    [f"{r.get('step_events')}/{int(r.get('h_total_steps', 0))} steps, {r.get('preview_events')} previews" for r in t2v], "steps == total, previews >= 1",
    t2v and len(steps_ok) == len(t2v))
peak = max([r.get("peak_footprint_bytes", 0) for r in t2v], default=0)
add("peak footprint (app + helper + video child) <= B(T3-48)", round(peak / 1e9, 3), "<= 36 GB", t2v and peak <= 36e9)
k = "m0.VID1.S4.vid-5b-480p"
v = rep.get(k)
scaled = sorted(x.split("@")[-1] for x in rep if x.startswith(k + "@"))
add("NFR-VID1 measured (n = 3) and [SCALED] to S1–S3", v and {"p50_s": round(v["p50"], 2), "p95_s": round(v["p95"], 2), "n": v["n"], "scaled_to": scaled},
    "n >= 3; chips of S1, S2, S3", v is not None and v["n"] >= 3 and {"M1", "M4", "M4 Pro", "M5", "M4 Max"} <= set(scaled))
i2v = [r for r in rows("video-i2v-480p") if r.get("run", -1) >= 0]
iok = [r for r in i2v if r.get("status") == "completed" and r.get("mp4_bytes", 0) > 0 and r.get("step_events", 0) >= r.get("h_total_steps", 99) > 0]
add("one I2V clip via sd.cpp (sd-cli vid_gen) with progress events", [{"final_s": round(r.get("final_s", -1), 1), "steps": r.get("step_events"), "frames": r.get("out_frames")} for r in i2v],
    ">= 1 clip, step events == --steps", len(iok) >= 1)
cs = open(os.path.join(out, "codesign.txt")).read() if os.path.exists(os.path.join(out, "codesign.txt")) else ""
heads = re.findall(r"# codesign --verify --strict: (\S+) \((\d+) Mach-O, (\d+) failed\)", cs)
after = [h for h in heads if "unzipped" in h[0]]
add("every Mach-O in the runtime zip passes codesign --verify --strict (ad-hoc) after a zip round trip",
    [{"tree": h[0], "macho": int(h[1]), "failed": int(h[2])} for h in heads], "0 failed, after unzip",
    after and all(int(h[2]) == 0 and int(h[1]) > 0 for h in heads))
size = json.load(open("build/runtimes/video-runtime-size.json")) if os.path.exists("build/runtimes/video-runtime-size.json") else None
add("runtime size recorded", size, "zip + tree bytes", size is not None and size.get("zip_bytes", 0) > 0)
# Informational (not in the PRD pass list): parity, VID2, cancel, 720p.
par = json.load(open(os.path.join(out, "parity.json"))) if os.path.exists(os.path.join(out, "parity.json")) else None
info = {"parity_pass": par and par.get("pass"), "umt5_cosine_min": par and par.get("umt5_cosine_min")}
for kk in ("m0.VID2.S4.vid-5b-480p", "m0.VID1.S4.vid-5b-720p", "m0.VID2.S4.vid-5b-720p", "m0.VID1.S4.vid-i2v-480p"):
    if kk in rep:
        info[kk] = {"p50": round(rep[kk]["p50"], 2), "n": rep[kk]["n"], "target": rep[kk].get("target"), "pass": rep[kk].get("pass")}
cx = [r for r in rows("video-t2v-cancel") if r.get("run", -1) >= 0]
info["cancel"] = [{"status": r.get("status"), "cancel_sent_s": round(r.get("cancel_sent_s", -1), 2),
                   "final_s": round(r.get("final_s", -1), 2), "child_alive_after": r.get("child_alive_after")} for r in cx]
host = {"machine": platform.machine(), "macos": platform.mac_ver()[0],
        "chip": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()}
res = {"at": "AT-M0-07", "pass": all(c["pass"] for c in checks), "checks": checks, "info": info, "commit": commit, "host": host}
json.dump(res, open(os.path.join(out, "result.json"), "w"), indent=2)
for c in checks:
    print(("[ok]  " if c["pass"] else "[FAIL]") + f" {c['name']}: {c['value']} (bar {c['bar']})")
print("info:", json.dumps(info))
print("AT-M0-07 pass =", res["pass"])
sys.exit(0 if res["pass"] else 1)
PY
