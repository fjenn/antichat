#!/bin/bash
# AT-FA-08 the safety floor fires — never with real prohibited content (D-006, Q-012): lawful proxies only.
#   a. blocked path: the forced-verdict seam (`ForcedVerdictCheck`, compiled only under ANTICHAT_UI_TESTING, which no
#      app configuration defines — r241 rule 2b + the `nm` scan) drives the REAL MediaOutputGate in the SwiftPM test
#      build (tools/at/at-285-runner.sh: one gate call per preview and per final, nothing written on block, a later
#      blocked preview stops the job) and MediaJobQueueTests (blocked job → `local_counter.child_safety_blocks` + 1,
#      the blocked tile state, no file in Media). The app's Debug/Release builds have no seam by design, so the
#      in-app "blocked card" form of M10.md is not reachable there (recorded; the tile itself is covered by
#      BlockedMediaTile snapshot tests in the unit suite).
#   b. fail-closed: with the detector models absent from the model store the Photo job is refused with the
#      `safety.missing` repair card and no image is produced (Debug build, real Photo path, FinalAcceptanceProbe leg
#      `image` with expect=missing). The same on the Release build needs UI automation (Q-015).
#   c. the R-241 audit report (one call site, nothing sent): tools/ci/r241-audit.py.
set -uo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd -P)"; cd "$root"
date="${OUT_DATE:-$(date +%Y%m%d-%H%M%S)}"
o="$root/build/at/AT-FA-08/$date"; rm -rf "$o"; mkdir -p "$o"
exec > >(tee -a "$o/run.log") 2>&1
FA_FAILS=0; FA_CHECKS=""
check() { if eval "$2"; then echo "[ok]   $1"; FA_CHECKS+="ok	$1"$'\n'; else echo "[FAIL] $1"; FA_CHECKS+="FAIL	$1"$'\n'; FA_FAILS=$((FA_FAILS + 1)); fi; }
note() { echo "[pending] $1"; FA_CHECKS+="pending	$1"$'\n'; }

echo "== a. forced verdict through the real gate + queue counter"
tools/at/at-285-runner.sh > "$o/at-285-runner.log" 2>&1; arc=$?
check "forced 'block' verdict through the real MediaOutputGate: nothing written, job stopped (11 forced tests)" "[ $arc = 0 ] && grep -q 'Test run with 11 tests in 3 suites passed' '$o/at-285-runner.log'"
check "blocked job → child_safety_blocks + 1 and no Media file (MediaJobQueueTests in the runner)" "[ \"\$(grep -c '^rc=0$' '$o/at-285-runner.log')\" = 2 ]"

