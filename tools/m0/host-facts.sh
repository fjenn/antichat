#!/usr/bin/env bash
# M0.T00 step 1: print host facts and write build/at/AT-M0-00/host.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${1:-$ROOT/build/at/AT-M0-00}"
mkdir -p "$OUT_DIR"

run() { "$@" 2>&1 || echo "error: $*"; }

export HF_PRODUCT="$(run sw_vers -productVersion)"
export HF_BUILD="$(run sw_vers -buildVersion)"
export HF_ARCH="$(run uname -m)"
export HF_CPU="$(run sysctl -n machdep.cpu.brand_string)"
export HF_MEM="$(run sysctl -n hw.memsize)"
export HF_GPU_JSON="$(system_profiler SPDisplaysDataType -json 2>/dev/null || echo '{}')"
export HF_DF="$(df -k ~ | tail -1)"
export HF_XCODE="$(run xcodebuild -version)"
export HF_XCSELECT="$(run xcode-select -p)"
export HF_GIT="$(run git --version)"
export HF_LFS="$(run git lfs version)"
export HF_PY="$(run python3 --version)"

python3 -I - "$OUT_DIR/host.json" <<'PY'
import json, os, sys
e = os.environ
gpu = None
try:
    d = json.loads(e["HF_GPU_JSON"])
    g = d.get("SPDisplaysDataType", [{}])[0]
    gpu = {"model": g.get("sppci_model"), "cores": int(g.get("sppci_cores", 0) or 0)}
except Exception as ex:  # record, do not fail
    gpu = {"error": str(ex)}
df = e["HF_DF"].split()
free_kb = int(df[3]) if len(df) > 3 and df[3].isdigit() else None
xc = e["HF_XCODE"].splitlines()
facts = {
    "macos_version": e["HF_PRODUCT"],
    "macos_build": e["HF_BUILD"],
    "arch": e["HF_ARCH"],
    "cpu": e["HF_CPU"],
    "mem_bytes": int(e["HF_MEM"]) if e["HF_MEM"].isdigit() else e["HF_MEM"],
    "gpu": gpu,
    "df_home": e["HF_DF"],
    "free_disk_gb": round(free_kb * 1024 / 1e9, 1) if free_kb is not None else None,
    "xcodebuild_version": xc,
    "xcode_select": e["HF_XCSELECT"],
    "git": e["HF_GIT"],
    "git_lfs": e["HF_LFS"],
    "python3": e["HF_PY"],
}
with open(sys.argv[1], "w") as f:
    json.dump(facts, f, indent=2)
    f.write("\n")
print(json.dumps(facts, indent=2))
PY
