#!/bin/sh
# M5.T11: builds the gpu-burn CLI (Metal compute load for the NFR-B5 yield test) into build/tools/gpu-burn.
set -eu
root=$(cd "$(dirname "$0")/../../.." && pwd)
mkdir -p "$root/build/tools"
xcrun swiftc -O -framework Metal "$root/tools/perf/gpu-burn/main.swift" -o "$root/build/tools/gpu-burn"
echo "$root/build/tools/gpu-burn"
