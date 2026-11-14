#!/bin/bash
# AT-012 fallback runner (M1.T11; Q-015: XCUITest cannot enable automation mode on this Mac). Generates the
# 10,000-chat fixture database once (tools/fixtures/gen-chats.py → build/fixtures/big-10k.sqlite), then runs the
# in-process ⌘K probe (`-PaletteProbe`, App/AntiChat/PaletteProbe.swift) RUNS times on build/AntiChat.app (Debug),
# each on a fresh copy of the database as the container's antichat.sqlite. Output: build/at/AT-012/probe-<n>/
# {probe.json,S-18-*.png}. The container copy is also left at build/fixtures/big-10k-container/ for J09PaletteTests.
# Usage: tools/at/run.sh AT-012 -- tools/at/at-012-probe.sh [RUNS]
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
OUT="$ROOT/build/at/AT-012"
DB="$ROOT/build/fixtures/big-10k.sqlite"
RUNS="${1:-3}"
[ -x "$BIN" ] || { echo "missing $BIN (run make build)"; exit 2; }
if [ ! -f "$DB" ]; then
  python3 -I "$ROOT/tools/fixtures/gen-chats.py" --chats 10000 --long 1:1000 --out "$DB" || exit 2
fi
mkdir -p "$OUT" "$ROOT/build/fixtures/big-10k-container"
cp "$DB" "$ROOT/build/fixtures/big-10k-container/antichat.sqlite"
fail=0
for n in $(seq 1 "$RUNS"); do
  dir="$OUT/probe-$n"
  box="$(mktemp -d /tmp/antichat-at012-XXXXXX)"
  cp "$DB" "$box/antichat.sqlite"
  rm -rf "$dir"
  "$BIN" -ApplePersistenceIgnoreState YES -OfflineOnly YES -ANTICHAT_DEV_CONTAINER "$box" -PaletteProbe "$dir" \
    >"$box.log" 2>&1
  if [ ! -f "$dir/probe.json" ]; then echo "probe-$n: no probe.json"; tail -5 "$box.log"; fail=1; continue; fi
  python3 -I - "$dir/probe.json" "probe-$n" <<'PY' || fail=1
import json, sys
d = json.load(open(sys.argv[1]))
legs = d.get("legs", {})
bad = [k for k, v in sorted(legs.items()) if not v.get("pass")]
lat = legs.get("3-latency-20-queries", {})
print(f"{sys.argv[2]}: pass={d.get('pass')} p50={lat.get('p50_ms')} ms p95={lat.get('p95_ms')} ms "
      f"opened={legs.get('1-open-tabs-footer', {}).get('openedBy')} failed={bad}")
sys.exit(0 if d.get("pass") else 1)
PY
  rm -rf "$box" "$box.log"
done
exit $fail
