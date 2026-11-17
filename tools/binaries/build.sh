#!/usr/bin/env bash
# make binaries: build llama-server and sd-server/sd-cli from the pinned submodules
# (M0.T01 step 8, D-013). Cached per submodule SHA in $ANTICHAT_DEV_CACHE/binaries/<sha>/.
# First run records sha256 in Binaries/checksums.json; a rebuild that differs prints `drift`.
# CHECK=1: only compare build/binaries/* with checksums.json (exit 20 on mismatch).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=../env.sh
source tools/env.sh
CACHE="${ANTICHAT_DEV_CACHE:-$HOME/Library/Caches/AntiChat-dev}/binaries"
OUT="$ROOT/build/binaries"
mkdir -p "$OUT"
JOBS="$(sysctl -n hw.ncpu)"

# A worktree has no submodule checkout: build from BINARIES_SRC (the main checkout's Binaries/) instead.
src_of() { if [ -e "Binaries/$1/.git" ]; then echo "$ROOT/Binaries/$1"; else echo "${BINARIES_SRC:?Binaries/$1 is not checked out; set BINARIES_SRC}/$1"; fi; }
LLAMA_SRC="$(src_of llama.cpp)"
SD_UPSTREAM="$(src_of sdcpp)"
# A shallow clone stamps a wrong build number/describe count into the binaries (llama.cpp: rev-list --count;
# sd.cpp: git describe), so the checksums would not reproduce: require full history.
for s in "$LLAMA_SRC" "$SD_UPSTREAM"; do
  if [ "$(git -C "$s" rev-parse --is-shallow-repository)" = true ]; then
    echo "[fail] $s is a shallow clone; run: git -C $s fetch --unshallow"; exit 22
  fi
