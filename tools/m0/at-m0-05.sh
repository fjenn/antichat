#!/usr/bin/env bash
# AT-M0-05: voice round-trip in the helper (docs/prd/M0.md M0.T05; S-9; K-022).
#   1. hf-fetch --set m0-t05 (stt, vad-files, turn, tts, chat-2b, chat-9b-q4, chat-35b-q4; pinned, ungated)
#   2. input mode: blackhole if the BlackHole 2ch driver is installed, else inject ([IN-PIPELINE], no P-ADMIN)
#   3. tools/bench.sh voice at T1 (chat-9b-q4) and T3-48 (chat-35b-q4), n = 20 each; T0 (chat-2b) for memory
#   4. Kokoro peak RSS vs B (T0 4.0, T1 9.5 GB); over B → rerun with SystemTTS (D-010) and record both
#   5. K-NEW-ENG-9: sw_vers; the automatic SystemTTS fallback is exercised with a simulated Kokoro failure
#   6. python3 -I tools/audio/rt-report.py → build/perf/report.json m0.V1.* / V1b / V2 / R1.voice, stages.csv
#   7. TCC (K-NEW-ARCH-5): tcc-prompt.png + tcc-settings.png (computer use, vq-00 part B) and the helper live
#      capture result (build/perf/raw/voice-*-live-*.jsonl, RMS > −60 dBFS) are checked if present
# Writes build/at/AT-M0-05/{<date>.log, result.json, stages.csv, rt-summary.json}. V1 vs NFR-V1 is reported,
# not gated (it drives the fallback). Env: FIXTURES (default fixtures), NO_BUILD=1, SKIP_RUNS=1 (report only).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/at/AT-M0-05"
mkdir -p "$OUT"
DATE="$(date +%Y-%m-%d)"
LOG="$OUT/$DATE.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
FIXTURES="${FIXTURES:-$ROOT/fixtures}"
INPUT="$FIXTURES/audio/librispeech-test-clean-200"
RUNS="${RUNS:-20}"

echo "== AT-M0-05 $(date -u +%Y-%m-%dT%H:%M:%SZ) commit $(git rev-parse --short HEAD 2>/dev/null || echo none)"
sw_vers | tee "$OUT/sw_vers.txt"
echo "== step 1: models"
python3 -I tools/dev/hf-fetch.py --set m0-t05
[ -f "$INPUT/transcripts.tsv" ] || { echo "missing $INPUT/transcripts.tsv (tools/fixtures/make-librispeech.py)"; exit 2; }

echo "== step 2: input mode"
if ls /Library/Audio/Plug-Ins/HAL 2>/dev/null | grep -qi blackhole; then MODE=blackhole; else MODE=inject; fi
echo "mode=$MODE (BlackHole driver $( [ $MODE = blackhole ] && echo present || echo 'absent: not run: permission, P-ADMIN' ))"

if [ "${SKIP_RUNS:-0}" != 1 ]; then
  rm -f build/perf/raw/voice-*-"$MODE"-*.jsonl
  B="${NO_BUILD:-0}"
  run() { NO_BUILD="$B" FIXTURES="$FIXTURES" tools/bench.sh voice --runs "$RUNS" --input "$INPUT" --mode "$MODE" "$@"; B=1; }
  echo "== step 3: T1 chat-9b-q4 (Kokoro)"
  run --tier-cap T1 --model chat-9b-q4 --tts kokoro
  echo "== step 3: T3-48 chat-35b-q4 (Kokoro)"
  run --tier-cap T3-48 --model chat-35b-q4 --tts kokoro
  echo "== step 4: T0 chat-2b (Kokoro, memory)"
  run --tier-cap T0 --model chat-2b --tts kokoro
  echo "== step 4/5: SystemTTS legs (D-010 fallback numbers) and the simulated Kokoro failure (K-NEW-ENG-9)"
  run --tier-cap T0 --model chat-2b --tts system
  run --tier-cap T1 --model chat-9b-q4 --tts system
  RUNS_SAVE="$RUNS"; RUNS=3
  BENCH_TAG=simfail run --tier-cap T0 --model chat-2b --tts kokoro --simulate-kokoro-failure
  RUNS="$RUNS_SAVE"
fi

echo "== step 6: rt-report"
python3 -I tools/audio/rt-report.py --replace --raw $(ls build/perf/raw/voice-*-"$MODE"-*.jsonl | grep -v simfail) --at-dir "$OUT"

echo "== evaluate"
python3 -I - "$OUT" "$MODE" "$(git rev-parse HEAD 2>/dev/null || echo none)" <<'PY'
import glob, json, os, sys
out, mode, sha = sys.argv[1], sys.argv[2], sys.argv[3]
sums = json.load(open(os.path.join(out, "rt-summary.json")))
def find(tier, model, tts):
    for s in sums:
        if s["tier"] == tier and s["model"] == model and s["tts_requested"] == tts:
            return s
