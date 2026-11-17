#!/usr/bin/env bash
# AT-M0-06 (M0.T06; selection §9 S-5): `make m0-gate AT=AT-M0-06`.
# Runs M0.T06 steps 4–7 through the Release app's `-Bench image|handoff|coresident|cancel` (real XPC path,
# helper-owned sd-server child, one-GPU-job lock), scales P1/P2 with tools/perf/sd-scale.py and evaluates the
# pass conditions into build/at/AT-M0-06/result.json. Images go to build/at/AT-M0-06/out/ only (hashes in the
# log; never shown in a UI before ChildSafetyCheck exists, M0.md safety-floor note).
# Env: SKIP_BENCH=1 (evaluate existing raw runs), NO_BUILD=1 (reuse build/dd-bench), RUNS (20), RUNS_T2 (10),
#      RUNS_CANCEL (10), PROMPTS (default fixtures/images/prompts-50.json, else generated into build/fixtures-t06).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT=build/at/AT-M0-06
RAWD=build/perf/raw
mkdir -p "$OUT/out" "$RAWD"
DATE="$(date +%Y-%m-%d)"
LOG="$OUT/$DATE.log"
exec > >(tee -a "$LOG") 2>&1
echo "== AT-M0-06 $(date -u +%FT%TZ) commit $(git rev-parse --short HEAD)"
RUNS="${RUNS:-20}"; RUNS_T2="${RUNS_T2:-10}"; RUNS_CANCEL="${RUNS_CANCEL:-10}"
LOCK=/tmp/antichat-gpu.lock
APP=build/dd-bench/Build/Products/Release/AntiChat.app
BIN="$APP/Contents/MacOS/AntiChat"

PROMPTS="${PROMPTS:-fixtures/images/prompts-50.json}"
if [ ! -f "$PROMPTS" ]; then
  # Q-013: this worktree cannot initialise the fixtures submodule; the generator is the source of truth.
  python3 -I tools/fixtures/make-image-prompts.py --out build/fixtures-t06/images/prompts-50.json
  PROMPTS=build/fixtures-t06/images/prompts-50.json
fi
echo "[..] prompts: $PROMPTS sha256 $(shasum -a 256 "$PROMPTS" | cut -c1-16)"

