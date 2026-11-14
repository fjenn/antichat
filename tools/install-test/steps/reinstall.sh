#!/bin/bash
# Right after uninstall (same VM): the same build back in /Applications, a clean start — no container or defaults
# domain before the first launch, no login item, every shortcut nil or at its default (none custom).
# The file checks come first: running the app's print hooks registers the shortcut names, and KeyboardShortcuts
# stores each name's default combo in the defaults domain (M8.T16 Tart run).
set -euo pipefail
app="$1"; source "$(cd "$(dirname "$0")" && pwd)/common.sh"
for d in "Application Support/AntiChat-Dev" "Application Support/AntiChat" "Caches/AntiChat"; do
  [ ! -e "$HOME/Library/$d" ] || { echo "stale $d"; exit 1; }
done
defaults read "$bundle" >/dev/null 2>&1 && { echo "stale defaults domain"; exit 1; }
"$bin" -PrintLoginItemStatus YES | tee /dev/stderr | grep -q "loginItem=notRegistered\|loginItem=notFound"
shortcuts="$("$bin" -PrintShortcuts YES)"; echo "$shortcuts"
if grep -q "=custom" <<<"$shortcuts"; then echo "shortcut left after reinstall"; exit 1; fi
echo "reinstall: ok"
