#!/bin/bash
# M9.T06 AT-NFR-R2: swap-out growth caused by a 30-minute AntiChat session with a 10-tab browser load.
#   tools/perf/swap-session.sh TIER=T1                [--baseline-min 10] [--session-min 30] [--images real|scripted]
# 1. Ten local fixture pages in Safari (fixtures/web/serp-snapshots/*/*.html), opened by command line in the background
#    and hidden (`open -g -j`: no focus taken, nothing clicked; the concurrent screen captures are not covered).
# 2. Baseline: `--baseline-min` (10) idle minutes with Safari open → the background swap-out rate (vm_stat "Swapouts").
# 3. The session: the soak driver (tools/perf/soak.sh, the same perf-harness app, dev container and gpu-run shared) for
#    `--session-min` (30) minutes with only the chat, voice and image legs, 3 images in the 30 minutes, on the tier cap.
# 4. AntiChat-caused swap-out = Δswapouts(session) − baseline rate × session length, in bytes (vm_stat page size).
# Pass: ≤ 0.5 GB → build/at/AT-NFR-R2/<date>.json. Safari is quit at the end only if this script started it.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TIER="${TIER:-T1}" BASE_MIN=10 SESSION_MIN=30 IMAGES=real
while [ $# -gt 0 ]; do
  case "$1" in
    TIER=*) TIER="${1#TIER=}"; shift ;;
    --tier) TIER="$2"; shift 2 ;;
    --baseline-min) BASE_MIN="$2"; shift 2 ;;
    --session-min) SESSION_MIN="$2"; shift 2 ;;
    --images) IMAGES="$2"; shift 2 ;;
    *) echo "usage: $0 TIER=T1 [--baseline-min 10] [--session-min 30] [--images real|scripted]" >&2; exit 64 ;;
  esac
done
FIX="${FIXTURES:-$ROOT/fixtures}"
if [ ! -d "$FIX/web/serp-snapshots" ]; then
  common="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  [ -n "$common" ] && FIX="$(dirname "$common")/fixtures"
fi
PAGES=()
while IFS= read -r p; do PAGES+=("$p"); done < <(find "$FIX/web/serp-snapshots" -name '*.html' | sort | head -n 10)
[ ${#PAGES[@]} -eq 10 ] || { echo "swap-session: need 10 pages under $FIX/web/serp-snapshots" >&2; exit 2; }
swapouts() { vm_stat | awk '/^Swapouts:/ {gsub("\\.", "", $2); print $2}'; }
PAGE=$(vm_stat | sed -n 's/.*page size of \([0-9]*\) bytes.*/\1/p')
SAFARI_WAS_RUNNING=0; pgrep -xq Safari && SAFARI_WAS_RUNNING=1
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RUN="$ROOT/build/soak/swap-$STAMP"
mkdir -p "$(dirname "$RUN")"
echo "swap-session: opening ${#PAGES[@]} pages in Safari (background, hidden)"
open -g -j -a Safari "${PAGES[@]}"
sleep 20  # pages load
echo "swap-session: baseline ${BASE_MIN} min idle"
B0=$(swapouts); T0=$(date +%s)
sleep $((BASE_MIN * 60))
B1=$(swapouts); T1=$(date +%s)
echo "swap-session: ${SESSION_MIN} min session (chat + voice + 3 images) on $TIER"
S0=$(swapouts); U0=$(date +%s)
IPH=$(python3 -c "print(3 * 60 / float('$SESSION_MIN'))")
"$ROOT/tools/perf/soak.sh" --minutes "$SESSION_MIN" --tier "$TIER" --images "$IMAGES" --images-per-hour "$IPH" \
  --skip evil,normal,quickpanel,project,import --run-dir "$RUN" --no-report
RC=$?
S1=$(swapouts); U1=$(date +%s)
[ "$SAFARI_WAS_RUNNING" = 0 ] && osascript -e 'tell application "Safari" to quit' >/dev/null 2>&1
OUT="$ROOT/build/at/AT-NFR-R2"; mkdir -p "$OUT"
python3 -I - "$OUT/$(date +%Y-%m-%d).json" <<PY
import json, sys
page = int("$PAGE" or 16384)
b0, b1, t0, t1, s0, s1, u0, u1 = $B0, $B1, $T0, $T1, $S0, $S1, $U0, $U1
rate = (b1 - b0) / max(1, t1 - t0)  # background swap-outs per second (Safari open, AntiChat not running)
session = s1 - s0
attributable = session - rate * (u1 - u0)
gb = attributable * page / 1e9
res = json.load(open("$RUN/probe/result.json")) if __import__("os").path.exists("$RUN/probe/result.json") else None
ok = $RC == 0 and res is not None and gb <= 0.5
out = {"at": "AT-NFR-R2", "tier": "$TIER", "pass": ok, "bar_gb": 0.5, "attributable_swapout_gb": round(gb, 3),
       "page_size": page, "baseline": {"minutes": (t1 - t0) / 60, "swapouts": b1 - b0, "rate_per_s": rate},
       "session": {"minutes": (u1 - u0) / 60, "swapouts": session, "soak_exit": $RC, "run_dir": "$RUN",
                   "legs": res and {"counts": res.get("counts"), "failures": res.get("failures"), "images": res.get("imagesDone")}},
       "safari_pages": ${#PAGES[@]}, "safari_was_running": bool($SAFARI_WAS_RUNNING),
       "method": "vm_stat Swapouts delta during the session minus the idle baseline rate (Safari open) × the session length"}
json.dump(out, open(sys.argv[1], "w"), indent=1)
print(f"{'PASS' if ok else 'FAIL'} AT-NFR-R2 {out['tier']}: AntiChat-caused swap-out {gb:.3f} GB (≤ 0.5), "
      f"session Δ {session} pages, baseline {b1 - b0} pages / {(t1 - t0) / 60:.0f} min → {sys.argv[1]}")
sys.exit(0 if ok else 1)
PY
