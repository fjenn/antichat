#!/bin/bash
# AT-FA-06 image, then video — on this Mac, not in the clean VM: the VM is T0 (8 GB; Photo needs 16 GB, Video 24 GB,
# catalog photo_reason/video_reason) and its GPU is paravirtualised (ci-release §9); there is no test user on this Mac
# (Q-002), so each half runs in a fresh dev container / scratch dir of the current user with the developer's installed
# catalog models (read-only), through ~/AntiChat-tools/gpu-run.sh shared:
#   image  the Debug build, FinalAcceptanceProbe leg `image`: "Draw me a lighthouse at dusk" → the chat turn's
#          create_image call (turn script; the chat model's tool choice is not under test) → the REAL Photo models
#          in the helper → MediaOutputGate → the picture in the chat: % progress values, the AI-generated mark;
#   video  `-Bench video --installed <Models>`: the app's own resolution (live hardware profile → signed catalog →
#          the plan card's default text-to-video job → InstalledVideoModels.request) → helper → VideoEngine on the
#          signed video runtime → gate on every preview and the final frames → MP4Encoder (AI mark);
#   notify the "video ready" notification of a finished background video job (MacIntegrationProbe `video` mode,
#          tools/at/at-108-probe.sh: notification spy, scripted job; AT-042).
# Env: OUT_DATE (suite date), MODELS (default the dev cache's Models; image), VIDEO_MODELS (install views; video), VIDEO_RUNTIME (an unzipped signed
#      video-runtime@<catalog version>), GPU_RUN (default ~/AntiChat-tools/gpu-run.sh).
set -uo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd -P)"; cd "$root"
date="${OUT_DATE:-$(date +%Y%m%d-%H%M%S)}"
o="$root/build/at/AT-FA-06/$date"; rm -rf "$o"; mkdir -p "$o"
exec > >(tee -a "$o/run.log") 2>&1
gpu="${GPU_RUN:-$HOME/AntiChat-tools/gpu-run.sh}"
models="${MODELS:-$HOME/Library/Application Support/AntiChat-Dev/Models}"
runtime="${VIDEO_RUNTIME:-}"
# The video models as catalog install views (the dev cache keeps them in the pre-M2 layout): `antichat-cli models
# import --models build/fa/video-models --from <dev Models> --id vid-5b` + `models install … --id vid-taehv` (runbook).
video_models="${VIDEO_MODELS:-$root/build/fa/video-models}"
bin="$root/build/AntiChat.app/Contents/MacOS/AntiChat"
FA_FAILS=0; FA_CHECKS=""
check() { if eval "$2"; then echo "[ok]   $1"; FA_CHECKS+="ok	$1"$'\n'; else echo "[FAIL] $1"; FA_CHECKS+="FAIL	$1"$'\n'; FA_FAILS=$((FA_FAILS + 1)); fi; }
json() { python3 -I -c 'import json,sys
try: j=json.load(open(sys.argv[1]))
except Exception: j={}
try: v=eval(sys.argv[2])
except Exception: v=""
print("" if v is None else v)' "$1" "$2"; }
free_gb() { vm_stat | awk '/page size/ {ps=$8} /Pages free/ {f=$3} /Pages inactive/ {i=$3} END {printf "%d", (f+i)*ps/1073741824}'; }
echo "free memory $(free_gb) GB, load $(sysctl -n vm.loadavg)"

parts="${PARTS:-image,video,notify}"   # PARTS: a subset (each part is self-contained)
if [[ ",$parts," == *,image,* ]]; then
echo "== image (real Photo models, in-app)"
box="$(mktemp -d "${TMPDIR:-/tmp}/fa06.XXXXXX")"; mkdir -p "$box/container/Models" "$o/image"
for d in installs manifests store; do ln -s "$models/$d" "$box/container/Models/$d"; done
printf '%s\n%s\n%s\n' \
    '{"t":"toolCallDone","id":"call_1","name":"create_image","args":"{\"prompt\":\"a lighthouse at dusk\",\"aspect\":\"3:2\"}","delayMs":1}' \
    '{"t":"turn"}' '{"t":"textDelta","v":"Here is your lighthouse.","delayMs":30}' > "$box/turn.jsonl"
printf 'image\n' > "$o/image/leg"
"$gpu" shared -- perl -e 'alarm shift; exec @ARGV' 2400 "$bin" -ApplePersistenceIgnoreState YES -DefaultsSuite fa06 -ANTICHAT_DEV_CONTAINER "$box/container" \
    -SkipOnboarding YES -ChatModel chat-9b-q4 -UseScriptedEngine "$box/turn.jsonl" -FakePackState photo=ready \
    -FinalAcceptanceProbe "$o/image" > "$o/image/app.log" 2>&1
defaults delete fa06 >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/fa06.plist"; rm -rf "$box"
j="$o/image/probe.json"
check "image done in the chat (real Photo models, $(json "$j" 'round(j["seconds"])') s)" "[ -n \"\$(json '$j' 'j[\"imagePath\"]')\" ]"
check "real % progress while it ran ($(json "$j" 'len(j["progress"])') distinct values)" "[ \"\$(json '$j' 'j[\"realProgress\"]')\" = True ]"
check "the picture carries the AI-generated mark (XMP trainedAlgorithmicMedia)" "[ \"\$(json '$j' 'j[\"aiMark\"]')\" = True ]"
fi

if [[ ",$parts," == *,video,* ]]; then
echo "== video (real video models + runtime)"
mkdir -p "$o/video/out"
# The gate's detectors (installed views from the dev store): without them every clip ends `safetyMissing` (fail-closed).
for k in csc-age csc-age-bins csc-nudity; do
    [ -e "$video_models/installs/$k" ] || ln -s "$models/installs/$k" "$video_models/installs/$k" 2>/dev/null || true
done
if [ -n "$runtime" ] && [ -x "$runtime/bin/python3" -o -d "$runtime/bin" ]; then
    "$gpu" shared -- "$root/build/AntiChat.app/Contents/MacOS/AntiChat" -Bench video --installed "$video_models" --runtime "$runtime" \
        --runs 1 --out-dir "$o/video/out" --events "$o/video/events.jsonl" --raw "$o/video/raw.jsonl" > "$o/video/bench.log" 2>&1
    mp4="$(ls "$o/video/out"/*.mp4 2>/dev/null | head -1)"
    check "video done: an MP4 written by the app's own resolution ($(basename "${mp4:-none}"))" "[ -s '${mp4:-/nonexistent}' ]"
    check "the clip carries the AI-generated mark" "grep -a -q trainedAlgorithmicMedia '${mp4:-/nonexistent}'"
    # The runner writes the MP4 only after the gate's checkVideo allowed the final frames (MediaJobRunner.emitVideoResult);
    # without the detectors the same job ends safetyMissing (fail-closed), so a completed row = gated output.
    check "the job completed through the gate (status $(python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline()).get("status"))' "$o/video/raw.jsonl" 2>/dev/null))" "python3 -I -c 'import json,sys; sys.exit(0 if json.loads(open(sys.argv[1]).readline()).get(\"status\") == \"completed\" else 1)' '$o/video/raw.jsonl'"
else
    echo "VIDEO_RUNTIME not set to an unzipped video runtime"; check "video runtime available" "false"
fi
fi

if [[ ",$parts," == *,notify,* ]]; then
echo "== video-ready notification (background job, notification spy)"
tools/at/at-108-probe.sh > "$o/notify.log" 2>&1; nrc=$?
cp -R build/at/AT-108/video "$o/notify-video" 2>/dev/null
check "a finished video job posts one 'video' notification (AT-042 leg; spy)" "[ $nrc = 0 ] && grep -q -i video '$o/notify-video/requests.json'"
fi

printf '%s' "$FA_CHECKS" > "$o/checks.tsv"
python3 -I - "$o" "$FA_FAILS" <<'PY'
import json, sys, datetime
o, fails = sys.argv[1], int(sys.argv[2])
rows = [l.split("\t", 1) for l in open(f"{o}/checks.tsv").read().splitlines() if l]
json.dump({"at": "AT-FA-06", "form": "host (current user, fresh dev container; VM is T0 + paravirtual GPU, no test user Q-002)",
           "pass": fails == 0, "fails": fails, "pending_subchecks": 0, "checks": [{"status": s, "check": c} for s, c in rows],
           "finished": datetime.datetime.now(datetime.timezone.utc).isoformat()}, open(f"{o}/result.json", "w"), indent=1)
PY
echo "AT-FA-06: $([ $FA_FAILS = 0 ] && echo PASS || echo "FAIL ($FA_FAILS)")"
[ $FA_FAILS = 0 ]