if [ "${SKIP_BENCH:-0}" != 1 ]; then
  if [ "${NO_BUILD:-0}" != 1 ] || [ ! -x "$BIN" ]; then
    xcodebuild -workspace AntiChat.xcworkspace -scheme AntiChat-Release -configuration Release -derivedDataPath build/dd-bench ARCHS=arm64 'GCC_PREPROCESSOR_DEFINITIONS=$(inherited) NDEBUG=1' \
      -disableAutomaticPackageResolution -packageAuthorizationProvider netrc CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ANTICHAT_PERF_HARNESS' build -quiet  # -Bench is not in a release build (tools/ci/dev-modes-guard.py)
  fi
  test -x "$APP/Contents/Helpers/sd-server" || { echo "[fail] sd-server not bundled"; exit 1; }
  echo "[..] bundled sd-server sha256 $(shasum -a 256 "$APP/Contents/Helpers/sd-server" | cut -c1-64)"
  rm -f "$OUT"/out/*.png
  run() {  # run <raw-name> <bench args…>
    local raw="$RAWD/$1.jsonl"; shift
    lockf "$LOCK" "$BIN" -Bench "$@" --prompts "$ROOT/$PROMPTS" --out-dir "$ROOT/$OUT/out" --raw "$raw"
  }
  # Step 4: P1/P2 at the S1/S2 default (768²) and the S3/S4 default (1024²), T1 set (Q4) and T2 set (Q8).
  run image-q4-768  image --quant q4 --res 768  --runs "$RUNS"
  run image-q4-1024 image --quant q4 --res 1024 --runs "$RUNS"
  run image-q8-1024 image --quant q8 --res 1024 --runs "$RUNS"
  # Step 5: handoff at the T1 cap (chat-9b-q4 + klein Q4 set at 768², the T1/S1 default).
  run handoff-T1 handoff --tier-cap T1 --model chat-9b-q4 --quant q4 --res 768 --runs "$RUNS"
  # Step 6: no eviction at the T2-24 cap (chat-9b-q4 + klein Q8 set at 1024², this Mac's S4 default).
  run coresident-T2-24 coresident --tier-cap T2-24 --model chat-9b-q4 --quant q8 --res 1024 --runs "$RUNS_T2"
  # Step 7: cancel at step 2 of a 1024² job.
  run cancel-q4-1024 cancel --quant q4 --res 1024 --runs "$RUNS_CANCEL" --cancel-step 2
fi

echo "== output hashes (images are not displayed; M0 safety floor)"
for f in "$OUT"/out/*.png; do [ -f "$f" ] && echo "$(shasum -a 256 "$f" | cut -c1-64)  $(basename "$f")"; done
python3 -I tools/perf/sd-scale.py --raw-dir "$RAWD" --report build/perf/report.json $([ "${REPLACE:-0}" = 1 ] && echo --replace) --csv "$OUT/handoff.csv" > "$OUT/scale.log"
cat "$OUT/scale.log"

python3 -I - "$OUT" "$RAWD" "$(git rev-parse HEAD)" <<'PY'
import json, os, platform, statistics, subprocess, sys
out, rawd, commit = sys.argv[1:4]
rep = json.load(open("build/perf/report.json"))
B = {"T1": 9.5e9, "T2-24": 16e9}
def rows(name):
    p = os.path.join(rawd, name + ".jsonl")
    return [json.loads(l) for l in open(p) if l.strip()] if os.path.exists(p) else []
checks = []
def add(name, value, bar, ok):
    checks.append({"name": name, "value": value, "bar": bar, "pass": bool(ok)})

# 1. P1 / P2 recorded (n = 20) at 768² and 1024², measured on S4 and [SCALED] to S1–S3.
for q, res in (("q4", 768), ("q4", 1024), ("q8", 1024)):
    for m in ("P1", "P2"):
        k = f"m0.{m}.S4.img-klein-{q}-{res}"
        v = rep.get(k)
        scaled = sorted(x.split("@")[-1] for x in rep if x.startswith(k + "@"))
        add(f"{m} recorded {q} {res}² (S4 measured + [SCALED] S1–S3)",
            v and {"p50": round(v["p50"], 3), "p95": round(v["p95"], 3), "n": v["n"], "scaled_to": scaled},
            "n >= 20, scaled to >= 3 chips", v is not None and v["n"] >= 20 and len(scaled) >= 3)

# 2. Handoff at the T1 cap.
h = [r for r in rows("handoff-T1") if r.get("run", -1) >= 0]
ev = [r for r in h if r.get("evicted")]
def p50(xs):  # nfr.md "Statistics": linear interpolation (= median); xs[n // 2] was the upper median for even n
    xs = sorted(x for x in xs if x is not None and x >= 0)
    return statistics.median(xs) if xs else None
un = p50([r.get("unload_s") for r in ev])
rl = p50([r.get("queued_chat_first_token_s") for r in h])
add("T1: chat model evicted for the image (runs)", f"{len(ev)}/{len(h)}", f"{len(h)}/{len(h)} (n = 20)", len(h) >= 20 and len(ev) == len(h))
add("T1: LLM unload p50 (evict call → footprint < B − image set)", un, "<= 1 s", un is not None and un <= 1)
add("T1: reload → first token of the queued chat, p50 (NFR-M1, ≤ 6 GB weights)", rl, "<= 3 s", rl is not None and rl <= 3)
ans = [r for r in h if r.get("queued_chat_answered")]
queued = [r for r in h if "loading" in str(r.get("queued_chat_load_states", ""))]
add("T1: chat request sent during the reload is queued (not rejected) and answered",
    {"answered": f"{len(ans)}/{len(h)}", "saw_loading_state": f"{len(queued)}/{len(h)}"}, "all", len(h) >= 20 and len(ans) == len(h))
# 3. No eviction at the T2-24 cap.
c = [r for r in rows("coresident-T2-24") if r.get("run", -1) >= 0]
kept = [r for r in c if not r.get("evicted") and r.get("container_unchanged") and not r.get("next_chat_reloaded")]
ttft = p50([r.get("next_chat_ttft_s") for r in c])
add("T2-24: chat model not evicted, container identity unchanged, no reload", f"{len(kept)}/{len(c)}", "10/10", len(c) >= 10 and len(kept) == len(c))
add("T2-24: next chat TTFT p50 within NFR-C1", ttft, "<= 1.5 s", ttft is not None and ttft <= 1.5)
# 4. Preview on every step + cancel.
allimg = [r for n in ("image-q4-768", "image-q4-1024", "image-q8-1024", "handoff-T1", "coresident-T2-24") for r in rows(n) if r.get("run", -1) >= 0 and r.get("status") == "completed"]
full = [r for r in allimg if r.get("preview_count") == r.get("steps") and r.get("h_previews") == r.get("steps")]
add("preview callback fires on every step (count = steps) in every completed job", f"{len(full)}/{len(allimg)}", "all", allimg and len(full) == len(allimg))
cx = [r for r in rows("cancel-q4-1024") if r.get("run", -1) >= 0]
cok = [r for r in cx if r.get("status") == "cancelled" and r.get("h_steps_after_cancel", 9) <= 1 and 0 <= r.get("h_cancel_mem_recover_s", -1) <= 2]
add("cancel at step 2 of 1024²: stops <= 1 step later, sd-server memory back to idle <= 2 s",
    {"ok": f"{len(cok)}/{len(cx)}", "stop_s_p50": p50([r.get("h_cancel_to_stopped_s") for r in cx]),
     "mem_recover_s_max": max([r.get("h_cancel_mem_recover_s", -1) for r in cx], default=None)}, "10/10", len(cx) >= 10 and len(cok) == len(cx))
# 5. NFR-R1 in every capped run.
for name, tier in (("handoff-T1", "T1"), ("coresident-T2-24", "T2-24")):
    rr = [r for r in rows(name) if r.get("run", -1) >= 0]
    over = [r["run"] for r in rr if r.get("peak_footprint_bytes", 0) > B[tier]]
    add(f"R1 peak footprint (app + helper + sd-server) <= B in every {tier} run",
        {"max_gb": round(max([r.get("peak_footprint_bytes", 0) for r in rr], default=0) / 1e9, 3), "over": over}, f"<= {B[tier]/1e9} GB", rr and not over)

host = {"machine": platform.machine(), "macos": platform.mac_ver()[0],
        "chip": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()}
res = {"at": "AT-M0-06", "pass": all(c["pass"] for c in checks), "checks": checks, "commit": commit, "host": host}
json.dump(res, open(os.path.join(out, "result.json"), "w"), indent=2)
for c in checks:
    print(("[ok]  " if c["pass"] else "[FAIL]") + f" {c['name']}: {c['value']} (bar {c['bar']})")
print("AT-M0-06 pass =", res["pass"])
sys.exit(0 if res["pass"] else 1)
PY
