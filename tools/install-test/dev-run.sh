#!/bin/bash
# ENV=dev pre-check (M8.T10 AT-NFR-D7 last sentence; M8.T11 dev-container dry run): build/AntiChat.app (Debug) against
# a scratch tree — ANTICHAT_ROOT (every ~/Library path) + -ANTICHAT_DEV_CONTAINER — seeded with a DB, media, caches,
# logs, a moved Models folder and Keychain items, then the case's hook, then zero-files.sh over the same tree.
# The login item, the Trash and the real defaults domain are not touched here (that leg needs ENV=tart / user).
set -euo pipefail
c="$1"
root="$(cd "$(dirname "$0")/../.." && pwd)"
app="$root/build/AntiChat.app/Contents/MacOS/AntiChat"
[ -x "$app" ] || { echo "make build first"; exit 1; }
scratch="$(mktemp -d "${TMPDIR:-/tmp}/actest-$c-XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
container="$scratch/Library/Application Support/AntiChat-Dev"
moved="$scratch/Volumes/ACTEST/Models"
mkdir -p "$container/Media/2026" "$container/Backups" "$scratch/Library/Caches/AntiChat/router" "$scratch/Library/Logs/AntiChat-Dev/app" \
  "$moved/store/sha256/ab" "$scratch/Library/Logs/DiagnosticReports" "$scratch/tmp/AntiChat-incognito-1" "$scratch/Library/WebKit/app.antichat.AntiChat.dev"
head -c 200000 /dev/urandom > "$container/Media/2026/a.png"
head -c 50000 /dev/urandom > "$container/Backups/daily-20261101.sqlite"
head -c 30000 /dev/urandom > "$scratch/Library/Caches/AntiChat/router/p.bin"
echo log > "$scratch/Library/Logs/AntiChat-Dev/app/app.log"
echo crash > "$scratch/Library/Logs/DiagnosticReports/AntiChat-2026-11-05.ips"
echo keep > "$scratch/Library/Logs/DiagnosticReports/Other-2026-11-05.ips"
head -c 100000 /dev/urandom > "$moved/store/sha256/ab/abcd"
svc="app.antichat.devrun-$$"
# -A: any app may delete it, like an item the app wrote itself
security add-generic-password -A -s "$svc.mcp.test" -a token -w x -U >/dev/null
# The moved Models folder: the bookmark lives in the (isolated) defaults of this dev container run.
hook="-RunRemoveEverything"; [ "$c" = remove-everything ] || hook="-RunUninstall"
[ "$c" = reinstall ] && hook="-RunUninstall"
ANTICHAT_ROOT="$scratch" ANTICHAT_MODELS_FOLDER="$moved" ANTICHAT_KEYCHAIN_PREFIX="$svc." \
  "$app" -ANTICHAT_DEV_CONTAINER "$container" "$hook" YES -UninstallKeepBundle YES
if [ "$c" != remove-everything ]; then
  # The waiter runs after the process exited; give it the AT's 10 s.
  for _ in $(seq 1 50); do [ -e "$container" ] || break; sleep 0.2; done
fi
if [ "$c" = reinstall ]; then
  # The same build launched again over the emptied tree: the hook exits before onboarding writes anything, and the
  # tree is still empty (the shortcut / login-item legs need ENV=tart or ENV=user: a dev run never touches them).
  ANTICHAT_ROOT="$scratch" "$app" -ANTICHAT_DEV_CONTAINER "$container" -PrintLoginItemStatus YES
fi
"$root/tools/ci/zero-files.sh" --paths "$root/tools/ci/antichat-paths.txt" --root "$scratch" --models "$moved" \
  --bundle-id app.antichat.AntiChat.dev --keychain-prefix "$svc."
[ -e "$scratch/Library/Logs/DiagnosticReports/Other-2026-11-05.ips" ] || { echo "removed a file outside the list"; exit 1; }
echo "dev-run $c: ok"
