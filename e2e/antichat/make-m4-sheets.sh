#!/bin/bash
# Builds the M4 contact sheets (iOS and Android, light and dark, largest
# text) from the latest run.sh screenshots of the history flows.
#
#   e2e/antichat/make-m4-sheets.sh [out-dir]     default: docs/antichat/m4
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$ROOT/docs/antichat/m4}"
SHOTS="$HERE/screenshots"
REF="$ROOT/docs/research/assets/chatgpt"
mkdir -p "$OUT"

sheet() { # name height [label=path ...]; missing files are skipped
  local name="$1" height="$2"; shift 2
  local tiles=()
  for tile in "$@"; do [ -f "${tile#*=}" ] && tiles+=("$tile"); done
  [ ${#tiles[@]} -gt 0 ] || return 0
  swift "$HERE/scripts/contact-sheet.swift" "$OUT/$name.jpg" "$height" "${tiles[@]}" >/dev/null
  echo "$OUT/$name.jpg"
}

four() { # name shot [extra tiles...]
  local name="$1" shot="$2"; shift 2
  sheet "$name" 1100 "$@" \
    "iOS light=$SHOTS/ios-light/$shot.png" "Android light=$SHOTS/android-light/$shot.png" \
    "iOS dark=$SHOTS/ios-dark/$shot.png" "Android dark=$SHOTS/android-dark/$shot.png"
}

four 01-drawer 40-drawer
four 02-row-menu 41-row-menu
four 03-row-rename 42-row-rename
four 04-row-swipe 44-row-swipe
four 05-delete-undo 45-deleted-undo
four 06-search-empty 50-search-empty
four 07-search-results 51-search-results
four 08-search-none 53-search-none
four 09-search-hit-open 54-search-hit-open
four 10-search-recent 55-search-recent
four 11-chat-menu 60-chat-menu "ChatGPT top bar (reference)=$REF/appstore-iphone-03.jpg"
four 12-branched 61-branched-drawer
four 13-rename-dialog 62-rename-dialog
four 14-share-sheet 63-share-sheet
four 15-archived 64-archived
four 16-archived-empty 65-archived-empty
four 17-temporary-empty 70-temporary-empty "ChatGPT temporary icon (reference)=$REF/screensdesign-c53e2b44a5d94d70b4255666cd06bcd5.webp"
four 18-temporary-chat 71-temporary-chat
four 19-temporary-not-found 72-temporary-not-found
four 20-locked-gate 80-locked-gate
four 21-locked-row 81-locked-row
sheet 22-largest-text 1100 \
  "iOS drawer=$SHOTS/ios-light-large/40-drawer.png" "Android drawer=$SHOTS/android-light-large/40-drawer.png" \
  "iOS search=$SHOTS/ios-light-large/51-search-results.png" "Android search=$SHOTS/android-light-large/51-search-results.png" \
  "iOS temporary=$SHOTS/ios-light-large/70-temporary-empty.png" "Android temporary=$SHOTS/android-light-large/70-temporary-empty.png"
sheet 23-largest-text-more 1100 \
  "iOS rename=$SHOTS/ios-light-large/62-rename-dialog.png" "Android rename=$SHOTS/android-light-large/62-rename-dialog.png" \
  "iOS share=$SHOTS/ios-light-large/63-share-sheet.png" "Android share=$SHOTS/android-light-large/63-share-sheet.png" \
  "iOS locked=$SHOTS/ios-light-large/80-locked-gate.png" "Android locked=$SHOTS/android-light-large/80-locked-gate.png"
sheet 24-drawer-2000 1100 \
  "iOS 2,000 chats=$SHOTS/ios-light/91-drawer-2000.png" "Android 2,000 chats=$SHOTS/android-light/91-drawer-2000.png" \
  "iOS frames=$SHOTS/ios-light/92-perf-result.png" "Android frames=$SHOTS/android-light/92-perf-result.png"
