#!/bin/bash
# ENV=tart (M8.T11 step 5): clone antichat-clean-26.x → boot headless with a virtiofs share → copy build/AntiChat.app
# into /Applications → run steps/<case>.sh through Tart's guest agent (`tart exec`: no guest IP or SSH needed; the
# host's vmnet DHCP is not available to every session) → stop and delete the clone. `reinstall` runs in the same clone
# right after `uninstall` (a reinstall only means something on a Mac that was just uninstalled).
# Tart: `tart` on PATH, else $ANTICHAT_TART, else the pinned copy under ~/.local/share/antichat-tools/tart-*/.
# Exit 3 = not run (Tart or the image is not available here; see image.lock).
set -euo pipefail
c="$1"
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
image="antichat-clean-26.x"
tart="$(command -v tart || true)"
[ -n "$tart" ] || tart="${ANTICHAT_TART:-}"
[ -n "$tart" ] || tart="$(ls -d "$HOME"/.local/share/antichat-tools/tart-*/tart.app/Contents/MacOS/tart 2>/dev/null | tail -1 || true)"
[ -x "$tart" ] || { echo "not run: tart is not installed (brew install cirruslabs/cli/tart, pinned in tools/toolchain.lock) [perm]"; exit 3; }
# The list is read whole first: `tart list | grep -q` under pipefail fails when grep exits early (SIGPIPE).
vms="$("$tart" list --format json)"
grep -q "\"$image\"" <<<"$vms" || { echo "not run: VM image $image missing (tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest $image) [perm: ~20 GB]"; exit 3; }
vm="ac-$c-$(date +%s)"
xfer="$(mktemp -d "${TMPDIR:-/tmp}/ac-xfer-XXXXXX")"
# A snapshot as one archive (a rebuild during the run cannot change it; virtiofs mishandles framework symlinks).
tar -C "$root/build" -cf "$xfer/AntiChat.app.tar" AntiChat.app
mkdir -p "$xfer/steps" && cp "$here"/steps/*.sh "$root/tools/ci/zero-files.sh" "$root/tools/ci/antichat-paths.txt" \
  "${ANTICHAT_FIXTURES:-$root/fixtures}/scripts/basic.jsonl" "$xfer/steps/"
"$tart" clone "$image" "$vm"
cleanup() { "$tart" stop "$vm" >/dev/null 2>&1 || true; "$tart" delete "$vm" >/dev/null 2>&1 || true; rm -rf "$xfer"; }
trap cleanup EXIT
"$tart" run --no-graphics --dir=xfer:"$xfer" "$vm" >"$xfer/tart-run.log" 2>&1 &
# Every guest command is bounded (15 min): under heavy host load a `tart exec` stream was seen to never return after the
# guest command had ended (M8.T16), which hung the whole suite. A timed-out step fails its case.
vx() { perl -e 'alarm shift; exec @ARGV' "${TART_STEP_TIMEOUT:-900}" "$tart" exec "$vm" /bin/bash -lc "$*"; }
for _ in $(seq 1 100); do vx true >/dev/null 2>&1 && break; sleep 3; done
vx "sw_vers; whoami; uname -m"
echo "vm $vm ($("$tart" --version 2>/dev/null))"
X="/Volumes/My Shared Files/xfer"
vx "sudo rm -rf /Applications/AntiChat.app; sudo tar -C /Applications -xf '$X/AntiChat.app.tar'; sudo chown -R admin:staff /Applications/AntiChat.app; rm -rf ~/steps; cp -R '$X/steps' ~/steps"
if [ "$c" = reinstall ]; then
  vx "bash ~/steps/uninstall.sh /Applications/AntiChat.app"
  vx "sudo tar -C /Applications -xf '$X/AntiChat.app.tar'; sudo chown -R admin:staff /Applications/AntiChat.app"  # the same build back
fi
vx "bash ~/steps/$c.sh /Applications/AntiChat.app"
echo "tart-run $c: ok"