done
LLAMA_SHA="$(git -C "$LLAMA_SRC" rev-parse HEAD)"
SD_SHA="$(git -C "$SD_UPSTREAM" rev-parse HEAD)"
# M4.T05: AntiChat patches on sd.cpp (Vendor/UPSTREAM_PATCHES.md UP-SD-*), applied to a copy of the pinned tree;
# their hash is part of the cache key and of the checksums.json `config` key.
SD_PATCHES=(Vendor/patches/sdcpp/*.patch)
SD_PATCH_KEY="$(cat "${SD_PATCHES[@]}" | shasum -a 256 | cut -c1-12)"
CMAKE_COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DBUILD_SHARED_LIBS=OFF)

# Portable CPU baseline (A-M0-07, review-M0-T01 high finding): GGML_NATIVE defaults to ON, which builds
# with -mcpu=native (+i8mm+sme on this M5 Max) and would SIGILL on M1-M3. Pin the ARMv8.5-A + fp16 baseline
# that every Apple Silicon chip supports; assert_portable() below fails the build if native flags return.
PORTABLE_FLAGS=(-DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.5-a+fp16 -DGGML_CCACHE=OFF)
# Flags are part of the cache key and of checksums.json, so a flag change never reuses a stale build.
LLAMA_FLAGS=("${PORTABLE_FLAGS[@]}" -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_USE_PREBUILT_UI=OFF -DLLAMA_BUILD_UI=OFF)
SD_FLAGS=("${PORTABLE_FLAGS[@]}" -DSD_METAL=ON -DSD_BUILD_EXAMPLES=ON -DSD_SERVER_BUILD_FRONTEND=OFF)
# Path-independent outputs (same sha256 from any checkout dir): map the checkout path away.
REAL_ROOT="$(cd "$ROOT" && pwd -P)"
PMAP="-ffile-prefix-map=$REAL_ROOT=. -ffile-prefix-map=$ROOT=."
PREFIX_FLAGS=("-DCMAKE_C_FLAGS=$PMAP" "-DCMAKE_CXX_FLAGS=$PMAP" "-DCMAKE_OBJC_FLAGS=$PMAP")
LLAMA_KEY="$LLAMA_SHA-$(printf '%s ' "${CMAKE_COMMON[@]}" "${LLAMA_FLAGS[@]}" | shasum -a 256 | cut -c1-12)"
# stamp=pinned-git: the version stamp comes from the submodule (git-pinned.sh); older keys stamped AntiChat's HEAD.
SD_KEY="$SD_SHA-$(printf '%s ' "${CMAKE_COMMON[@]}" "${SD_FLAGS[@]}" "$SD_PATCH_KEY" stamp=pinned-git | shasum -a 256 | cut -c1-12)"
# The cache dir is user-level and shared by every checkout/worktree: key it on the toolchain too, so
# an Xcode/clang/cmake change rebuilds (and is then checked against checksums.json) instead of
# silently reusing a binary from the old toolchain. Not part of the checksums.json `config` key.
TC_KEY="$({ xcodebuild -version; xcrun clang --version | head -1; cmake --version | head -1; } 2>/dev/null | shasum -a 256 | cut -c1-8)"
# The generator stays "Ninja" in the cache/config keys (CMAKE_COMMON), but the build always uses Unix Makefiles:
# Binaries/checksums.json was recorded with Makefiles (no ninja on the recording Mac). GitHub release run 44174414767
# (ninja 1.13.2, cmake 4.4.5) reproduced llama-server but not sd-server/sd-cli; the generator is one of the two differences.
gen_args() { local a; for a in "${CMAKE_COMMON[@]}"; do if [ "$a" = Ninja ]; then echo "Unix Makefiles"; else echo "$a"; fi; done; }
# cache_put src dst: atomic, so a concurrent build in another worktree never copies a half-written file.
cache_put() { cp -f "$1" "$2.tmp.$$" && mv -f "$2.tmp.$$" "$2"; }

# assert_portable <cmake build dir> <binary>...: no -mcpu=native / i8mm / SME in the configured flags, and
# no i8mm (smmla/ummla/usmmla) or SME (smstart/smstop) instructions in the binaries.
assert_portable() {
  local dir="$1"; shift
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    grep -q '^GGML_NATIVE:BOOL=OFF' "$dir/CMakeCache.txt" || { echo "[fail] $dir: GGML_NATIVE is not OFF"; exit 21; }
    if grep -rEl -- '-mcpu=native|-march=native|\+i8mm|\+sme' "$dir/build.ninja" "$dir"/CMakeFiles/rules.ninja "$dir"/CMakeCache.txt 2>/dev/null | grep -q .; then
      echo "[fail] $dir: native/i8mm/sme compile flags found"; exit 21
    fi
  fi
  local b
  for b in "$@"; do
    local n
    # otool's failure is masked below (`|| true`), so a missing binary would read as "portable".
    [ -f "$b" ] || { echo "[fail] $b missing"; exit 20; }
    # count, not grep -q: with pipefail an early grep exit would SIGPIPE otool and hide a match.
    n="$(otool -tv "$b" | grep -Ec '[[:space:]](smmla|ummla|usmmla|smstart|smstop)([[:space:]]|$)' || true)"
    if [ "${n:-0}" != 0 ]; then
      echo "[fail] $b contains $n i8mm/SME instructions (not portable to M1-M3)"; exit 21
    fi
    echo "[ok] $(basename "$b") portable (no i8mm/SME instructions)"
  done
}

build_llama() {
  local c="$CACHE/$LLAMA_KEY-$TC_KEY"
  if [ -x "$c/llama-server" ] && [ "${FORCE:-0}" != 1 ]; then
    echo "[ok] llama-server cached ($c)"
  else
    echo "[fix] building llama-server @ $LLAMA_SHA"
    # LLAMA_OPENSSL=OFF: offline helper, no Homebrew dylib dependency; LLAMA_USE_PREBUILT_UI=OFF and
    # LLAMA_BUILD_UI=OFF: no web UI is downloaded or embedded (runs with --no-webui, D-013) (A-M0-02).
    rm -rf "${ROOT:?}/build/llama"   # fresh tree: no stale UI stamp or cache from another flag set
    local gen=(); while IFS= read -r a; do gen+=("$a"); done < <(gen_args)
    cmake -S "$LLAMA_SRC" -B build/llama "${gen[@]}" "${LLAMA_FLAGS[@]}" "${PREFIX_FLAGS[@]}"
    cmake --build build/llama --target llama-server -j "$JOBS"
    assert_portable build/llama build/llama/bin/llama-server
    mkdir -p "$c"
    cache_put build/llama/bin/llama-server "$c/llama-server"
  fi
  cp -f "$c/llama-server" "$OUT/llama-server"
}

build_sd() {
  local c="$CACHE/$SD_KEY-$TC_KEY"
  if [ -x "$c/sd-server" ] && [ -x "$c/sd-cli" ] && [ "${FORCE:-0}" != 1 ]; then
    echo "[ok] sd-server/sd-cli cached ($c)"
  else
    echo "[fix] building sd-server + sd-cli @ $SD_SHA"
    # Targets at e239e4b: examples/server/CMakeLists.txt `sd-server`, examples/cli `sd-cli`.
    # SD_SERVER_BUILD_FRONTEND=OFF: no web UI, no pnpm (D-013 offline helper; A-M0-02).
    rm -rf "${ROOT:?}/build/sdcpp" "${ROOT:?}/build/sdcpp-src"
    # The pinned tree (+ its ggml submodule) copied, then the UP-SD patches; the submodule itself stays pristine.
    rsync -a --exclude .git "$SD_UPSTREAM/" build/sdcpp-src/
    for p in "${SD_PATCHES[@]}"; do patch -d build/sdcpp-src -p1 --forward --silent < "$p"; echo "[ok] applied $(basename "$p")"; done
    # Path-independent outputs: the patched copy maps to the same "." as a checkout.
    local sp; sp="-ffile-prefix-map=$REAL_ROOT/build/sdcpp-src=. -ffile-prefix-map=$ROOT/build/sdcpp-src=. $PMAP"
    local gen=(); while IFS= read -r a; do gen+=("$a"); done < <(gen_args)
    # Version stamps (sd.cpp describe/commit, ggml commit) come from the pinned submodule, never from the AntiChat
    # repo that contains the .git-less copy (tools/binaries/git-pinned.sh).
    export PINNED_GIT_COPY="$ROOT/build/sdcpp-src" PINNED_GIT_SRC="$SD_UPSTREAM"
    cmake -S build/sdcpp-src -B build/sdcpp "${gen[@]}" "${SD_FLAGS[@]}" "-DGIT_EXE=$ROOT/tools/binaries/git-pinned.sh" \
      "-DCMAKE_C_FLAGS=$sp" "-DCMAKE_CXX_FLAGS=$sp" "-DCMAKE_OBJC_FLAGS=$sp"
    cmake --build build/sdcpp --target sd-server sd-cli -j "$JOBS"
    assert_portable build/sdcpp build/sdcpp/bin/sd-server build/sdcpp/bin/sd-cli
    mkdir -p "$c"
    cache_put build/sdcpp/bin/sd-server "$c/sd-server"
    cache_put build/sdcpp/bin/sd-cli "$c/sd-cli"
  fi
  cp -f "$c/sd-server" "$OUT/sd-server"
  cp -f "$c/sd-cli" "$OUT/sd-cli"
}

if [ "${CHECK:-0}" != 1 ]; then
  build_llama
  build_sd
fi
# Also on CHECK=1 and cached builds: the shipped binaries must stay portable.
assert_portable "" "$OUT/llama-server" "$OUT/sd-server" "$OUT/sd-cli"

python3 -I - "$ROOT" "$LLAMA_KEY" "$SD_KEY" "${CHECK:-0}" <<'PY'
import hashlib, json, os, subprocess, sys
root, llama_key, sd_key, check = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
path = os.path.join(root, "Binaries/checksums.json")
data = json.load(open(path)) if os.path.exists(path) else {}
tool = subprocess.run(["xcrun", "clang", "--version"], capture_output=True, text=True).stdout.splitlines()[0]
xc = " ".join(subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).stdout.split())
cmake = subprocess.run(["cmake", "--version"], capture_output=True, text=True).stdout.splitlines()[0]
arts = {"llama-server": ("Binaries/llama.cpp", llama_key), "sd-server": ("Binaries/sdcpp", sd_key), "sd-cli": ("Binaries/sdcpp", sd_key)}
drift = False
for name, (sub, key) in arts.items():
    sha, cfg = key.split("-")
    f = os.path.join(root, "build/binaries", name)
    if not os.path.exists(f):
        print(f"[fail] {name} missing"); drift = True; continue
    h = hashlib.sha256(open(f, "rb").read()).hexdigest()
    prev = data.get(name)
    if prev and prev.get("submodule_sha") == sha and prev.get("config") == cfg:
        if prev["sha256"] != h:
            print(f"drift {name}: recorded {prev['sha256']} built {h}"); drift = True
        else:
            print(f"[ok] {name} sha256 matches checksums.json"); prev["reproduced"] = True
    elif check:
        print(f"[fail] {name}: no checksum recorded for {sub}@{sha}"); drift = True
    else:
        data[name] = {"sha256": h, "size": os.path.getsize(f), "submodule": sub, "submodule_sha": sha, "config": cfg,
                      "toolchain": f"{xc}; {tool}; {cmake}", "reproduced": False}
        print(f"[ok] {name} recorded {h}")
if not check:
    json.dump(data, open(path, "w"), indent=2, sort_keys=True); open(path, "a").write("\n")
sys.exit(20 if drift else 0)
PY
