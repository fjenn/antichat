#!/bin/zsh
# Save a screenshot into the research packet.
# Usage: shot.sh <chatgpt|claude|local-apps/NAME|other-dir> <label> [x,y,w,h]
# Writes docs/research/01-reference/<dir>/screens/<NNN>_<label>.png (auto-numbered).
set -e
root=${0:A:h:h}/docs/research/01-reference
dir=$root/$1/screens; label=$2; region=$3
mkdir -p $dir
n=$(printf '%03d' $(( $(ls $dir 2>/dev/null | grep -c '\.png$') + 1 )))
out=$dir/${n}_${label}.png
if [[ -n $region ]]; then screencapture -x -R$region $out; else screencapture -x $out; fi
echo $out
