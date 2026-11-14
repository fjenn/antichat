#!/bin/zsh
# AT-291 AC2 idle-sleep leg (M4.T04): during a 60 s scripted media job (60 steps × 1000 ms through the real XPC helper,
# ScriptedImageEngine, no weights) `pmset -g assertions` shows a PreventUserIdleSystemSleep line named "AntiChat media
# job", and none 5 s after the job ended. Samples every 5 s around MediaJobQueueXPCTests/testSleepAssertionDuringJob
# (which also asserts both ends itself). Exit 0 iff seen during and absent after. Log: build/at/AT-291/sleep-assertion.log.
# (The app-turn variant — a scripted chat turn calling create_image — needs the create_image tool, M4.T06.)
set -u
ROOT="${0:A:h:h:h}"
OUT="$ROOT/build/at/AT-291"; mkdir -p "$OUT"; LOG="$OUT/sleep-assertion.log"; : > "$LOG"
SAMPLES="$OUT/sleep-assertion.samples"; : > "$SAMPLES"
( while true; do echo "$(date +%T) $(pmset -g assertions | grep -cE 'PreventUserIdleSystemSleep.*AntiChat media job')" >> "$SAMPLES"; sleep 5; done ) &
SAMPLER=$!
(cd "$ROOT" && TEST_RUNNER_ANTICHAT_SLEEP_JOB_STEPS=60 make test-integration-stub FILTER=MediaJobQueueXPCTests/testSleepAssertionDuringJob) > "$OUT/sleep-assertion-tests.log" 2>&1
RC=$?
sleep 5
kill $SAMPLER 2>/dev/null; wait $SAMPLER 2>/dev/null
SEEN=$(awk '$2 > 0' "$SAMPLES" | wc -l | tr -d ' ')
LEFT=$(pmset -g assertions | grep -cE 'PreventUserIdleSystemSleep.*AntiChat media job')
{ cat "$SAMPLES"; echo "tests rc=$RC, samples with the assertion during the run: $SEEN, 5 s after: $LEFT"; } | tee "$LOG"
rm -f "$SAMPLES"
[ "$RC" = 0 ] && [ "${SEEN:-0}" -gt 0 ] && [ "$LEFT" = 0 ]
