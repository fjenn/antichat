#!/bin/bash
# Inside the VM / fresh user: a real launch (container, caches, logs), seed the login item + non-default shortcuts,
# Uninstall through the hook (exactly the confirmed sheet's path), wait for the detached waiter, then: zero files
# (paths, Keychain, defaults domain), the app in the Trash, no login item (sfltool with the VM's passwordless sudo).
set -euo pipefail
app="$1"; source "$(cd "$(dirname "$0")" && pwd)/common.sh"
launch_once
"$bin" -SeedLoginItem YES; "$bin" -SeedShortcuts YES
"$bin" -PrintShortcuts YES | grep -q "quickPanel=custom" || { echo "precondition: shortcut not seeded"; exit 1; }
if sudo -n true 2>/dev/null; then
  echo "login items before: $(sudo sfltool dumpbtm | grep -ci antichat)"; sudo sfltool dumpbtm | grep -i -B6 -A14 antichat
fi
"$bin" -RunUninstall YES
sleep 10
zero
trash=( "$HOME"/.Trash/AntiChat*.app )
[ "${#trash[@]}" = 1 ] && [ -d "${trash[0]}" ] || { echo "AntiChat.app not in the Trash"; exit 1; }
[ ! -e "$app" ] || { echo "the app is still in /Applications"; exit 1; }
# Login item: unregister() flips the app's BTM record to `disabled`; backgroundtaskmanagementd keeps the record
# itself (no API removes it; it is pruned once the app is gone). Left = an AntiChat record still `enabled`.
if sudo -n true 2>/dev/null; then
  enabled="$(sudo sfltool dumpbtm | awk '/^ *#[0-9]+:$/ {d=""; a=0} /[Aa]nti[Cc]hat/ {a=1} /Disposition:/ {d=$0}
    a && d ~ /\[enabled/ {print d; a=0}' | sort -u)"
  echo "login items after: AntiChat records still enabled: ${enabled:-none}"
  [ -z "$enabled" ] || { echo "login item left:"; sudo sfltool dumpbtm | grep -i -B6 -A14 antichat; exit 1; }
fi
echo "uninstall: ok"
