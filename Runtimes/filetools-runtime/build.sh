#!/bin/bash
# Build the AntiChat File tools runtime (M6.T15; P-files-tools-09; R-018 AC1). Run: `make runtime-filetools`.
#
#   beeware/Python-Apple-support 3.13-b18 (sha256-pinned, base.sha256) → Python.framework thinned to arm64
#   + hash-locked binary wheels (requirements.lock) in site-packages/ + antichat/{sitecustomize,repl}.py
#   → precompiled (unchecked-hash .pyc) → smoke test → deterministic zip + manifest + size report.
#
# Layout of build/runtimes/filetools/ (the runtime root; zipped as filetools-runtime-<ver>.zip):
#   bin/ft-python                                                               launcher (launcher/ft-python.c)
#   Python.framework/Versions/3.13/{Python, lib/python3.13/…}                   interpreter library + stdlib
#   site-packages/                                                              wheels of requirements.lock
#   antichat/{sitecustomize.py, repl.py}                                        our process setup + JSON REPL
#   RUNTIME.json                                                                name, version, inputs, hashes
# The interpreter is bin/ft-python (Py_BytesMain; the framework's bin/python3.13 is only a stub that spawns an
# embedded Python.app); its LC_RPATH (@executable_path/..) is the runtime root, so the tree is relocatable. The FileTools XPC launches it with PYTHONHOME =
# the framework version dir and PYTHONPATH = site-packages:antichat (M6.T17), never writing into it.
#
# Usage: Runtimes/filetools-runtime/build.sh [--check] [--lock] [--offline]
#   --lock     re-resolve requirements.lock from requirements.in (needs PyPI), then stop
#   --check    verify only: base tarball hash, lock is current and installs with --require-hashes
#              (uv pip sync --require-hashes into a scratch target), built zip matches its manifest
#   --offline  use the cached tarball and the uv cache only
# Env: OUT_DIR (default build/runtimes), AT_DIR (default build/at/AT-018/<UTC date>).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
NAME=filetools-runtime
VERSION=0.1.0
PYVER=3.13
ASSET=Python-3.13-macOS-support.b18.tar.gz
URL="$(sed -n 's/^# url: //p' "$HERE/base.sha256")"
OUT_DIR="${OUT_DIR:-$ROOT/build/runtimes}"
OUT="$OUT_DIR/filetools"
CACHE="$OUT_DIR/cache"
ZIP="$OUT_DIR/$NAME-$VERSION.zip"
AT_DIR="${AT_DIR:-$ROOT/build/at/AT-018/$(date -u +%Y-%m-%d)}"
SIZE_LIMIT=$((90 * 1000 * 1000))  # R-018 AC1 "≈ 85 MB" download; M6.T15 target ≤ 90 MB
UV_PLATFORM=(--python-version "$PYVER" --python-platform aarch64-apple-darwin --only-binary :all:)
MODE=build OFFLINE=()
for a in "$@"; do
    case "$a" in
        --check) MODE=check ;;
        --lock) MODE=lock ;;
        --offline) OFFLINE=(--offline) ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

log() { printf '[runtime-filetools] %s\n' "$*"; }
die() { printf '[runtime-filetools] error: %s\n' "$*" >&2; exit 1; }

compile_lock() {  # compile_lock <out-file>
    # From inside the runtime folder: the lock's "# via -r requirements.in" annotations stay path-independent.
    (cd "$HERE" && uv pip compile requirements.in "${UV_PLATFORM[@]}" --generate-hashes -q \
        --custom-compile-command "make runtime-filetools LOCK=1" -o "$1" ${OFFLINE[@]+"${OFFLINE[@]}"})
}

