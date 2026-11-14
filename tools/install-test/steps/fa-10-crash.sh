#!/bin/bash
# AT-FA-10 crash recovery in the clean VM (FinalAcceptanceProbe legs crash-stream / idle / crash-check / engine-kill):
#   a. a long reply streams and a draft is typed → `kill -9` the app;
#   b. a real crash for the crash prompt: an idle launch gets SIGSEGV (macOS writes its .ips report; kill -9 writes
#      none), with Settings › Privacy › Crash reports = Ask;
#   c. relaunch: the chat reopens, the partial reply says "Response interrupted." with Retry, the draft is back, the
#      crash prompt is up, nothing was sent without a tap; Retry answers;
#   d. `kill -9` the engine helper mid-reply → the S-25 `engine.restarted` notice + Retry within NFR-S4.
set -uo pipefail
source "$(dirname "$0")/fa-common.sh"
o="$(fa_out AT-FA-10)"; p="$HOME/fa/crash"; e="$HOME/fa/engine-kill"; rm -rf "$p" "$e"; mkdir -p "$p" "$e"
defaults write "$DOMAIN" crashReportMode ask

wait_file() { for _ in $(seq 1 "$2"); do [ -f "$1" ] && return 0; sleep 1; done; return 1; }
start() {  # start <dir> <leg>: a probe launch left running (the script ends it)
    rm -f "$1/probe.json" "$1/streaming.json"; printf '%s\n' "$2" > "$1/leg"
    # No -ApplePersistenceIgnoreState here or on the relaunch: the chat must reopen the way a user's app does (window
    # state restoration, and after a kill the app's own LastShownChatStore). The idle launch below ignores the saved
    # state (both: -ApplePersistenceIgnoreState turns the store off too), so it cannot replace it.
    open -g -n "$APP" --stderr "$1/app-$2.log" --args -FinalAcceptanceProbe "$1"
}

echo "a. stream, draft, kill -9"
start "$p" crash-stream
wait_file "$p/streaming.json" 1200 && sleep 1
cp "$p/streaming.json" "$o/" 2>/dev/null
[ -f "$p/probe.json" ] && mv "$p/probe.json" "$o/stream-probe.json"   # the leg ended by itself: keep why
pid=$(pgrep -f "$BIN" | head -1); echo "kill -9 $pid"; kill -9 "$pid"
for _ in $(seq 1 20); do pgrep -f "$BIN" >/dev/null || break; sleep 0.5; done
check "the app was streaming when it was killed ($(json "$p/streaming.json" 'j["chars"]') chars)" "[ -f '$p/streaming.json' ] && ! pgrep -f '$BIN' >/dev/null"

echo "b. idle launch, SIGSEGV"
ips_before=$(ls ~/Library/Logs/DiagnosticReports/AntiChat* 2>/dev/null | wc -l)
mkdir -p "$p/idle"; printf 'idle\n' > "$p/idle/leg"
open -g -n "$APP" --stderr "$p/idle/app.log" --args -ApplePersistenceIgnoreState YES -FinalAcceptanceProbe "$p/idle"
sleep 15; pid=$(pgrep -f "$BIN" | head -1); echo "kill -SEGV $pid"; kill -SEGV "$pid"
for _ in $(seq 1 240); do [ "$(ls ~/Library/Logs/DiagnosticReports/AntiChat* 2>/dev/null | wc -l)" -gt "$ips_before" ] && break; sleep 1; done
pkill -KILL -f "$BIN" 2>/dev/null || true
ls -la ~/Library/Logs/DiagnosticReports/ > "$o/diagnostic-reports.txt" 2>&1
check "macOS wrote a crash report for the crash" "[ \"\$(ls ~/Library/Logs/DiagnosticReports/AntiChat* 2>/dev/null | wc -l)\" -gt $ips_before ]"

echo "c. relaunch"
sent_before=$(ls "$CONTAINER/Diagnostics"/crash-report-*.txt 2>/dev/null | wc -l)
printf 'crash-check\n' > "$p/leg"; rm -f "$p/probe.json"
open -g -n "$APP" --stderr "$p/app-crash-check.log" --args -FinalAcceptanceProbe "$p"
for _ in $(seq 1 1200); do [ -f "$p/probe.json" ] && ! pgrep -f "$BIN" >/dev/null && break; sleep 1; done
app_quit
cp -R "$p/." "$o/"
j="$o/probe.json"
check "the chat reopened after the kill" "[ \"\$(json '$j' 'j[\"reopenedChat\"]')\" = True ]"
# An interrupted row is what the view renders as InterruptedNotice ("Response interrupted." + Retry,
# AssistantMessageView); the Retry anchor itself is reported when the row is laid out on screen.
check "partial reply kept as interrupted ($(json "$j" 'j["partialChars"]') chars → \"Response interrupted.\" + Retry)" "[ \"\$(json '$j' 'j[\"replyStatus\"]')\" = interrupted ] && [ \"\$(json '$j' 'j[\"partialChars\"]')\" -gt 0 ]"
[ "$(json "$j" 'j["retryShown"]')" = True ] || note "the Retry button laid out on screen (anchor not seen in the background window; RC visual QA)"
check "draft kept" "[ \"\$(json '$j' 'j[\"draftRestored\"]')\" = True ]"
check "crash prompt shown (Crash reports = Ask)" "[ \"\$(json '$j' 'j[\"crashPromptShown\"]')\" = True ]"
check "nothing sent without a tap (no crash-report file written)" "[ \"\$(ls '$CONTAINER/Diagnostics'/crash-report-*.txt 2>/dev/null | wc -l)\" -eq $sent_before ]"
check "Retry answers again" "[ \"\$(json '$j' 'j[\"retryStatus\"]')\" = done ]"

echo "d. kill -9 the engine helper mid-reply"
start "$e" engine-kill
wait_file "$e/streaming.json" 1200 && sleep 1
hp=$(pgrep -x AntiChatEngine | head -1); echo "kill -9 helper $hp"
python3 -I -c 'import time; print(time.time())' > "$e/killed"; kill -9 "$hp"
for _ in $(seq 1 1200); do [ -f "$e/probe.json" ] && ! pgrep -f "$BIN" >/dev/null && break; sleep 1; done
app_quit
mkdir -p "$o/engine-kill"; cp -R "$e/." "$o/engine-kill/"
k="$o/engine-kill/probe.json"
check "the reply ends engine.restarted after the helper died (the S-25 notice + Retry row)" "[ \"\$(json '$k' 'j[\"engineRestartedErrorCode\"]')\" = True ]"
[ "$(json "$k" 'j["noticeShown"]')" = True ] || note "the engine.restarted notice laid out on screen (anchor not seen in the background window; RC visual QA)"
# Correctness only in the VM (paravirtual GPU, ci-release §9); NFR-S4 timing is measured on hardware (M9.T05).
echo "kill → notice $(json "$k" 'round(j["killToNoticeS"],2)') s (VM; informational, NFR-S4 bar 5 s on hardware)"
check "the engine came back: notice within 15 s of the kill ($(json "$k" 'round(j["killToNoticeS"],2)') s)" "python3 -I -c 'import sys; v=\"$(json "$k" 'j["killToNoticeS"]')\"; sys.exit(0 if v and float(v) <= 15 else 1)'"
check "Retry streams again (first token after $(json "$k" 'round(j["retryToFirstTokenS"],2)') s)" "[ -n \"\$(json '$k' 'j[\"retryToFirstTokenS\"]')\" ]"
collect_logs "$o"; fa_result "$o" AT-FA-10 "dev (Debug test build, clean VM, real models)"
