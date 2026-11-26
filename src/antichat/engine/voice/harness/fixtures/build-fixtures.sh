#!/bin/bash
# Builds the speech fixtures for the voice harness: macOS `say` voices,
# 16 kHz mono 16-bit WAV, plus noise variants (mix-noise.js, seeded).
#   src/antichat/engine/voice/harness/fixtures/build-fixtures.sh
# Output: *.wav and manifest.json next to this script. Re-running rewrites them.
set -euo pipefail
cd "$(dirname "$0")"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ROWS=()

speak() { # id voice lang kind text
  local id="$1" voice="$2" lang="$3" kind="$4" text="$5"
  say -v "$voice" -o "$TMP/$id.aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/$id.aiff" "$id.wav"
  ROWS+=("$(node -e 'const [id,voice,lang,kind,text]=process.argv.slice(1);process.stdout.write(JSON.stringify({id,file:id+".wav",voice,lang,kind,text}))' "$id" "$voice" "$lang" "$kind" "$text")")
}

speak en-us-capital   "Samantha" en utterance "What is the capital of France, and how many people live there?"
speak en-gb-timer     "Daniel"   en utterance "Set a timer for fifteen minutes and remind me to call my sister."
speak en-au-plants    "Karen"    en utterance "Can you explain how photosynthesis works in simple terms?"
speak en-in-recipe    "Rishi"    en utterance "I need a recipe for dinner tonight with chicken, rice and vegetables."
speak en-ie-trip      "Moira"    en utterance "We are planning a trip to Portugal in September. Which cities should we visit first?"
speak de-de-wetter    "Anna"     de utterance "Wie wird das Wetter morgen in Berlin, und brauche ich einen Regenschirm?"
speak es-es-idioma    "Mónica"   es utterance "¿Cuál es la mejor manera de aprender un idioma nuevo rápidamente?"
speak fr-fr-livre     "Thomas"   fr utterance "Peux-tu me recommander un bon livre à lire pendant les vacances ?"
speak en-us-bargein   "Samantha" en bargein   "Wait, stop. Tell me about Italy instead."
speak en-us-reply     "Daniel"   en tts       "The capital of France is Paris. About two million people live in the city itself, and more than ten million in the wider region. It has been the capital for over a thousand years."
speak en-us-long      "Samantha" en long      "This is a longer dictation to check that nothing is cut off. [[slnc 900]] First, I went to the market and bought apples, bread and cheese. [[slnc 1200]] Then I walked home along the river, because the weather was warm and the trees were green. [[slnc 1000]] After lunch I wrote three letters to old friends. One of them lives in Canada, another in Japan, and the third just moved to Norway. [[slnc 1500]] In the evening we cooked pasta with tomatoes and garlic, and we talked about the plans for next year. [[slnc 900]] Finally, I read a few pages of a book about the history of the railway, and then I went to sleep."

node mix-noise.js en-us-capital 15 1 && ROWS+=('{"id":"en-us-capital-snr15","file":"en-us-capital-snr15.wav","voice":"Samantha","lang":"en","kind":"utterance","noiseSnrDb":15,"text":"What is the capital of France, and how many people live there?"}')
node mix-noise.js en-us-capital 5 2  && ROWS+=('{"id":"en-us-capital-snr5","file":"en-us-capital-snr5.wav","voice":"Samantha","lang":"en","kind":"utterance","noiseSnrDb":5,"text":"What is the capital of France, and how many people live there?"}')
node mix-noise.js en-gb-timer 10 3   && ROWS+=('{"id":"en-gb-timer-snr10","file":"en-gb-timer-snr10.wav","voice":"Daniel","lang":"en","kind":"utterance","noiseSnrDb":10,"text":"Set a timer for fifteen minutes and remind me to call my sister."}')
node mix-noise.js de-de-wetter 10 4  && ROWS+=('{"id":"de-de-wetter-snr10","file":"de-de-wetter-snr10.wav","voice":"Anna","lang":"de","kind":"utterance","noiseSnrDb":10,"text":"Wie wird das Wetter morgen in Berlin, und brauche ich einen Regenschirm?"}')
node mix-noise.js --noise-only room-noise 4 5 && ROWS+=('{"id":"room-noise","file":"room-noise.wav","voice":"","lang":"","kind":"noise","text":""}')

printf '[\n' > manifest.json
for i in "${!ROWS[@]}"; do
  [ "$i" -gt 0 ] && printf ',\n' >> manifest.json
  printf '  %s' "$(printf '%s' "${ROWS[$i]}" | sed 's/\[\[slnc [0-9]*\]\] //g')" >> manifest.json
done
printf '\n]\n' >> manifest.json
ls -la *.wav | awk '{s+=$5} END {print NR " files, " s/1e6 " MB"}'