fetch_base() {
    mkdir -p "$CACHE"
    local sums; sums="$(grep -v '^#' "$HERE/base.sha256")"
    if [[ -f "$CACHE/$ASSET" ]] && (cd "$CACHE" && shasum -a 256 -c -s <<< "$sums"); then
        log "[ok] cached $ASSET"; return
    fi
    ((${#OFFLINE[@]} == 0)) || die "offline and $CACHE/$ASSET missing or wrong hash"
    log "download $URL"
    curl -fsSL --retry 3 -o "$CACHE/$ASSET.part" "$URL"
    mv "$CACHE/$ASSET.part" "$CACHE/$ASSET"
    (cd "$CACHE" && shasum -a 256 -c <<< "$sums") || { rm -f "$CACHE/$ASSET"; die "checksum mismatch for $ASSET"; }
}

if [[ "$MODE" == lock ]]; then
    compile_lock "$HERE/requirements.lock"; log "wrote requirements.lock"; exit 0
fi

if [[ "$MODE" == check ]]; then
    fetch_base
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/ft-check.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
    compile_lock "$tmp/requirements.lock"
    diff -u "$HERE/requirements.lock" "$tmp/requirements.lock" || die "requirements.lock is stale (make runtime-filetools LOCK=1)"
    uv pip sync --require-hashes "${UV_PLATFORM[@]}" --target "$tmp/site" -q ${OFFLINE[@]+"${OFFLINE[@]}"} "$HERE/requirements.lock"
    log "[ok] lock current; $(ls "$tmp/site" | grep -c 'dist-info$') distributions verify with --require-hashes"
    if [[ -f "$ZIP" && -f "$OUT_DIR/$NAME-$VERSION.json" ]]; then
        want="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["zip"]["sha256"])' "$OUT_DIR/$NAME-$VERSION.json")"
        got="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
        [[ "$want" == "$got" ]] || die "$ZIP sha256 $got != manifest $want"
        log "[ok] $ZIP matches its manifest"
    fi
    exit 0
fi

# ---------------------------------------------------------------- build (always from a clean tree)
fetch_base
rm -rf "$OUT" "$OUT.extract"
mkdir -p "$OUT.extract" "$OUT"
tar -xzf "$CACHE/$ASSET" -C "$OUT.extract"
FW_SRC="$OUT.extract/Python.xcframework/macos-arm64_x86_64/Python.framework"
[[ -f "$FW_SRC/Versions/$PYVER/Python" ]] || die "no Python.framework/Versions/$PYVER/Python in $ASSET"
cp -a "$FW_SRC" "$OUT/Python.framework"
rm -rf "$OUT.extract"
FW="$OUT/Python.framework/Versions/$PYVER"
PY="$OUT/bin/ft-python"
STD="$FW/lib/python$PYVER"

log "prune the framework (no GUI stub, headers, intel launchers, curses, tests, idle, ensurepip)"
rm -rf "$FW/Resources/Python.app" "$FW/bin" "$FW/include" "$FW/Headers" "$OUT/Python.framework/Headers" \
    "$FW/lib/pkgconfig" "$FW/_CodeSignature" \
    "$FW"/lib/lib{form,menu,panel,ncurses,curses}*.dylib \
    "$STD"/{test,idlelib,ensurepip,turtledemo,turtle.py,pydoc_data,__phello__} \
    "$STD"/lib-dynload/_curses*.so "$STD"/config-$PYVER-darwin
find "$OUT" -name __pycache__ -type d -prune -exec rm -rf {} +

log "thin every universal Mach-O to arm64"
fat_machos() {  # universal (FAT) Mach-O files under $1: magic 0xcafebabe / 0xcafebabf with a small arch count
    python3 -I - "$1" <<'PY'
import os, struct, sys
for root, _d, names in os.walk(sys.argv[1]):
    for n in names:
        p = os.path.join(root, n)
        if os.path.islink(p):
            continue
        with open(p, "rb") as f:
            head = f.read(8)
        if len(head) == 8 and head[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf") and 0 < struct.unpack(">I", head[4:])[0] < 8:
            print(p)
PY
}
thinned=0
while IFS= read -r f; do
    lipo -thin arm64 "$f" -output "$f.thin" && mv "$f.thin" "$f"; thinned=$((thinned + 1))
done < <(fat_machos "$OUT")
log "thinned $thinned files"

log "build the launcher (bin/ft-python → Py_BytesMain; replaces the framework's bin/ + Python.app stub pair)"
mkdir -p "$OUT/bin"
xcrun clang -arch arm64 -mmacosx-version-min=11.0 -O2 -Wall -Werror -F"$OUT" -framework Python \
    -Wl,-rpath,@executable_path/.. -o "$PY" "$HERE/launcher/ft-python.c"

log "install wheels (hash-locked, binary only)"
uv pip install --require-hashes --no-deps "${UV_PLATFORM[@]}" --python "$PY" --target "$OUT/site-packages" -q \
    --link-mode copy --no-compile ${OFFLINE[@]+"${OFFLINE[@]}"} -r "$HERE/requirements.lock"
sp="$OUT/site-packages"
rm -rf "$sp/bin"  # console-script shims point at the build host's interpreter
# …and their RECORD lines hash that path (A-M9-T05a: the zip depended on the checkout dir); drop them with the shims.
sed -i '' '/^bin\//d' "$sp"/*.dist-info/RECORD
find "$sp" -type d -name tests -prune -exec rm -rf {} +
rm -rf "$sp/numpy/f2py" "$sp/numpy/_core/include" "$sp/numpy/_pyinstaller" "$sp/matplotlib/backends/web_backend"
find "$sp" -type f \( -name '*.pyi' -o -name '*.pyx' -o -name '*.pxd' -o -name '*.c' -o -name '*.h' \) -delete
find "$OUT" -name __pycache__ -type d -prune -exec rm -rf {} +

mkdir -p "$OUT/antichat"
cp "$HERE/sitecustomize.py" "$HERE/repl.py" "$OUT/antichat/"

log "precompile (unchecked-hash .pyc; the signed tree is never written at run time)"
# -s strips the build path from co_filename (byte-reproducible; importlib fixes the name up at load time).
# -B -f (A-M9-T05a): compileall's own imports (argparse, __future__, _colorize, …) otherwise write timestamp .pyc
# files with the full build path first, which compileall then skips as up to date: the zip depended on the checkout dir.
"$PY" -I -B -m compileall -q -f -j0 --invalidation-mode unchecked-hash -s "$OUT" -p / "$STD" "$sp" "$OUT/antichat" >/dev/null

log "smoke test (no bytecode writes, matplotlib Agg, REPL round trip)"
smoke="$(mktemp -d "${TMPDIR:-/tmp}/ft-smoke.XXXXXX")"
before="$(find "$OUT" | LC_ALL=C sort | shasum -a 256)"
run_py() {
    env -i PATH=/usr/bin:/bin HOME="$smoke" TMPDIR="$smoke/tmp" LANG=en_US.UTF-8 ANTICHAT_SCRATCH="$smoke" \
        PYTHONHOME="$FW" PYTHONPATH="$sp:$OUT/antichat" PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 \
        OMP_NUM_THREADS=2 OPENBLAS_NUM_THREADS=2 VECLIB_MAXIMUM_THREADS=2 NUMEXPR_MAX_THREADS=2 "$PY" "$@"
}
mkdir -p "$smoke/tmp" "$smoke/out"
run_py -c 'import sys, numpy, pandas, openpyxl, docx, pptx, matplotlib, PIL, xlsxwriter, pypdf
import matplotlib.pyplot as plt
assert matplotlib.get_backend().lower() == "agg", matplotlib.get_backend()
assert "sitecustomize" in sys.modules
import resource as r
assert r.getrlimit(r.RLIMIT_NOFILE) == (256, 256) and r.getrlimit(r.RLIMIT_FSIZE) == (104857600, 104857600), "launcher limits"
assert r.getrlimit(r.RLIMIT_CPU) == (600, 600) and r.getrlimit(r.RLIMIT_CORE) == (0, 0), "launcher limits"
print(sys.version.split()[0], "numpy", numpy.__version__, "pandas", pandas.__version__, "mpl", matplotlib.__version__)'
reply="$(printf '%s\n' '{"id":"1","code":"import matplotlib.pyplot as plt\nplt.plot([1,2,3])\nx = 41\nx + 1"}' \
    '{"id":"2","code":"import os\nos.system(\"true\")"}' | (cd "$smoke" && run_py "$OUT/antichat/repl.py"))"
echo "$reply" | python3 -I -c '
import json, sys
lines = [json.loads(l) for l in sys.stdin.read().splitlines() if l.strip()]
assert lines[0]["ready"], lines[0]
r1, r2 = lines[1], lines[2]
assert r1["error"] is None and r1["stdout"].strip() == "42" and r1["files"] == ["figure-1.png"], r1
assert r2["error"]["type"] == "PermissionError", r2
print("[runtime-filetools] [ok] REPL round trip:", r1["stdout"].strip(), r1["files"], "| os.system ->", r2["error"]["type"])'
after="$(find "$OUT" | LC_ALL=C sort | shasum -a 256)"
[[ "$before" == "$after" ]] || die "the smoke run wrote into the runtime tree"
rm -rf "$smoke"

log "RUNTIME.json"
python3 -I - "$OUT/RUNTIME.json" "$NAME" "$VERSION" "$HERE" <<'PY'
import hashlib, json, sys
from pathlib import Path
out, name, version, here = sys.argv[1], sys.argv[2], sys.argv[3], Path(sys.argv[4])
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
base = [l.split() for l in (here / "base.sha256").read_text().splitlines() if l.strip() and not l.startswith("#")][0]
meta = {
    "name": name, "version": version,
    "python": {"source": "beeware/Python-Apple-support@2a786c1994", "release": "3.13-b18", "asset": base[1],
               "sha256": base[0], "version": "3.13.17"},
    "interpreter": "bin/ft-python",
    "pythonhome": "Python.framework/Versions/3.13",
    "pythonpath": ["site-packages", "antichat"],
    "entry": "antichat/repl.py",
    "requirements_lock_sha256": sha(here / "requirements.lock"),
    "sources": {n: sha(here / n) for n in ("sitecustomize.py", "repl.py")},
}
Path(out).write_text(json.dumps(meta, indent=1, sort_keys=True) + "\n")
PY

log "normalise modes and times, zip deterministically"
chmod -R u+rwX,go+rX,go-w "$OUT"
find "$OUT" -exec touch -h -t 202601010000 {} +
rm -f "$ZIP"
(cd "$OUT" && find . \( -type f -o -type l \) | LC_ALL=C sort | zip -X -y -q -9 -@ "$ZIP")
python3 -I "$ROOT/tools/release/runtime-manifest.py" --name "$NAME" --version "$VERSION" --root "$OUT" --zip "$ZIP" \
    --out "$OUT_DIR/$NAME-$VERSION.json" --size-report "$AT_DIR/size.json" --size-limit "$SIZE_LIMIT"
