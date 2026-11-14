#!/bin/bash
# M9.T05 hard precondition: Low Power Mode throttles CPU and GPU, also on AC (≈ 2.7× slower timing numbers seen
# 2026-11-09 with `pmset -g custom` powermode 1 on AC). Prints the live mode; --require-off exits 1 when it is on.
# Only the owner changes it: `sudo pmset -c powermode 0`, or System Settings › Battery › Low Power Mode: Only on
# Battery / Never. An agent never changes this setting.
mode=$(pmset -g | awk '/^ *(lowpowermode|powermode) / {m=$2} END {print m}')
echo "powermode ${mode:-unknown} (pmset -g; 0 automatic, 1 low power, 2 high power)"
pmset -g custom | awk '/^(AC|Battery) Power/ {src=$1} / powermode / {print "  " src ": powermode " $2}'
if [ "${1:-}" = "--require-off" ] && [ "${mode:-0}" = 1 ]; then
  echo "Low Power Mode is ON: T05 timing numbers would be throttled. Owner: sudo pmset -c powermode 0" \
       "(or System Settings > Battery > Low Power Mode: Only on Battery / Never)." >&2
  exit 1
fi
exit 0
