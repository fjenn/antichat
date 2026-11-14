#!/usr/bin/env bash
# S-4 (M0.T04 step 12, spike/s-4-vmlx): mlx-swift-lm @ f5b0677 vs vmlx-swift @ 88e25dc673, same in-process
# protocol (tools/antichat-bench-inproc vs tools/antichat-bench-vmlx), 20 runs each, under the GPU lock.
# Writes build/perf/raw/{inproc,vmlx}-<model>-<tier>-1k.jsonl and report keys m0.inproc.* / m0.vmlx.*.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
FIXTURES="${FIXTURES:-fixtures}"
[ -f "$FIXTURES/prompts/bench-300tok.txt" ] || FIXTURES=build/fixtures-t04
export FIXTURES
RUNS="${RUNS:-20}"
VMLX=build/dd-vmlx/Build/Products/Release/antichat-bench-vmlx
if [ ! -x "$VMLX" ]; then
  (cd tools/antichat-bench-vmlx && xcodebuild -scheme antichat-bench-vmlx -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ROOT/build/dd-vmlx" -packageAuthorizationProvider netrc build -quiet)
fi
for spec in "chat-9b-q4 T1" "chat-9b-q8 T2-24" "chat-g26 T2-32"; do
  set -- $spec
  if [ "$1" != chat-9b-q4 ]; then   # chat-9b-q4 inproc already measured by the S-3 step
    NO_BUILD=1 REPLACE=1 tools/bench.sh inproc --model "$1" --tier-cap "$2" --runs "$RUNS"
  fi
  RAW="build/perf/raw/vmlx-$1-$2-1k.jsonl"
  lockf /tmp/antichat-gpu.lock "$VMLX" chat --model "$1" --tier-cap "$2" --runs "$RUNS" --fixtures "$FIXTURES" --raw "$RAW"
  python3 -I tools/perf/report.py ingest --raw "$RAW" --replace
done
