#!/bin/zsh
# AT-008 leg 4 runner (M1.T09; NFR-U5 on the S1 stand-in). XCUITest is blocked here (Q-015), so the app measures
# itself with the in-process RendererProbe (`-RendererProbe <dir>`: cadence, main-thread hitches, word fade) while
# this script records the screen at display rate (tools/visual/capture.sh rec, [PERM: Screen Recording]) for the
# frame-based checks (tools/frametime.py, tools/visual/layout-jump.py), cropped to the conversation column.
# Layout jumps come from the renderer filmed in isolation (AT008_FRAMES=1 make test-unit FILTER=RendererLayoutFramesTests
# → build/at/AT-008/frames/), run that first.
# Usage: tools/at/run.sh AT-008 -- tools/at/at-008-probe.sh [CPU_SCALE=0.25] [SCRIPT=mixed-3k]
# Output: build/at/AT-008/{renderer.json, mixed-3k.mov, frametime.json, jumps.json, summary.json, final.png}
set -u
ROOT=${0:A:h:h:h}
BIN=${AT008_APP:-$ROOT/build/AntiChat.app}/Contents/MacOS/AntiChat  # M9.T05: AT008_APP = the perf-harness build
OUT=${AT008_OUT:-$ROOT/build/at/AT-008}  # fix/u5-renderer: the long-chat variant writes beside it
FRAMES=${AT008_FRAMES_DIR:-$ROOT/build/at/AT-008/frames}
SCALE=${1:-0.25}
NAME=${2:-mixed-3k}
SCRIPT=$ROOT/fixtures/scripts/$NAME.jsonl
[[ -f $SCRIPT ]] || SCRIPT=$ROOT/tools/fixtures/scripts/$NAME.jsonl  # staging copy (A-M1-T05a)
[[ -x $BIN ]] || { echo "missing $BIN (run make build)"; exit 2; }
mkdir -p "$OUT"
box=$(mktemp -d /tmp/antichat-at008-XXXXXX)
rm -f "$OUT/renderer.json"
args=(-ApplePersistenceIgnoreState YES -ANTICHAT_DEV_CONTAINER "$box" -SkipOnboarding YES -UseScriptedEngine "$SCRIPT" -RendererProbe "$OUT")  # M9.T05 prep: a fresh container shows onboarding, not the main window
# fix/u5-renderer long-chat variant (tools/at/at-008-longchat.sh): a seeded database and the chat to stream into.
[[ -n ${AT008_DB:-} ]] && cp "$AT008_DB" "$box/antichat.sqlite"
[[ -n ${AT008_CHAT:-} ]] && args+=(-RendererProbeChat "$AT008_CHAT")
[[ -n ${AT008_EXTRA_ARGS:-} ]] && args+=(${=AT008_EXTRA_ARGS})  # e.g. "-RendererLiveSelectable YES" (A/B)
[[ $SCALE != 1 ]] && args+=(-RendererCPUScale "$SCALE")
# M9.T05: sample load1 every 2 s while the renderer runs, so a contaminated run is visible in renderer.json / summary.json
# (the step's quiet gate only checks the start; other agents' builds can ramp mid-run).
( while :; do echo "$(date +%s) $(sysctl -n vm.loadavg | awk '{print $2}')"; sleep 2; done ) >"$box.load" 2>/dev/null &
sampler=$!
"$BIN" "${args[@]}" >"$box.log" 2>&1 &
app=$!
# The probe sends ~2.3 s after launch; record 40 s from launch (mixed-3k streams ~24 s at 10 ms/token).
rec=$("$ROOT/tools/visual/capture.sh" rec at-008 "$NAME" 40)
wait $app
kill $sampler 2>/dev/null
[[ -f $OUT/renderer.json ]] || { echo "no renderer.json"; tail -20 "$box.log"; exit 1; }
python3 -I - "$OUT/renderer.json" "$box.load" "$(sysctl -n hw.ncpu)" <<'PY'
import json, sys
path, samples, ncpu = sys.argv[1], sys.argv[2], int(sys.argv[3])
l1 = [float(x.split()[1]) for x in open(samples) if len(x.split()) == 2]
r = json.load(open(path))
r["load"] = {"load1_samples": l1, "load1_max": max(l1, default=None), "load1_min": min(l1, default=None),
             "load1_mean": sum(l1) / len(l1) if l1 else None, "ncpu": ncpu, "interval_s": 2,
             "contaminated_over_12": any(x > 12 for x in l1)}
