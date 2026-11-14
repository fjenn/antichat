#!/bin/zsh
# Visual-QA capture helper (M1.T09; reused by M1.T26/T27).
#   capture.sh shot <script> <label> [window-id]  → build/visual/<version>/<script>/<NN>_<label>.png
#       (`screencapture -x -o -l <window id>`; without a window id the whole screen)
#   capture.sh rec  <script> <label> <seconds>     → build/visual/<version>/<script>/<NN>_<label>.mov
#       (`screencapture -v -V <seconds>`, display rate; the whole screen — crop with frametime.py / layout-jump.py)
# [PERM: Screen Recording] for the terminal running it. Prints the written path.
set -euo pipefail
root=${0:A:h:h:h}
version=${VERSION:-$(git -C "$root" describe --always --dirty 2>/dev/null || echo dev)}
mode=${1:?usage: capture.sh shot|rec <script> <label> [window-id|seconds]}
script=${2:?script}
label=${3:?label}
dir=$root/build/visual/$version/$script
mkdir -p "$dir"
n=$(printf '%02d' $(( $(ls "$dir" 2>/dev/null | grep -cE '\.(png|mov)$' || true) + 1 )))
case $mode in
  shot)
    wid=${4:-}  # CGWindowID (e.g. NSWindow.windowNumber, printed by the in-app probes); empty = whole screen
    out=$dir/${n}_$label.png
    if [[ -n $wid ]]; then screencapture -x -o -l "$wid" "$out"; else screencapture -x "$out"; fi
    ;;
  rec)
    secs=${4:?seconds}
    out=$dir/${n}_$label.mov
    screencapture -x -v -V "$secs" "$out"
    ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
esac
echo "$out"
