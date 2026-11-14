#!/bin/bash
# Shared Tart helpers for the VM suites (sourced; M10.T09 final acceptance). The base image `antichat-clean-26.x`
# (image.lock) is NEVER run, modified or deleted: every suite clones it (APFS clone, copy on write), boots the clone
# headless with one virtiofs share, drives it through Tart's guest agent (`tart exec`: no guest IP, no SSH, no host
# networking), and deletes only its own clone on exit.
# Use: source lib/vm.sh; vm_init; vm_clone <name> [memMB] [cpus]; vm_boot <share-dir>; vx '<guest cmd>'; … (trap does
# vm_cleanup). Exit 3 from vm_init = not run here (Tart or the image missing).
VM_IMAGE="${IMAGE:-antichat-clean-26.x}"
VM_SHARE="/Volumes/My Shared Files/xfer"   # where the guest sees the share

vm_init() {
    TART="$(command -v tart || true)"
    [ -n "$TART" ] || TART="${ANTICHAT_TART:-}"
    [ -n "$TART" ] || TART="$(ls -d "$HOME"/.local/share/antichat-tools/tart-*/tart.app/Contents/MacOS/tart 2>/dev/null | tail -1 || true)"
    [ -x "$TART" ] || { echo "not run: tart is not installed (tools/toolchain-sources.json)"; return 3; }
    local i
    for i in 1 2 3 4 5; do  # other tracks' tart operations can hold the lock briefly
        "$TART" get "$VM_IMAGE" >/dev/null 2>&1 && return 0
        sleep 3
    done
    echo "not run: VM image $VM_IMAGE missing (tools/install-test/image.lock)"; return 3
}

# vm_clone <name> [memory MB] [cpus]: a fresh clone; the name must not be the base image.
vm_clone() {
    VM_NAME="$1"
    [ "$VM_NAME" != "$VM_IMAGE" ] || { echo "refusing to use the base image itself" >&2; return 1; }
    "$TART" clone "$VM_IMAGE" "$VM_NAME"
    "$TART" set "$VM_NAME" --memory "${2:-16384}" --cpu "${3:-6}" --display 1440x900
}

# vm_boot <log> <share dir> [name:dir[:ro] …]: headless boot with the `xfer` share (+ more), waits for the guest
# agent (≤ 5 min). Shares appear in the guest under /Volumes/My Shared Files/<name>.
vm_boot() {
    local log="$1" xfer="$2"; shift 2
    local dirs=(--dir=xfer:"$xfer") d
    for d in "$@"; do dirs+=(--dir="$d"); done
    "$TART" run --no-graphics "${dirs[@]}" "$VM_NAME" > "$log" 2>&1 &
    VM_PID=$!
    local i
    for i in $(seq 1 100); do vx true >/dev/null 2>&1 && return 0; sleep 3; done
    echo "the guest agent never answered" >&2; return 1
}

# vx '<cmd>': run in the guest's login shell as admin (the auto-logged-in console user). Every call is bounded
# (TART_STEP_TIMEOUT, default 15 min): under heavy host load a `tart exec` stream was seen to never return (M8.T16).
vx() { perl -e 'alarm shift; exec @ARGV' "${TART_STEP_TIMEOUT:-900}" "$TART" exec "$VM_NAME" /bin/zsh -lc "$*"; }

# Deletes the clone (never the base image).
vm_cleanup() {
    [ -n "${VM_NAME:-}" ] || return 0
    [ "$VM_NAME" != "$VM_IMAGE" ] || return 0
    [ "${KEEP:-0}" != 1 ] || { echo "KEEP=1: clone $VM_NAME left for inspection (tart delete $VM_NAME)"; return 0; }
    "$TART" stop "$VM_NAME" >/dev/null 2>&1 || true
    "$TART" delete "$VM_NAME" >/dev/null 2>&1 || true
    VM_NAME=""
}
