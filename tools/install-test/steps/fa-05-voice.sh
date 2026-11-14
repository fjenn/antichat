#!/bin/bash
# AT-FA-05 dictation + voice conversation in the clean VM. Tart has no microphone, so ScriptedVoice (fixture WAVs at
# real-time pace, environment §5) stands in for it, through the real path across the process boundary: the helper's
# STT (Parakeet), VAD (Silero), smart-turn and TTS (Kokoro) from the Voice pack the onboarding installed, and the
# installed chat model. `-Bench dictation` = the composer's dictation pipeline (capture → endpoint → final transcript);
# `-Bench voice-session --runs 3` = one 3-turn spoken conversation in one chat (transcript → streamed reply → speech).
# The first-use microphone prompt is a TCC dialog on the Release build: it needs UI automation (Q-015).
set -uo pipefail
source "$(dirname "$0")/fa-common.sh"
o="$(fa_out AT-FA-05)"
in="$ANTICHAT_FIXTURES/audio/dictation"
# The tier chat model the onboarding installed (else the starter).
chat="$(ls "$CONTAINER/Models/installs" | grep -E '^chat-' | grep -v '^chat-0\.8b$' | head -1)"
chat="${chat:-chat-0.8b}"
bench() {  # bench <name> <args…>: one headless bench launch as the app (its XPC helper), waited for
    local n="$1"; shift
    open -g -n -W "$APP" --stdout "$o/$n.out" --stderr "$o/$n.err" --args -Bench "$@"
}
bench dictation dictation --input "$in" --runs 3 --tier-cap T0 --raw "$o/dictation.jsonl"
# Every engine helper process seen during the conversation (first seen, pid): a helper that goes away mid-call is a
# failure even when a later turn recovers on a new one.
( seen=" "
  while :; do
      for p in $(pgrep -f 'XPCServices/AntiChatEngine'); do
          case "$seen" in *" $p "*) ;; *) seen+="$p "; echo "$(date +%T) $p" >> "$o/helper-pids.log" ;; esac
      done
      sleep 0.5
  done ) &
watch=$!
bench voice voice-session --input "$in" --runs 3 --model "$chat" --raw "$o/voice-session.jsonl"
kill "$watch" 2>/dev/null
python3 -I - "$o" "$in" > "$o/summary.json" <<'PY'
import json, sys, os
o, inp = sys.argv[1], sys.argv[2]
def rows(n):
    p = os.path.join(o, n)
    return [json.loads(l) for l in open(p)] if os.path.exists(p) else []
d, v = rows("dictation.jsonl"), rows("voice-session.jsonl")
dw = sum(r.get("words", 0) for r in d); de = sum(r.get("word_errors", 0) for r in d)
print(json.dumps({"dictation": {"runs": len(d), "errors": [r["error"] for r in d if r.get("error")],
                                "transcripts": [r.get("transcript", "") for r in d], "wer": de / dw if dw else None},
                  "voice": {"turns": len(v), "errors": [r["error"] for r in v if r.get("error")],
                            "pairs": [[r.get("transcript", ""), r.get("reply", "")[:200]] for r in v],
                            "v1_ms": [r.get("v1_ms") for r in v]}}, indent=1))
PY
s="$o/summary.json"
check "dictation: 3 utterances transcribed, no error" "[ \"\$(json '$s' 'j[\"dictation\"][\"runs\"]')\" -ge 3 ] && [ \"\$(json '$s' 'len(j[\"dictation\"][\"errors\"])')\" = 0 ] && [ \"\$(json '$s' 'all(t.strip() for t in j[\"dictation\"][\"transcripts\"])')\" = True ]"
check "dictation text matches the fixtures (WER $(json "$s" 'round(j["dictation"]["wer"],3)') ≤ 0.15)" "python3 -I -c 'import sys; w=\"$(json "$s" 'j["dictation"]["wer"]')\"; sys.exit(0 if w and float(w) <= 0.15 else 1)'"
check "voice conversation: 3 turns on $chat, each with a transcript and a spoken reply" "[ \"\$(json '$s' 'sum(1 for t,r in j[\"voice\"][\"pairs\"] if t.strip() and r.strip())')\" -ge 3 ] && [ \"\$(json '$s' 'len(j[\"voice\"][\"errors\"])')\" = 0 ]"
check "the engine helper stayed up for the whole conversation (one helper process)" "[ \"\$(wc -l < '$o/helper-pids.log' 2>/dev/null | tr -d ' ')\" = 1 ]"
note "microphone permission asked only on first use: the TCC dialog on the Release build needs UI automation (Q-015)"
collect_logs "$o"; fa_result "$o" AT-FA-05 "dev (Debug test build, ScriptedVoice, real STT/TTS/chat models)"
