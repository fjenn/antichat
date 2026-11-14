#!/bin/bash
# Inside the VM / fresh user: a real launch, seed the login item + shortcuts, Remove everything through the hook,
# then zero files (paths, Keychain, defaults) while the app bundle stays (Remove everything keeps it).
set -euo pipefail
app="$1"; source "$(cd "$(dirname "$0")" && pwd)/common.sh"
launch_once
"$bin" -SeedLoginItem YES; "$bin" -SeedShortcuts YES
"$bin" -RunRemoveEverything YES
zero
[ -d "$app" ] || { echo "Remove everything must keep the app"; exit 1; }
"$bin" -PrintShortcuts YES | grep -q "=custom" && { echo "shortcut left"; exit 1; }
echo "remove-everything: ok"
