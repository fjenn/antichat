#!/bin/bash
# AT-FA-13 uninstall cleans up, in the clean VM at the end of the debug pass (models, chats, imports, Evil chats,
# crash reports and settings of AT-FA-02…11 all present): the menu's Uninstall AntiChat… path (UninstallService.run +
# Trash, through the DEBUG -RunUninstall hook = the confirmed sheet's action; the sheet itself needs UI automation,
# Q-015), then the AT-226 assertions of steps/uninstall.sh: zero files (paths, Keychain, defaults), app in the Trash,
# no login item left. The Release build's documented manual way runs in the release pass (vm-release-smoke.sh step 4).
set -uo pipefail
source "$(dirname "$0")/fa-common.sh"
o="$(fa_out AT-FA-13)"
du -sh "$CONTAINER" > "$o/container-before.txt" 2>&1
ls "$CONTAINER/Models/installs" >> "$o/container-before.txt" 2>&1
app_quit
bash "$STEPS/uninstall.sh" "$APP" > "$o/uninstall.log" 2>&1; rc=$?
tail -5 "$o/uninstall.log"
# CrashReporter/<app>_<uuid>.plist is macOS's own crash-report bookkeeping (written because AT-FA-10 crashes the app on
# purpose), not app data.
find "$HOME/Library" -maxdepth 4 \( -iname '*antichat*' -o -iname 'app.antichat.*' \) -not -path '*/.Trash/*' -not -path '*/Application Support/CrashReporter/*' > "$o/sweep.txt" 2>/dev/null
check "Uninstall: zero files, app in the Trash, no login item (steps/uninstall.sh)" "[ $rc = 0 ] && grep -q 'uninstall: ok' '$o/uninstall.log'"
check "no undocumented AntiChat files left in ~/Library" "[ ! -s '$o/sweep.txt' ]"
note "the Uninstall sheet (type UNINSTALL) itself: UI automation (Q-015); its action ran through the hook"
fa_result "$o" AT-FA-13 "dev (Debug test build: Uninstall action via hook; Release manual way in the release pass)"
