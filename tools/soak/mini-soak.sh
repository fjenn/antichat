#!/bin/bash
# M2.T13 step 5 (R-206 AC7 early check, AT-206 part 2, AT-NFR-R1): mini-soak through the real helper at a tier cap.
#   tools/soak/mini-soak.sh --tier T1 --minutes 60        (chat-9b-q4 + evil-9b + scripted 6.3 GB image jobs)
#   tools/soak/mini-soak.sh --tier T2-24 --minutes 60     (chat-9b-q4 + evil-9b + scripted 6.2 GB image jobs)
#   tools/soak/mini-soak.sh --tier T0 --minutes 30        (chat-2b + scripted 2.5 GB image jobs; no Evil on T0)
#   tools/soak/mini-soak.sh --tier T3-48 --minutes 60     (M9.T05: chat-35b-q4 + evil-35b-q4 (MLX) + scripted 6.0 GB
#                                                          image jobs, the T3 photo default q4@1024; chat co-resides)
#   --no-evil: run without Evil chats (only for a smoke run while the Evil model is not installed; recorded in the JSON)
# Pass: 0 crashes (helper PID stable and alive; no new AntiChat*.ips in ~/Library/Logs/DiagnosticReports), 0 jetsam
# events (`log show` xnu lines naming AntiChat), peak phys_footprint(helper + children) ≤ B.
# Output: build/at/AT-206/soak-<tier>.csv + .json, and the verdict line in build/at/AT-206/soak-<tier>.log.
# Needs the release antichat-bench (make bench-release) and a Debug build/AntiChat.app
# (ScriptedImageEngine is DEBUG-only); SOAK_APP=<copy of the app> keeps a long soak independent of later builds.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TIER=T1 MINUTES=60 NO_EVIL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tier) TIER="$2"; shift 2 ;;
    --minutes) MINUTES="$2"; shift 2 ;;
    --no-evil) NO_EVIL=1; shift ;;
    *) echo "usage: $0 --tier T0|T1|T2-24|T3-48 --minutes N [--no-evil]" >&2; exit 64 ;;
  esac
done
MODELS="${ANTICHAT_DEV_CACHE:+$ANTICHAT_DEV_CACHE/Models}"
MODELS="${MODELS:-$HOME/Library/Application Support/AntiChat-Dev/Models}"
EVIL="" EVIL_KEY=""
case "$TIER" in
  T0) CHAT=chat-2b; EVIL=""; IMG=2.5 ;;
  T1) CHAT=chat-9b-q4; EVIL="$MODELS/evil-9b"; IMG=6.3 ;;
  T2-24) CHAT=chat-9b-q4; EVIL="$MODELS/evil-9b"; IMG=6.2 ;;
  T3-48) CHAT=chat-35b-q4; EVIL_KEY=evil-35b-q4; IMG=6.0 ;;
  *) echo "unknown tier $TIER" >&2; exit 64 ;;
esac
if [ -n "$EVIL_KEY" ] && [ ! -e "$MODELS/$EVIL_KEY" ] && [ ! -e "$MODELS/installs/$EVIL_KEY" ]; then
  if [ "$NO_EVIL" = 1 ]; then EVIL_KEY=""
  else echo "missing $MODELS/$EVIL_KEY (make models-dev TIER=evil-T3), or --no-evil for a smoke run" >&2; exit 2; fi
fi
[ "$NO_EVIL" = 1 ] && EVIL="" && EVIL_KEY=""
OUT="$ROOT/build/at/AT-206"
mkdir -p "$OUT"
BENCH="$ROOT/.build/release/antichat-bench"
[ -x "$BENCH" ] || { echo "missing $BENCH (make bench-release)" >&2; exit 2; }
START_EPOCH=$(date +%s)
START_LOG=$(date '+%Y-%m-%d %H:%M:%S')
ARGS=(soak --cap "$TIER" --minutes "$MINUTES" --chat "$CHAT" --image-gb "$IMG" --csv "$OUT/soak-$TIER.csv" --json "$OUT/soak-$TIER.json"
      --app "${SOAK_APP:-$ROOT/build/AntiChat.app}")
[ -n "$EVIL" ] && ARGS+=(--evil "$EVIL")
[ -n "$EVIL_KEY" ] && ARGS+=(--evil-key "$EVIL_KEY")
# GPU wrapper (M9.T05 prep): gpu-run.sh in ANTICHAT_GPU_MODE (timing default, shared for dry runs); none inside an
# outer gpu-run.sh timing (a nested lockf on the same lock would wait forever); bare lockf without gpu-run.sh.
GPU_RUN="${ANTICHAT_GPU_RUN:-$HOME/AntiChat-tools/gpu-run.sh}"
if [ -n "${ANTICHAT_GPU_LOCK_HELD:-}" ]; then WRAP=()
elif [ -x "$GPU_RUN" ]; then WRAP=("$GPU_RUN" "${ANTICHAT_GPU_MODE:-timing}" --)
else WRAP=(lockf /tmp/antichat-gpu.lock); fi
${WRAP[@]+"${WRAP[@]}"} "$BENCH" "${ARGS[@]}"
RC=$?
IPS=$(find "$HOME/Library/Logs/DiagnosticReports" -name 'AntiChat*' -newermt "@$START_EPOCH" 2>/dev/null | wc -l | tr -d ' ')
JETSAM=$(log show --start "$START_LOG" --style compact --predicate 'subsystem == "com.apple.xnu" AND eventMessage CONTAINS "AntiChat"' 2>/dev/null | grep -ci jetsam || true)
python3 -I - "$OUT/soak-$TIER.json" "$RC" "$IPS" "$JETSAM" <<'PY' | tee "$OUT/soak-$TIER.log"
import json, sys
path, rc, ips, jetsam = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
try:
    r = json.load(open(path))
except Exception as e:
    print(f"FAIL soak: no result ({e}), bench exit {rc}"); sys.exit(1)
ok = rc == 0 and ips == 0 and jetsam == 0 and r["helper_alive"] and r["helper_pid_start"] == r["helper_pid_end"] and r["peak_le_b"]
print(f"{'PASS' if ok else 'FAIL'} soak {r['cap']} {r['minutes']} min: turns {r['turns']}, image jobs {r['image_jobs']}, "
      f"evil chats {r['evil_chats']}, errors {len(r['errors'])}, peak {r['peak_bytes']/1e9:.2f} GB vs B {r['budget_b']/1e9:.1f} GB, "
      f"helper pid {r['helper_pid_start']}->{r['helper_pid_end']} alive {r['helper_alive']}, new .ips {ips}, jetsam {jetsam}")
sys.exit(0 if ok else 1)
PY
