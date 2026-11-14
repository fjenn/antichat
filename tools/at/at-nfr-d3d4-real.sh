#!/usr/bin/env bash
# AT-NFR-D3 / AT-NFR-D4 on real bytes (M2.T25 step 1; closed in M2.T26): the CAS of a real T1 install (a dev
# container that went through onboarding with real anonymous HF downloads, e.g. tools/at/at-209-destinations.sh's
# /tmp/antichat-dest.*) vs `antichat-cli catalog sizes`. Pass: every installed model verifies, the store's bytes are
# within 1% of the catalog sum for the chat pack, and ≤ the NFR-D4 cap (T1 7.5 GB). D3 (all packs) stays on catalog
# sums until the Voice/Photo packs exist (M3/M4).
# M9.T05: D3=1 checks a default (all eligible packs) install instead: a container from
# `ONB_PROBE_ALL_PACKS=1 tools/at/at-209-destinations.sh`; the store's bytes vs the catalog `all` sum (within 1%) and
# ≤ the NFR-D3 cap (T0 4 · T1 15 · T2 60 · T3 110 · T4 180 GB).
# Usage: [D3=1] tools/at/at-nfr-d3d4-real.sh <container> [tier]
set -euo pipefail
BOX="${1:?container}"; TIER="${2:-T1}"
CLI="${CLI:-.build/out/Products/Debug/antichat-cli}"
"$CLI" models verify --models "$BOX/Models" --db "$BOX/antichat.sqlite" >&2
"$CLI" models list --models "$BOX/Models" --db "$BOX/antichat.sqlite" --json > /tmp/d3d4-list.$$.json
"$CLI" catalog sizes --tier "$TIER" --json > /tmp/d3d4-sizes.$$.json
actual=$(find "$BOX/Models/store" -type f -print0 | xargs -0 stat -f %z | awk '{s+=$1} END {print s+0}')
python3 -I - "$actual" /tmp/d3d4-list.$$.json /tmp/d3d4-sizes.$$.json "$TIER" "${D3:-0}" <<'PY'
import json, sys
actual, models, sizes, tier = int(sys.argv[1]), json.load(open(sys.argv[2])), json.load(open(sys.argv[3])), sys.argv[4]
d3 = sys.argv[5] == "1"
caps = ({"T0": 4.0, "T1": 15.0, "T2": 60.0, "T3": 110.0, "T4": 180.0} if d3      # nfr.md NFR-D3
        else {"T0": 3.0, "T1": 7.5, "T2": 22.0, "T3": 31.0, "T4": 71.0})          # nfr.md NFR-D4
want = sizes["all" if d3 else "chat"]
dev = abs(actual - want) / want
ok = all(m["state"] == "ready" for m in models) and dev <= 0.01 and actual / 1e9 <= caps[tier]
print(json.dumps({"nfr": "D3" if d3 else "D4", "tier": tier, "models": [m["id"] for m in models], "store_bytes": actual,
                  "catalog_bytes": want, "catalog_set": "all" if d3 else "chat",
                  "deviation": round(dev, 6), "cap_gb": caps[tier], "pass": ok}, indent=1))
sys.exit(0 if ok else 1)
PY
rc=$?; rm -f /tmp/d3d4-list.$$.json /tmp/d3d4-sizes.$$.json; exit $rc
