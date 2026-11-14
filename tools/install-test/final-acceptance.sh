#!/bin/bash
# `make test-final` — the final acceptance suite AT-FA-01…14 (M10.T09; runbook tools/release/final-acceptance.md).
# Three passes; each VM pass is a fresh clone of `antichat-clean-26.x` (its own user = the clean account), deleted after.
#   debug    the test-flavoured build of the RC commit (build/AntiChat.app, Debug: the in-process probes and hooks only
#            exist there) in an 8 GB VM (its real RAM → tier T0): AT-FA-02/03/14 onboarding with real downloads from
#            the local mirror of the catalog's Hugging Face files, 04 offline chat, 05 dictation + voice, 07 Evil,
#            09 ChatGPT import, 10 crash recovery, 11 relaunch, 13 Uninstall (steps/fa-*.sh).
#   release  the Release RC DMGs (N-1 and N, dev/adhoc-signed, dev keys) in a second clone: AT-FA-01 download →
#            Gatekeeper → first open, AT-FA-12 update N-1 → N through the local dev appcast (user data from a schema
#            one behind: migration + backup), AT-FA-13 the documented manual uninstall (vm-release-smoke.sh FORM=dev).
#   host     AT-FA-06 image then video and AT-FA-08 safety floor, on this Mac (GPU; the safety seam only exists in
#            the SwiftPM test build): steps/fa-06-media-host.sh, steps/fa-08-safety-host.sh.
# Env: PASS=all|debug|release|host (comma list), LEGS=02,04,… (debug pass subset), VM_PREFIX (alias CLONE_PREFIX)=<clone name prefix>
#      (default ac-fa-debug; one per agent so nobody deletes another run's clone), VM=<existing clone> (reuse, never
#      the base image; with KEEP=1 it is not deleted), PREV_DMG / DMG (release pass; default build/fa/rel-n1|rel-n).
# Evidence: build/at/AT-FA-<nn>/<date>/ (result.json + checks.tsv + captures/logs); suite table build/at/AT-FA/<date>/.
# Exit: 0 all run legs pass, 1 a failure, 3 not run (no Tart / image).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"; root="$(cd "$here/../.." && pwd -P)"; cd "$root"
source "$here/lib/vm.sh"
passes="${PASS:-all}"; [ "$passes" = all ] && passes="debug,release,host"
legs="${LEGS:-02,04,05,07,09,10,11,13}"
date="$(date +%Y%m%d-%H%M%S)"
suite="$root/build/at/AT-FA/$date"; mkdir -p "$suite"
exec > >(tee -a "$suite/suite.log") 2>&1
echo "final acceptance $date @ $(git rev-parse --short HEAD)$(git diff --quiet || echo ' (dirty)'); passes: $passes"
rc=0
gpu="${GPU_RUN:-$HOME/AntiChat-tools/gpu-run.sh}"
trap 'vm_cleanup' EXIT INT TERM

collect() {  # collect <share out dir>: AT-FA-<nn> folders → build/at/AT-FA-<nn>/<date>/
    local d
    for d in "$1"/AT-FA-*; do
        [ -d "$d" ] || continue
        local at; at="$(basename "$d")"
        mkdir -p "$root/build/at/$at"; rm -rf "$root/build/at/$at/$date"; mv "$d" "$root/build/at/$at/$date"
        echo "evidence $at → build/at/$at/$date"
    done
}

