#!/usr/bin/env bash
# AT-200 leg 3 (M2.T01; R-200 AC1, AC5, AC6 on this Mac): the app's own probe (`-PrintHardwareProfile YES`, DEBUG)
# against system_profiler / sysctl / df. Prints a diff table; exits 1 on any mismatch.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="${APP:-$root/build/AntiChat.app}/Contents/MacOS/AntiChat"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
"$app" -PrintHardwareProfile YES -ANTICHAT_DEV_CONTAINER "$tmp/c" > "$tmp/app.json"
system_profiler SPHardwareDataType -json > "$tmp/sp.json"
sysctl -n hw.memsize hw.perflevel0.physicalcpu hw.perflevel1.physicalcpu > "$tmp/sysctl.txt"
mkdir -p "$HOME/Library/Application Support"
df -k "$HOME/Library/Application Support" | tail -1 | awk '{print $4}' > "$tmp/df.txt"
python3 -I - "$tmp" <<'PY'
import json, sys, pathlib
d = pathlib.Path(sys.argv[1])
app = json.loads((d / "app.json").read_text())
sp = json.loads((d / "sp.json").read_text())["SPHardwareDataType"][0]
mem, p, e = [int(x) for x in (d / "sysctl.txt").read_text().split()]
df_gb = int((d / "df.txt").read_text()) * 1024 / 1e9
procs = sp.get("number_processors", "")  # e.g. "proc 18:6:12"
parts = procs.replace("proc ", "").split(":") if isinstance(procs, str) else []
rows = [
    ("chip", app["chip"], sp["chip_type"], app["chip"] == sp["chip_type"]),
    ("ramGB", app["ramGB"], sp["physical_memory"], f'{app["ramGB"]} GB' == sp["physical_memory"]),
    ("ram (sysctl GiB)", app["ramGB"], mem / 2**30, app["ramGB"] == round(mem / 2**30)),
    ("pCores", app["pCores"], p, app["pCores"] == p),
    ("eCores", app["eCores"], e, app["eCores"] == e),
]
if len(parts) == 3:
    rows.append(("cores (system_profiler)", f'{app["pCores"]}:{app["eCores"]}', ":".join(parts[1:]),
                 f'{app["pCores"]}:{app["eCores"]}' == ":".join(parts[1:])))
# volumeAvailableCapacityForImportantUsage counts purgeable space, df does not: it may only be larger.
rows.append(("freeDiskGB (≥ df − 1)", app["freeDiskGB"], round(df_gb, 1), app["freeDiskGB"] >= df_gb - 1))
print(f'{"field":28} {"app":>22} {"system":>22}  ok')
bad = 0
for name, a, s, ok in rows:
    print(f"{name:28} {str(a):>22} {str(s):>22}  {'ok' if ok else 'MISMATCH'}")
    bad += not ok
print(f"tier {app['tier']} {app.get('subband')} B={app['B']} W={app['W']} {app['speedClass']} ({app['speedClassSource']})")
print(f"mismatches: {bad}")
sys.exit(1 if bad else 0)
PY
