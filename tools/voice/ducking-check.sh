#!/bin/bash
# M3.T12 AT-280 AC3 (R-280): other apps' audio while a voice conversation runs, on the built-in speakers. The music
# bed plays with afplay; the built-in mic measures 20 s before and 20 s during a live session (`-Bench aec
# --listen-seconds 20`), with the ducking setting on and off → build/at/AT-280/ducking.json (drop = before − during,
# median dBFS over 60 s = one whole loop of the bed, so both windows hold the same music). Pass: setting on → the `.min` configuration (VoiceAudioEngine.appliedDuckingLevel) and the drop is
# recorded; setting off → drop ≤ 1 dB.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
FX=${ANTICHAT_FIXTURES:-$ROOT/fixtures}
OUT=$ROOT/build/at/AT-280
TOOLS=$ROOT/build/tools/voice
APP=${APP:-$ROOT/build/AntiChat.app}
mkdir -p "$OUT" "$TOOLS"
for t in set-default-device level-probe; do
  [ "$TOOLS/$t" -nt "tools/voice/$t.swift" ] || swiftc -O -o "$TOOLS/$t" "tools/voice/$t.swift" || exit 1
done
prev_in=$("$TOOLS/set-default-device" get input | cut -f1)
prev_out=$("$TOOLS/set-default-device" get output | cut -f1)
prev_vol=$(osascript -e "output volume of (get volume settings)")
music=""
restore() {
  [ -n "$music" ] && kill "$music" 2>/dev/null
  "$TOOLS/set-default-device" set input "$prev_in" >/dev/null 2>&1
  "$TOOLS/set-default-device" set output "$prev_out" >/dev/null 2>&1
  osascript -e "set volume output volume $prev_vol" >/dev/null 2>&1
}
trap restore EXIT
"$TOOLS/set-default-device" builtin || exit 2
osascript -e "set volume output volume 50"
( while true; do afplay "$FX/audio/music/bed-60s.wav"; done ) &
music=$!
for duck in 1 0; do
  sleep 2
  before=$("$TOOLS/level-probe" 60 "$OUT/ducking-before-$duck.json")
  log="$OUT/ducking-session-$duck.log"
  "$HOME/AntiChat-tools/gpu-run.sh" shared -- "$APP/Contents/MacOS/AntiChat" -Bench aec --listen-seconds 70 --duck "$duck" \
    --tier-cap T1 --model chat-9b-q4 --out "$OUT/ducking-session-$duck.json" > "$log" 2>&1 &
  bench=$!
  for _ in $(seq 1 600); do grep -q "session listening" "$log" 2>/dev/null && break; sleep 0.5; done
  sleep 2
  during=$("$TOOLS/level-probe" 60 "$OUT/ducking-during-$duck.json")
  wait $bench
  echo "duck=$duck before ${before} dBFS, during ${during} dBFS"
  echo "$duck $before $during" >> "$OUT/ducking-levels.txt.tmp"
done
kill "$music" 2>/dev/null; music=""
python3 -I - "$OUT" <<'PY'
import json, sys, os
out = sys.argv[1]
rows = [l.split() for l in open(os.path.join(out, "ducking-levels.txt.tmp"))][-2:]
os.remove(os.path.join(out, "ducking-levels.txt.tmp"))
res = {}
for duck, before, during in rows:
    key = "setting_on" if duck == "1" else "setting_off"
    s = json.load(open(os.path.join(out, f"ducking-session-{duck}.json")))
    res[key] = {"before_dbfs": float(before), "during_dbfs": float(during), "drop_db": round(float(before) - float(during), 2),
                "ducking_applied": s.get("ducking_applied"), "half_duplex": s.get("half_duplex"), "errors": s.get("errors")}
res["pass_setting_off"] = res.get("setting_off", {}).get("drop_db", 99) <= 1.0
res["note"] = "music bed at 50 % volume on the built-in speakers, measured by the built-in microphone (plain input tap)"
json.dump(res, open(os.path.join(out, "ducking.json"), "w"), indent=2, sort_keys=True)
print(json.dumps(res, indent=2))
sys.exit(0 if res["pass_setting_off"] else 1)
PY