debug_pass() {
    local app="$root/build/AntiChat.app"
    [ -x "$app/Contents/MacOS/AntiChat" ] || { echo "debug pass: make build first"; return 1; }
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" | grep -q '\.dev$' \
        || { echo "debug pass: build/AntiChat.app is not the Debug build"; return 1; }
    # The T0 catalog sets: starter + tier chat + embed (Chat), Voice, Evil.
    python3 -I "$here/fa-mirror.py" --catalog site/public/catalog/v2/catalog.json --out build/fa/mirror \
        --ids chat-0.8b,chat-2b,embed,evil-2b,stt,tts,vad-files,turn,turn-coreml || return 1
    local xfer; xfer="$(mktemp -d "${TMPDIR:-/tmp}/ac-fa-XXXXXX")"
    tar -C "$root/build" -cf "$xfer/AntiChat.app.tar" AntiChat.app
    mkdir -p "$xfer/steps" "$xfer/out"
    cp "$here"/steps/*.sh "$root/tools/ci/zero-files.sh" "$root/tools/ci/antichat-paths.txt" \
        "$root/fixtures/scripts/basic.jsonl" "$root/tools/fixtures/range-server.py" "$root/tools/ci/db-canon.py" "$xfer/steps/"
    tar -C "$root/fixtures" -cf "$xfer/fixtures.tar" audio/dictation chats/chatgpt-export/export.zip
    local own=0
    if [ -n "${VM:-}" ]; then VM_NAME="$VM"; echo "reusing VM $VM (its shares must be xfer=$xfer, mirror)"; else
        own=1; vm_clone "${VM_PREFIX:-${CLONE_PREFIX:-ac-fa-debug}}-$(date +%s)" 8192 4 || return 1
        trap 'vm_cleanup; rm -rf "$xfer"' RETURN
        vm_boot "$suite/tart-debug.log" "$xfer" "mirror:$root/build/fa/mirror:ro" || return 1
    fi
    vx "sw_vers; sysctl -n hw.memsize; whoami" | tee "$suite/vm-debug.txt"
    vx "sudo rm -rf /Applications/AntiChat.app; sudo tar -C /Applications -xf '$VM_SHARE/AntiChat.app.tar'; sudo chown -R admin:staff /Applications/AntiChat.app
        rm -rf ~/steps ~/fixtures; cp -R '$VM_SHARE/steps' ~/steps; mkdir -p ~/fixtures; tar -C ~/fixtures -xf '$VM_SHARE/fixtures.tar'"
    local l s r=0
    for l in ${legs//,/ }; do
        s="$(ls "$here"/steps/fa-"$l"-*.sh 2>/dev/null | head -1)"
        [ -n "$s" ] || { echo "no step for AT-FA-$l"; r=1; continue; }
        echo; echo "== $(date +%T) AT-FA-$l ($(basename "$s"))"
        # Model runs hold a shared GPU slot (~/AntiChat-tools/gpu-run.sh); 3 h bound per leg.
        "$gpu" shared -- perl -e 'alarm shift; exec @ARGV' 10800 "$TART" exec "$VM_NAME" /bin/zsh -lc "bash ~/steps/$(basename "$s")" || r=1
    done
    collect "$xfer/out"
    [ "$own" = 1 ] || rm -rf "$xfer"
    return $r
}

release_pass() {
    local prev="${PREV_DMG:-$(ls build/fa/rel-n1/AntiChat-*.dmg 2>/dev/null | head -1)}" new="${DMG:-$(ls build/fa/rel-n/AntiChat-*.dmg 2>/dev/null | head -1)}"
    [ -f "$prev" ] && [ -f "$new" ] || { echo "release pass: build the N-1 and N DMGs first (runbook §Build)"; return 1; }
    local seed="$root/fixtures/chats/db/v32_video_run_history.sqlite"
    FORM="${FORM:-dev}" SEED_DB="$seed" PREV_DMG="$prev" DMG="$new" OUT="$suite/release" "$here/vm-release-smoke.sh"; local r=$?
    # Split the journey's evidence per leg.
    local o="$suite/release" at
    for at in AT-FA-01 AT-FA-12 AT-FA-13; do mkdir -p "$root/build/at/$at/$date"; cp "$o/journey.log" "$root/build/at/$at/$date/"; done
    cp "$o"/gk-*.txt "$o"/log-first-run.txt "$o"/download.txt "$o"/codesign-verify.txt "$root/build/at/AT-FA-01/$date/" 2>/dev/null
    cp "$o"/appcast.txt "$o"/requests.log "$o"/sparkle-log.txt "$o"/log-upgraded.txt "$o"/pr5.txt "$o"/container-*.txt \
       "$o"/db-*.json "$o"/backups.txt "$root/build/at/AT-FA-12/$date/" 2>/dev/null
    mkdir -p "$root/build/at/AT-FA-13/$date/release-manual"
    cp "$o"/zero-files.txt "$o"/sweep.txt "$root/build/at/AT-FA-13/$date/release-manual/" 2>/dev/null
    python3 -I "$here/fa-split.py" "$o/journey.log" "$root/build/at" "$date" --form "${FORM:-dev}"
    return $r
}

host_pass() {
    local r=0
    OUT_DATE="$date" "$here/steps/fa-06-media-host.sh" || r=1
    OUT_DATE="$date" "$here/steps/fa-08-safety-host.sh" || r=1
    return $r
}

if [[ ",$passes," == *,debug,* || ",$passes," == *,release,* ]]; then
    vm_init; v=$?; [ $v = 0 ] || exit $v
fi
for p in ${passes//,/ }; do
    echo; echo "=== pass $p $(date +%T)"
    case "$p" in
        debug) debug_pass || rc=1 ;;
        release) release_pass || rc=1 ;;
        host) host_pass || rc=1 ;;
        *) echo "unknown pass $p"; exit 2 ;;
    esac
done
python3 -I "$here/fa-report.py" --date "$date" --out "$suite/summary.md" | tee -a "$suite/suite.log"
echo "final acceptance: $([ $rc = 0 ] && echo PASS || echo FAIL) → build/at/AT-FA/$date"
exit $rc
