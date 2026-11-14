#!/bin/bash
# M3.T12 AT-280 AC1 (R-280): 10 minutes of voice conversation on the Mac's built-in speakers and microphone,
# unattended: built-in devices selected, output volume 70 %, ambient level checked (median of 10 s ≤ −50 dBFS, else
# wait 10 min, up to 3 tries, then run anyway with the level logged), then `AntiChat -Bench aec` (live VPIO session,
# questions played by afplay outside the echo reference). Devices and volume are restored afterwards.
#   tools/at/run.sh AT-280 -- tools/voice/aec-10min.sh --volume 70 --minutes 10
# --source afplay (questions on these speakers: cancelled by VPIO on macOS, A-M3-T12b) | remote (a second device
# plays them: tools/voice/aec-remote.py, see docs/prd/M3-owner-steps.md) | owner (the owner speaks each prompted question).
# Exit 0 = pass (0 self-interruptions, ≥ 18/20 answered, full duplex throughout), 1 = fail, 2 = not run (headphones).
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
VOLUME=70 MINUTES=10 QVOL=1 SOURCE=afplay
while [ $# -gt 0 ]; do
  case "$1" in --volume) VOLUME=$2; shift 2 ;; --minutes) MINUTES=$2; shift 2 ;; --question-volume) QVOL=$2; shift 2 ;; --source) SOURCE=$2; shift 2 ;;
    *) echo "unknown $1"; exit 64 ;; esac
done
FX=${ANTICHAT_FIXTURES:-$ROOT/fixtures}
OUT=$ROOT/build/at/AT-280
TOOLS=$ROOT/build/tools/voice
mkdir -p "$OUT" "$TOOLS"
for t in set-default-device level-probe; do
  [ "$TOOLS/$t" -nt "tools/voice/$t.swift" ] || swiftc -O -o "$TOOLS/$t" "tools/voice/$t.swift" || exit 1
done
APP=${APP:-$ROOT/build/AntiChat.app}
prev_in=$("$TOOLS/set-default-device" get input | cut -f1)
prev_out=$("$TOOLS/set-default-device" get output | cut -f1)
prev_vol=$(osascript -e "output volume of (get volume settings)")
restore() {
  "$TOOLS/set-default-device" set input "$prev_in" >/dev/null 2>&1
  "$TOOLS/set-default-device" set output "$prev_out" >/dev/null 2>&1
  osascript -e "set volume output volume $prev_vol" >/dev/null 2>&1
}
trap restore EXIT
"$TOOLS/set-default-device" builtin; rc=$?
[ $rc -eq 2 ] && { echo "AT-280 AC1 not run: headphones are connected"; exit 2; }
[ $rc -ne 0 ] && exit 1
osascript -e "set volume output volume $VOLUME"
ambient=""
for try in 1 2 3; do
  ambient=$("$TOOLS/level-probe" 10 "$OUT/ambient-$try.json")
  echo "ambient median ${ambient} dBFS (try $try)"
  python3 -c "import sys; sys.exit(0 if float('$ambient') <= -50 else 1)" && break
  [ $try -lt 3 ] && { echo "room above -50 dBFS: waiting 10 min"; sleep 600; }
done
EXTRA=()
if [ "$SOURCE" = remote ]; then
  python3 -I tools/voice/aec-remote.py --state "$OUT/remote-state.json" & SERVER=$!
  trap 'restore; kill $SERVER 2>/dev/null' EXIT
  EXTRA=(--remote-state "$OUT/remote-state.json")
  echo "Second device: open the URL above, tap Start, then press Return here."; read -r _
fi
"$HOME/AntiChat-tools/gpu-run.sh" shared -- "$APP/Contents/MacOS/AntiChat" -Bench aec --source "$SOURCE" ${EXTRA[@]+"${EXTRA[@]}"} \
  --script "$FX/audio/aec-10min/script.json" --minutes "$MINUTES" --question-volume "$QVOL" --tier-cap T1 --model chat-9b-q4 \
  --out "$OUT/aec-events.json" 2>&1 | tee "$OUT/aec-run.log"
python3 -I - "$OUT/aec-events.json" "$ambient" "$VOLUME" <<'PY'
import json, sys
p, ambient, volume = sys.argv[1], float(sys.argv[2] or -120), int(sys.argv[3])
d = json.load(open(p))
d["ambient_median_dbfs"] = ambient
d["output_volume_pct"] = volume
d["setup"] = "built-in speakers + built-in microphone (same device: questions by afplay on the same speakers, outside the VPIO reference)"
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
print(f"AT-280 AC1: {d['questions_played']} questions, {d['answered']} answered, {d['self_interruptions']} self-interruptions, "
      f"half duplex {d['half_duplex']} -> {'PASS' if d['pass'] else 'FAIL'}")
sys.exit(0 if d["pass"] else 1)
PY
