#!/bin/zsh
# Record the screen for N seconds into the research packet.
# Usage: rec.sh <chatgpt|claude|...> <flow-label> <seconds>
set -e
root=${0:A:h:h}/docs/research/01-reference
dir=$root/$1/flows; mkdir -p $dir
out=$dir/$2_$(date +%Y%m%d-%H%M%S).mov
screencapture -x -v -V $3 $out
echo $out
