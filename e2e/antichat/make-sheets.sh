#!/bin/bash
# Builds the paired contact sheets (iOS and Android, light and dark, with the
# ChatGPT reference where there is one) from the latest run.sh screenshots.
#
#   e2e/antichat/make-sheets.sh [out-dir]     default: docs/antichat/m1
#
# REF_DIR: folder with the ChatGPT reference images
#          (default docs/research/assets/chatgpt of this checkout, else of
#          the main checkout next to a worktree).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$ROOT/docs/antichat/m1}"
SHOTS="$HERE/screenshots"
REF="${REF_DIR:-$ROOT/docs/research/assets/chatgpt}"
[ -d "$REF" ] || REF="$(git -C "$ROOT" worktree list --porcelain | sed -n '1s/^worktree //p')/docs/research/assets/chatgpt"
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

four 01-chat-empty 01-chat-empty "ChatGPT (reference)=$REF/screensdesign-14dcb5612f2d469eaf36ecbb0c681c53.webp"
four 02-drawer 02-drawer
four 03-chat-thread 03-chat-thread "ChatGPT iOS (reference)=$REF/appstore-iphone-03.jpg" "ChatGPT Android (reference)=$REF/playstore-02.jpg"
four 04-settings 04-settings
four 05-primitives-1 05-gallery-1
four 06-primitives-2 06-gallery-2
four 07-primitives-3 07-gallery-3
four 08-sheet 08-sheet
four 09-primitives-4 09-gallery-4
four 10-streamed-answer 31-streamed
sheet 11-live-theme-switch 1100 \
  "iOS: system light, forced dark + green=$SHOTS/ios-light/20-forced-dark-green.png" \
  "Android: same=$SHOTS/android-light/20-forced-dark-green.png" \
  "iOS: system dark, forced light + purple=$SHOTS/ios-dark/21-forced-light-purple.png" \
  "Android: same=$SHOTS/android-dark/21-forced-light-purple.png" \
  "iOS: purple bubble=$SHOTS/ios-light/22-thread-purple.png" \
  "Android: purple bubble=$SHOTS/android-light/22-thread-purple.png"
sheet 12-largest-text 1100 \
  "iOS chat=$SHOTS/ios-light-large/01-chat-empty.png" "Android chat=$SHOTS/android-light-large/01-chat-empty.png" \
  "iOS drawer=$SHOTS/ios-light-large/02-drawer.png" "Android drawer=$SHOTS/android-light-large/02-drawer.png" \
  "iOS settings=$SHOTS/ios-light-large/04-settings.png" "Android settings=$SHOTS/android-light-large/04-settings.png"
sheet 13-largest-text-primitives 1100 \
  "iOS=$SHOTS/ios-light-large/05-gallery-1.png" "Android=$SHOTS/android-light-large/05-gallery-1.png" \
  "iOS=$SHOTS/ios-light-large/06-gallery-2.png" "Android=$SHOTS/android-light-large/06-gallery-2.png" \
  "iOS=$SHOTS/ios-light-large/07-gallery-3.png" "Android=$SHOTS/android-light-large/07-gallery-3.png"