json.dump(r, open(path, "w"), indent=1)
print("load1 during the run: max %s mean %.2f (n %d)%s" % (r["load"]["load1_max"], r["load"]["load1_mean"] or 0, len(l1),
      " — CONTAMINATED (> 12)" if r["load"]["contaminated_over_12"] else ""))
PY
cp "$rec" "$OUT/$NAME.mov"
# Crop: the window (pixels from the probe) minus the sidebar (260 pt) and the composer/toolbar bands.
crop=$(python3 -I - "$OUT/renderer.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["windowPixels"]
s = d["scale"]
x = d["x"] + int(300 * s); w = d["w"] - int(340 * s)
y = d["y"] + int(80 * s); h = d["h"] - int(260 * s)
print(f"{w}:{h}:{x}:{y}")
PY
)
echo "crop $crop"
python3 -I "$ROOT/tools/frametime.py" "$OUT/$NAME.mov" --crop "$crop" --json "$OUT/frametime.json" | head -3
python3 -I "$ROOT/tools/visual/layout-jump.py" "$OUT/$NAME.mov" --crop "$crop" --json "$OUT/jumps.json"
# Layout jumps: the renderer filmed in isolation (RendererLayoutFramesTests → frames/, see that test's header),
# because the live recording's crop is shared with other apps' windows on this desktop.
if [[ ! -d $FRAMES ]]; then
  echo "missing $FRAMES: run AT008_FRAMES=1 make test-unit FILTER=RendererLayoutFramesTests first"; exit 2
fi
python3 -I "$ROOT/tools/visual/layout-jump.py" "$FRAMES" --step-ms 0 --json "$OUT/jumps-frames.json"
python3 -I - "$OUT" <<'PY'
import json, sys, os
o = sys.argv[1]
r = json.load(open(os.path.join(o, "renderer.json")))
f = json.load(open(os.path.join(o, "frametime.json")))
j = json.load(open(os.path.join(o, "jumps.json")))
jf = json.load(open(os.path.join(o, "jumps-frames.json")))
med = r["applyIntervalMs"].get("median", 0)
legs = {
    "cadence 30–60 Hz: in-process reveal apply interval median 16.7–33.3 ms": {"pass": 16.6 <= med <= 33.4, "median_ms": med},
    "0 main-thread frames > 33 ms": r["legs"]["0 main-thread frames > 33 ms"],
    "0 layout jumps > 4 px (renderer frames)": {"pass": jf["jumps_over_threshold"] == 0 and jf["pairs"] > 50,
                                                "max_jump_px": jf["max_jump_px"], "pairs": jf["pairs"]},
    "per-word fade active": r["legs"]["per-word fade active"],
}
# The live-window screen recording is informational only (shared desktop: other windows overlap the crop).
info = {"recording frame-change median ms": f.get("median_ms"), "recording max jump px": j["max_jump_px"]}
summary = {"label": r["label"], "pass": all(v["pass"] for v in legs.values()), "legs": legs, "informational": info,
           "reveal_seconds": r["revealSeconds"], "main_thread": r["mainThread"], "load": r.get("load")}
json.dump(summary, open(os.path.join(o, "summary.json"), "w"), indent=1)
for k, v in legs.items():
    print(("PASS " if v["pass"] else "FAIL ") + k + "  " + json.dumps({a: b for a, b in v.items() if a != "pass"}))
print("informational:", json.dumps(info))
print("AT-008 leg 4:", "PASS" if summary["pass"] else "FAIL", "(" + r["label"] + ")")
sys.exit(0 if summary["pass"] else 1)
PY
