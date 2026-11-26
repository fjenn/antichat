#!/bin/bash
# Builds M6's paired contact sheets from the latest run-m6.sh screenshots:
# iOS and Android, light and dark, with the ChatGPT reference where one
# exists; plus largest text and small/large phones.
#
#   e2e/antichat/make-sheets-m6.sh [out-dir]     default: docs/antichat/m6
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$ROOT/docs/antichat/m6}"
SHOTS="$HERE/screenshots"
REF="${REF_DIR:-$ROOT/docs/research/assets/chatgpt}"
mkdir -p "$OUT"

sheet() { # name height [label=path ...]; missing files are skipped
  local name="$1" height="$2"; shift 2
  local tiles=()
  for tile in "$@"; do [ -f "${tile#*=}" ] && tiles+=("$tile"); done
  [ ${#tiles[@]} -gt 0 ] || return 0
  swift "$HERE/scripts/contact-sheet.swift" "$OUT/$name.jpg" "$height" "${tiles[@]}"
  echo "$OUT/$name.jpg"
}

four() { # name shot [extra tiles...]
  local name="$1" shot="$2"; shift 2
  sheet "$name" 1100 "$@" \
    "iOS light=$SHOTS/ios-light/$shot.png" "Android light=$SHOTS/android-light/$shot.png" \
    "iOS dark=$SHOTS/ios-dark/$shot.png" "Android dark=$SHOTS/android-dark/$shot.png"
}

sizes() { # name shot: largest text, a small phone and a large phone
  local name="$1" shot="$2"
  sheet "$name" 1100 \
    "iOS largest text=$SHOTS/ios-light-large/$shot.png" "Android largest text=$SHOTS/android-light-large/$shot.png" \
    "iOS small phone=$SHOTS/ios-light-small/$shot.png" "Android small phone=$SHOTS/android-light-small/$shot.png" \
    "iOS large phone=$SHOTS/ios-light/$shot.png" "Android large phone=$SHOTS/android-light-big/$shot.png"
}

four 01-welcome 60-welcome "ChatGPT signed out (reference)=$REF/screensdesign-14dcb5612f2d469eaf36ecbb0c681c53.webp"
four 02-downloading 61-downloading
four 03-download-paused 62-download-paused
four 04-details 63-details
four 05-ready 64-ready
four 06-first-chat 65-first-chat
four 07-model-menu 66-model-menu
four 08-mobile-data 67-mobile-data
four 09-waiting-wifi 68-waiting-wifi
four 10-offline 69-offline
four 11-not-enough-space 95-not-enough-space
four 12-download-stopped 96-download-stopped
four 20-settings 70-settings "ChatGPT Android (reference)=$REF/androidpolice-2026-11-04.jpg"
four 21-general 71-general
four 22-personalization 72-personalization "ChatGPT Android (reference)=$REF/androidpolice-2026-11-05.jpg"
four 23-personalization-2 73-personalization-2
four 24-memories 74-memories
four 25-voice 75-voice "ChatGPT Android (reference)=$REF/androidpolice-2026-11-07.jpg"
four 26-data-controls 76-data-controls
four 27-archived 77-archived
four 28-delete-all 78-delete-all
four 30-models 80-models
four 31-models-download-paused 88-models-download-paused
four 32-model-delete 89-model-delete
four 33-models-after-delete 90-models-after-delete
four 34-unrestricted-consent 91-unrestricted-consent
four 35-unrestricted-downloading 92-unrestricted-downloading
four 36-storage 81-storage
four 37-capabilities 82-capabilities
four 40-privacy 83-privacy
four 41-about 84-about
four 42-licences 85-licences
four 43-licence 86-licence
four 44-advanced 87-advanced
four 45-persisted-general 93-persisted-general
four 46-persisted-personalization 94-persisted-personalization
sizes 50-sizes-welcome 60-welcome
sizes 51-sizes-download 62-download-paused
sizes 52-sizes-settings 70-settings
sizes 53-sizes-general 71-general
sizes 54-sizes-personalization 72-personalization
sizes 55-sizes-models 80-models
sizes 56-sizes-data-controls 76-data-controls
sizes 57-sizes-capabilities 82-capabilities