checks, info = [], {}
def add(name, value, bar, ok):
    checks.append({"name": name, "value": value, "bar": bar, "pass": bool(ok)})
label = "[IN-PIPELINE]" if mode == "inject" else mode
for tier, model in (("T1", "chat-9b-q4"), ("T3-48", "chat-35b-q4")):
    s = find(tier, model, "kokoro")
    add(f"NFR-V1/V1b recorded {tier} {model} (n, p50, p95, mode label)",
        s and {"n": s["n"], "p50": round(s["v1_p50"], 3), "p95": round(s["v1_p95"], 3), "mode": s["mode"], "tts": s["tts_used"]},
        "n = 20, mode label present", s and s["n"] >= 20 and s["mode"] == label)
    if s:
        info[f"V1 {tier} {model}"] = {"p50": s["v1_p50"], "target": s["v1_target"], "nfr_pass": s["v1_pass"],
                                      "p95": s["v1_p95"], "v1b_target": s["v1b_target"], "v1b_pass": s["v1b_pass"]}
stages_ok = all(s["stages_p50_ms"] and all(v == v for v in s["stages_p50_ms"].values()) for s in sums)
add("per-stage p50 table present (stages.csv)", os.path.exists(os.path.join(out, "stages.csv")), "6 stages per run set", stages_ok)
for tier, model in (("T0", "chat-2b"), ("T1", "chat-9b-q4")):
    s = find(tier, model, "kokoro")
    sysrun = find(tier, model, "system")
    v = s and {"peak_rss_gb": s["peak_rss_gb"], "B_gb": s["budget_b_gb"], "fit": s["fits_b"],
               "system_tts_peak_gb": sysrun and sysrun["peak_rss_gb"]}
    verdict_ok = s is not None and s["fits_b"] is not None and (s["fits_b"] or sysrun is not None)
    add(f"Kokoro peak RSS vs B at {tier} ({model}) with fit/no-fit verdict", v, "recorded; no-fit → SystemTTS rerun recorded", verdict_ok)
sim = sorted(glob.glob("build/perf/raw/voice-*simfail*.jsonl"))
simrows = [json.loads(l) for f in sim for l in open(f) if l.strip()]
simturns = [r for r in simrows if r.get("kind") == "turn"]
info["K-NEW-ENG-9 fallback (simulated Kokoro failure)"] = {
    "turns": len(simturns), "tts_used": sorted({r.get("tts_used") for r in simturns}),
    "errors": [r.get("error") for r in simturns if r.get("error")]}
info["sw_vers"] = open(os.path.join(out, "sw_vers.txt")).read().split()
live = sorted(glob.glob("build/perf/raw/voice-*-live-*.jsonl"))
liverows = [json.loads(l) for f in live for l in open(f) if l.strip()]
shots = {n: os.path.exists(os.path.join(out, n)) for n in ("tcc-prompt.png", "tcc-settings.png")}
tcc_ok_file = os.path.join(out, "tcc-attribution.json")
tcc = json.load(open(tcc_ok_file)) if os.path.exists(tcc_ok_file) else {}
best_rms = max([r.get("live_rms_dbfs", -200) for r in liverows] or [-200])
tcc_pass = shots["tcc-prompt.png"] and tcc.get("prompt_names_antichat") is True and best_rms > -60
pending = []
if tcc_pass:
    add("TCC prompt names AntiChat (helper capture) and helper capture delivers audio",
        {"prompt": "tcc-prompt.png", "settings": "tcc-settings.png", "best_live_rms_dbfs": round(best_rms, 1)},
        "prompt names AntiChat, RMS > -60 dBFS", True)
else:
    pending.append("TCC attribution (K-NEW-ARCH-5): needs the prompt screenshot naming AntiChat, the Allow click by the "
                   "user (the agent never clicks Allow, PRD §1.5) and a helper live capture with RMS > −60 dBFS")
info["tcc"] = {"screenshots": shots, "attribution": tcc, "live_runs": len(liverows), "best_live_rms_dbfs": best_rms}
ok = all(c["pass"] for c in checks)
status = ("pass-partial" if pending else "pass") if ok else "fail"
res = {"at": "AT-M0-05", "pass": ok and not pending, "status": status, "mode": label, "checks": checks, "pending": pending,
       "info": info, "commit": sha}
json.dump(res, open(os.path.join(out, "result.json"), "w"), indent=2, ensure_ascii=False)
for c in checks:
    print(("PASS " if c["pass"] else "FAIL ") + f'{c["name"]}: {c["value"]} (bar {c["bar"]})')
for p in pending:
    print("PENDING " + p)
print("INFO", json.dumps(info, ensure_ascii=False))
print("AT-M0-05:", status)
sys.exit(0 if ok else 1)
PY