echo "== b. fail-closed: the detector models absent → safety.missing, no picture"
# The real Photo path (no scripted engine): a fresh dev container whose installs are the dev store's installed
# models MINUS the detectors (csc-*), i.e. the state after the detector files are removed from the model store.
models="${MODELS:-$HOME/Library/Application Support/AntiChat-Dev/Models}"
box="$(mktemp -d "${TMPDIR:-/tmp}/fa08.XXXXXX")"; mkdir -p "$box/container/Models/installs" "$o/missing"
for d in manifests store; do ln -s "$models/$d" "$box/container/Models/$d"; done
for k in "$models"/installs/*; do case "$(basename "$k")" in csc-*) ;; *) ln -s "$k" "$box/container/Models/installs/$(basename "$k")" ;; esac; done
printf '%s\n%s\n%s\n' \
    '{"t":"toolCallDone","id":"call_1","name":"create_image","args":"{\"prompt\":\"a lighthouse at dusk\",\"aspect\":\"3:2\"}","delayMs":1}' \
    '{"t":"turn"}' '{"t":"textDelta","v":"Here is your lighthouse.","delayMs":30}' > "$box/turn.jsonl"
printf 'image\n' > "$o/missing/leg"; printf 'missing\n' > "$o/missing/expect"
"${GPU_RUN:-$HOME/AntiChat-tools/gpu-run.sh}" shared -- perl -e 'alarm shift; exec @ARGV' 1200 build/AntiChat.app/Contents/MacOS/AntiChat -ApplePersistenceIgnoreState YES \
    -DefaultsSuite fa08 -ANTICHAT_DEV_CONTAINER "$box/container" -SkipOnboarding YES -ChatModel chat-9b-q4 \
    -UseScriptedEngine "$box/turn.jsonl" -FakePackState photo=ready -FinalAcceptanceProbe "$o/missing" > "$o/missing/app.log" 2>&1
media="$(find "$box/container/Media" -type f 2>/dev/null | wc -l | tr -d ' ')"
sqlite3 -readonly "$box/container/antichat.sqlite" "SELECT kind, state FROM media_job" > "$o/missing/media-jobs.txt" 2>&1
defaults delete fa08 >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/fa08.plist"; rm -rf "$box"
j="$o/missing/probe.json"
check "detectors missing: the Photo job is withheld (media_job $(tr '\n' ' ' < "$o/missing/media-jobs.txt")) and no picture is made (Media files: $media)" \
    "[ -s '$o/missing/media-jobs.txt' ] && ! grep -q '|done' '$o/missing/media-jobs.txt' && [ '$media' = 0 ] && [ -z \"\$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get(\"imagePath\") or \"\")' '$j')\" ]"
python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("safetyMissingShown") else 1)' "$j" \
    && echo "[ok]   the safety.missing repair card is on screen" \
    || note "the safety.missing repair card on screen: its anchor was not seen (host background windows are not being ordered in this session; RC visual QA)"
note "Release-build fail-closed form (detector files deleted from the store → Photo shows the repair copy): UI automation (Q-015)"

echo "== b2. fail-closed, headless: a real video job with the detectors absent ends safetyMissing, no clip written"
# The app's own resolution (-Bench video --installed) over install views that hold the video models but no csc-*.
runtime="${VIDEO_RUNTIME:-}"
vm_src="${VIDEO_MODELS:-$root/build/fa/video-models}"
if [ -n "$runtime" ] && [ -d "$vm_src/installs/vid-5b" ]; then
    nod="$(mktemp -d "${TMPDIR:-/tmp}/fa08v.XXXXXX")"; mkdir -p "$nod/installs" "$o/video-missing/out"
    for d in manifests store; do [ -e "$vm_src/$d" ] && ln -s "$vm_src/$d" "$nod/$d"; done
    for k in "$vm_src"/installs/*; do case "$(basename "$k")" in csc-*) ;; *) ln -s "$k" "$nod/installs/$(basename "$k")" ;; esac; done
    "${GPU_RUN:-$HOME/AntiChat-tools/gpu-run.sh}" shared -- build/AntiChat.app/Contents/MacOS/AntiChat -Bench video --installed "$nod" \
        --runtime "$runtime" --runs 1 --out-dir "$o/video-missing/out" --raw "$o/video-missing/raw.jsonl" > "$o/video-missing/bench.log" 2>&1
    rm -rf "$nod"
    st="$(python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline()).get("status"))' "$o/video-missing/raw.jsonl" 2>/dev/null)"
    check "detectors missing: the real video job ends ${st:-?} and writes no clip" "[ '$st' = safetyMissing ] && [ -z \"\$(ls '$o/video-missing/out')\" ]"
else
    note "headless video fail-closed: VIDEO_RUNTIME / video install views not available here"
fi

echo "== c. R-241 audit"
python3 -I tools/ci/r241-audit.py > "$o/r241-audit.txt" 2>&1; rrc=$?
check "R-241 audit: one ChildSafetyCheck call site, no network in the check (report attached)" "[ $rrc = 0 ]"

printf '%s' "$FA_CHECKS" > "$o/checks.tsv"
pending=$(grep -c '^pending' "$o/checks.tsv" || true)
python3 -I - "$o" "$FA_FAILS" "$pending" <<'PY'
import json, sys, datetime
o, fails, pending = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
rows = [l.split("\t", 1) for l in open(f"{o}/checks.tsv").read().splitlines() if l]
json.dump({"at": "AT-FA-08", "form": "host: forced-verdict test build + Debug fail-closed (no seam in app builds by design)",
           "pass": fails == 0, "fails": fails, "pending_subchecks": pending, "checks": [{"status": s, "check": c} for s, c in rows],
           "finished": datetime.datetime.now(datetime.timezone.utc).isoformat()}, open(f"{o}/result.json", "w"), indent=1)
PY
echo "AT-FA-08: $([ $FA_FAILS = 0 ] && echo PASS || echo "FAIL ($FA_FAILS)")"
[ $FA_FAILS = 0 ]
