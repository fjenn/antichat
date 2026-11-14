#!/bin/bash
# ENV=user (M8.T11 fallback): a fresh macOS user `actest` (sysadminctl -addUser, the owner's one-time admin
# approval), the app copied to its ~/Applications, steps/<case>.sh run as that user, the user deleted afterwards.
# Exit 3 = not run (no admin approval in this session).
set -euo pipefail
c="$1"
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
sudo -n true 2>/dev/null || { echo "not run: sysadminctl -addUser needs the owner's admin approval [perm]"; exit 3; }
sudo sysadminctl -addUser actest -password - -home /Users/actest >/dev/null
trap 'sudo sysadminctl -deleteUser actest >/dev/null 2>&1' EXIT
sudo -u actest mkdir -p /Users/actest/Applications /Users/actest/steps
sudo ditto "$root/build/AntiChat.app" /Users/actest/Applications/AntiChat.app
sudo cp "$here/steps/"*.sh "$root/tools/ci/zero-files.sh" "$root/tools/ci/antichat-paths.txt" /Users/actest/steps/
sudo chown -R actest /Users/actest/Applications /Users/actest/steps
sudo -u actest -i bash /Users/actest/steps/"$c".sh /Users/actest/Applications/AntiChat.app
