#!/usr/bin/env bash
# tools/bootstrap.sh — clean-checkout bootstrap (environment.md §3; M0.T01 step 10).
# Idempotent. Every step prints [ok]/[fix]/[fail]/[skip] and appends to build/bootstrap.log.
# Flags: --ci (non-interactive), --offline (caches only), --no-models, --tier min|T0..T4
# Exit codes: 0 ok; 10 toolchain; 20 checksum; 30 build; 40 test.
# ANTICHAT_DEV_CACHE (default ~/Library/Caches/AntiChat-dev) relocates the binaries cache and
# the dev Models dir ($ANTICHAT_DEV_CACHE/Models), so a clean run downloads afresh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CI=0; OFFLINE=0; NO_MODELS=0; TIER=T1
while [ $# -gt 0 ]; do
  case "$1" in
    --ci) CI=1 ;;
    --offline) OFFLINE=1 ;;
    --no-models) NO_MODELS=1 ;;
    --tier) TIER="$2"; shift ;;
    --tier=*) TIER="${1#--tier=}" ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown flag $1"; exit 2 ;;
  esac
  shift
done
export CI OFFLINE

mkdir -p build
LOG="$ROOT/build/bootstrap.log"
echo "==== bootstrap $(date -u +%Y-%m-%dT%H:%M:%SZ) commit=$(git rev-parse --short HEAD 2>/dev/null || echo none) flags: ci=$CI offline=$OFFLINE no_models=$NO_MODELS tier=$TIER cache=${ANTICHAT_DEV_CACHE:-default}" >> "$LOG"
exec > >(tee -a "$LOG") 2>&1

# shellcheck source=env.sh
source tools/env.sh
T_START=$(date +%s)
SUMMARY=()
STEP_T0=0
step() { STEP_NAME="$1"; STEP_T0=$(date +%s); echo; echo "--- step $1"; }
done_step() { # status
  local dt=$(( $(date +%s) - STEP_T0 ))
  SUMMARY+=("$(printf '%-34s %-6s %5ss' "$STEP_NAME" "$1" "$dt")")
  echo "[$1] step $STEP_NAME (${dt}s)"
}
die() { # code msg
  local dt=$(( $(date +%s) - STEP_T0 ))
  SUMMARY+=("$(printf '%-34s %-6s %5ss' "$STEP_NAME" "fail" "$dt")")
  echo "[fail] $2"
  print_summary
  echo "bootstrap FAILED with exit $1 after $(( $(date +%s) - T_START ))s (log: $LOG)"
  exit "$1"
}
print_summary() {
  echo; echo "==== summary"
  printf '%s\n' "${SUMMARY[@]}"
}

sha_ok() { # file sha256
  [ -f "$1" ] && [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$2" ]
}
fetch_pinned() { # url sha256 dest
  if sha_ok "$3" "$2"; then return 0; fi
  [ "$OFFLINE" = 1 ] && return 1
  curl -fsSL --retry 3 -o "$3.tmp" "$1" || return 1
  if ! sha_ok "$3.tmp" "$2"; then echo "[fail] checksum mismatch for $1"; rm -f "$3.tmp"; return 20; fi
  mv "$3.tmp" "$3"
}

# ---------------------------------------------------------------- 0 host facts
step "0 host facts"
OSV="$(sw_vers -productVersion)"; ARCH="$(uname -m)"
echo "macOS $OSV ($(sw_vers -buildVersion)) $ARCH $(sysctl -n machdep.cpu.brand_string) RAM $(( $(sysctl -n hw.memsize) / 1073741824 )) GB free $(df -h ~ | tail -1 | awk '{print $4}')"
[ "$ARCH" = arm64 ] || die 10 "not arm64"
python3 -I -c "import sys; v=tuple(int(x) for x in '$OSV'.split('.')); sys.exit(0 if v >= (26,4) else 1)" || die 10 "macOS $OSV < 26.4"
done_step ok

# ---------------------------------------------------------------- 1 Xcode
step "1 xcode"
XCV="$(xcodebuild -version 2>/dev/null | head -1 || true)"
XCB="$(xcodebuild -version 2>/dev/null | sed -n 2p | awk '{print $3}' || true)"
echo "$XCV ($XCB) at $(xcode-select -p)"
# A-M9-T05a (2026-11-09): Xcode auto-updated 27.1 → 27.2 (27B52); 27.1 is no longer offered, so the pin moved.
XCODE_PIN=27.2
if [ "$XCV" != "Xcode $XCODE_PIN" ]; then
  echo "Install Xcode $XCODE_PIN from the App Store or https://developer.apple.com/download/all/ and run: sudo xcode-select -s /Applications/Xcode.app"
  die 10 "wrong Xcode: '$XCV' (need Xcode $XCODE_PIN; never auto-downloaded)"
fi
if [ -f tools/toolchain.lock ]; then
  WANT_B="$(sed -n "s/^xcode=$XCODE_PIN (build \(.*\))\$/\1/p" tools/toolchain.lock)"
  [ -z "$WANT_B" ] || [ "$WANT_B" = "$XCB" ] || die 10 "Xcode build $XCB != toolchain.lock $WANT_B"
fi
case "$(xcode-select -p)" in *Xcode*.app/Contents/Developer) ;; *) die 10 "xcode-select points at $(xcode-select -p), not Xcode.app" ;; esac
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  echo "[fix] xcodebuild -runFirstLaunch"
  xcodebuild -runFirstLaunch || die 10 "xcodebuild -runFirstLaunch failed (may need an admin: run it once by hand)"
fi
xcodebuild -license check >/dev/null 2>&1 || die 10 "Xcode licence not accepted: run 'sudo xcodebuild -license accept' once"
# The Metal Toolchain is a separate Xcode component (Xcode 26+); an Xcode update drops it (2026-11-09: 27.2 auto-update),
# and then every Metal shader build (MLX, sd.cpp metallib) fails. Never auto-downloaded here: the hint names the fix.
if ! xcrun -f metal >/dev/null 2>&1; then
  echo "Install the Metal Toolchain: xcodebuild -downloadComponent MetalToolchain (or Xcode › Settings › Components)"
  die 10 "Metal Toolchain missing (xcrun -f metal failed)"
fi
echo "[ok] metal $(xcrun -f metal)"
done_step ok

# ---------------------------------------------------------------- 2 mise + runtimes
step "2 mise + node/python/uv"
mkdir -p "$ANTICHAT_TOOLS_HOME/bin"
SRC=tools/toolchain-sources.json
jq_get() { python3 -I -c "import json,sys; print(json.load(open('$SRC'))[sys.argv[1]].get(sys.argv[2],''))" "$1" "$2"; }
fetch_pinned "$(jq_get mise url)" "$(jq_get mise sha256)" "$ANTICHAT_TOOLS_HOME/bin/mise" || die 20 "mise download/checksum"
chmod +x "$ANTICHAT_TOOLS_HOME/bin/mise"
if [ "$OFFLINE" = 1 ]; then MISE_OFFLINE=1 mise install >/dev/null || die 10 "mise install (offline)"; else mise install || die 10 "mise install"; fi
echo "mise $(mise --version | awk '{print $1}'); node $(node --version); $(python3 --version); $(uv --version)"
done_step ok

# ---------------------------------------------------------------- 3 pinned binaries
step "3 pinned dev tools"
mkdir -p .tools/bin .tools/dl
for name in vendir xcodegen xcbeautify swiftlint swiftformat; do
  url="$(jq_get $name url)"; sum="$(jq_get $name sha256)"; kind="$(jq_get $name kind)"; ver="$(jq_get $name version)"
  stamp=".tools/dl/$name-$ver.ok"
  # A symlinked ziptree tool is the old (broken) install: re-install it as a wrapper.
  if [ -f "$stamp" ] && [ -x ".tools/bin/$name" ] && [ ! -L ".tools/bin/$name" ]; then echo "[ok] $name $ver"; continue; fi
  f=".tools/dl/$(basename "$url")"
  fetch_pinned "$url" "$sum" "$f" || die 20 "$name download/checksum"
  case "$kind" in
    binary) cp -f "$f" ".tools/bin/$name" ;;
    zip) rm -rf ".tools/dl/$name.x" && unzip -q -o "$f" -d ".tools/dl/$name.x" && cp -f ".tools/dl/$name.x/$(jq_get $name member)" ".tools/bin/$name" ;;
    ziptree) rm -rf ".tools/$name" ".tools/dl/$name.x" && unzip -q -o "$f" -d ".tools/dl/$name.x" \
             && mv ".tools/dl/$name.x/$(jq_get $name tree)" ".tools/$name" && rm -f ".tools/bin/$name" \
             && printf '#!/bin/sh\n# Wrapper, not a symlink: xcodegen finds share/xcodegen/SettingPresets relative to argv[0].\nexec "$(dirname "$0")/../%s/%s" "$@"\n' "$name" "$(jq_get $name member)" > ".tools/bin/$name" ;;
  esac
  chmod +x ".tools/bin/$name"; touch "$stamp"; echo "[fix] $name $ver"
done
# create-dmg: git checkout at the pinned tag commit.
CD_COMMIT="$(jq_get create-dmg commit)"
if [ "$(git -C .tools/create-dmg rev-parse HEAD 2>/dev/null || true)" != "$CD_COMMIT" ]; then
  [ "$OFFLINE" = 1 ] && die 10 "create-dmg not cached (offline)"
  rm -rf .tools/create-dmg
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$(jq_get create-dmg tag)" "$(jq_get create-dmg url)" .tools/create-dmg || die 10 "create-dmg clone"
  [ "$(git -C .tools/create-dmg rev-parse HEAD)" = "$CD_COMMIT" ] || die 20 "create-dmg tag moved"
fi
ln -sf ../create-dmg/create-dmg .tools/bin/create-dmg
# cmake + ninja: hash-locked wheels in a dedicated venv.
if [ ! -x .tools/build-venv/bin/cmake ] || ! .tools/build-venv/bin/python -c 'import sys' 2>/dev/null; then
  uv venv -q --python 3.13 .tools/build-venv || die 10 "uv venv"
fi
UVOFF=(); [ "$OFFLINE" = 1 ] && UVOFF=(--offline)
uv pip install -q ${UVOFF[@]+"${UVOFF[@]}"} --require-hashes -r tools/build-tools.lock --python .tools/build-venv/bin/python || die 20 "cmake/ninja (hash-locked)"
ln -sf ../build-venv/bin/cmake .tools/bin/cmake; ln -sf ../build-venv/bin/ninja .tools/bin/ninja
# ffmpeg: first needed by M3/M5 golden checks; pinned there (A-M0-02).
echo "[skip] ffmpeg: first needed by M3/M5 (A-M0-02)"
echo "vendir $(vendir version 2>/dev/null | head -1 | awk '{print $3}'); xcodegen $(xcodegen --version | awk '{print $2}'); cmake $(cmake --version | head -1 | awk '{print $3}'); ninja $(ninja --version)"
done_step ok

# ---------------------------------------------------------------- 4 submodules + LFS
step "4 submodules + fixtures LFS"
git submodule sync -q --recursive
# protocol.file.allow: the fixtures submodule is a local file:// remote until the public repo exists (A-M0-05).
git -c protocol.file.allow=always submodule update --init --recursive || die 20 "git submodule update"
echo "[skip] trafilatura-rs submodule: added in M7"
git lfs install --local >/dev/null
git -C fixtures lfs install --local >/dev/null
if [ "$OFFLINE" = 0 ]; then git -C fixtures lfs pull || die 20 "fixtures lfs pull"; fi
python3 -I tools/fixtures/lock.py check fixtures fixtures/fixtures.lock.json --exclude 'stub-models/*' --exclude 'stub-models.lock.json' --exclude 'downloads/*.bin' || die 20 "fixtures lock mismatch"
git submodule status
done_step ok

# ---------------------------------------------------------------- 5 vendor-sync
step "5 vendor-sync verify"
if [ -x tools/vendor-sync ]; then tools/vendor-sync verify || die 20 "vendor-sync verify"; done_step ok
else echo "[skip] tools/vendor-sync not yet present (added in M0.T02)"; done_step skip; fi

# ---------------------------------------------------------------- 6 SwiftPM resolution
step "6 package resolution + pins"
cp Package.resolved build/Package.resolved.before
XRES=AntiChat.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild -resolvePackageDependencies -workspace AntiChat.xcworkspace -scheme AntiChat-Debug \
  -disableAutomaticPackageResolution -packageAuthorizationProvider netrc -derivedDataPath build/dd >build/resolve.log 2>&1 || { tail -30 build/resolve.log; die 20 "xcodebuild -resolvePackageDependencies"; }
cmp -s Package.resolved build/Package.resolved.before || die 20 "resolution changed Package.resolved"
cmp -s Package.resolved "$XRES" || die 20 "workspace Package.resolved differs from root Package.resolved"
python3 -I tools/ci/pins-verify.py || die 20 "pins-verify"
done_step ok

# ---------------------------------------------------------------- 7 binaries
step "7 binaries (llama-server, sd-server)"
set +e; tools/binaries/build.sh; rc=$?; set -e
[ $rc = 20 ] && die 20 "binary checksum drift"
[ $rc = 0 ] || die 30 "make binaries failed ($rc)"
done_step ok

# ---------------------------------------------------------------- 8 relay/site
step "8 relay + site npm"
if [ -d relay ] || [ -d site ]; then
  # `[ -d ] && cmd || true` would also swallow a failing npm ci / typecheck: only the missing dir is optional.
  for d in relay site; do
    if [ -d "$d" ]; then (cd "$d" && npm ci --ignore-scripts) || die 30 "npm ci in $d"; fi
  done
  if [ -d relay ]; then (cd relay && npm run typecheck) || die 30 "relay typecheck"; fi
  done_step ok
else echo "[skip] relay/ and site/ not yet present (M7/M10)"; done_step skip; fi

# ---------------------------------------------------------------- 9 python tool deps
step "9 uv sync tools/"
uv sync -q --project tools --frozen ${UVOFF[@]+"${UVOFF[@]}"} || die 10 "uv sync tools"
done_step ok

# ---------------------------------------------------------------- 10 stub models
step "10 stub models"
make -s stub-models CHECK=1 || die 20 "stub models differ from fixtures/stub-models.lock.json (generator drift)"
done_step ok

# ---------------------------------------------------------------- 11 dev models
step "11 dev models (tier $TIER)"
if [ "$NO_MODELS" = 1 ]; then echo "[skip] --no-models"; done_step skip
else
  MODELS_DIR="${ANTICHAT_DEV_CACHE:+$ANTICHAT_DEV_CACHE/Models}"
  MODELS_DIR="${MODELS_DIR:-$HOME/Library/Application Support/AntiChat-Dev/Models}"
  NEED_GB=$(python3 -I -c "import json; m=json.load(open('tools/dev/models-m0.json')); print('ok' if '$TIER' in m['sets'] else 'missing')")
  [ "$NEED_GB" = ok ] || die 10 "tier '$TIER' not in tools/dev/models-m0.json (M0.T01 has only 'min'; M0.T04 adds more)"
  mkdir -p "$MODELS_DIR"
  FREE_GB=$(( $(df -k "$MODELS_DIR" | tail -1 | awk '{print $4}') / 1048576 ))
  [ "$FREE_GB" -ge 12 ] || die 10 "disk preflight: ${FREE_GB} GB free < download + 10 GB"
  OFF=(); [ "$OFFLINE" = 1 ] && OFF=(--offline)
  set +e; python3 -I tools/dev/hf-fetch.py --set "$TIER" ${OFF[@]+"${OFF[@]}"}; rc=$?; set -e
  [ $rc = 0 ] || die $([ $rc = 20 ] && echo 20 || echo 10) "hf-fetch failed ($rc)"
  done_step ok
fi

# ---------------------------------------------------------------- 11b voice test aligner (MFA)
# AT-282 AC2 reference (A-M9-T05-AT282b): Montreal Forced Aligner 3.4.3 + english_us_arpa models, pinned and
# sha256-checked by tools/voice/setup-mfa.sh (~1.4 GB, outside the repo). Test tooling only; never shipped.
step "11b voice test aligner (MFA)"
if [ "$NO_MODELS" = 1 ]; then echo "[skip] --no-models"; done_step skip
elif [ "$OFFLINE" = 1 ] && [ ! -x "${ANTICHAT_MFA_PREFIX:-$HOME/.local/share/mfa}/bin/mfa" ]; then
  echo "[skip] --offline and no MFA env yet (run tools/voice/setup-mfa.sh online)"; done_step skip
else
  set +e; tools/voice/setup-mfa.sh; rc=$?; set -e
  [ $rc = 0 ] || die $([ $rc = 20 ] && echo 20 || echo 10) "setup-mfa failed ($rc)"
  done_step ok
fi

# ---------------------------------------------------------------- 12 dev container + env
step "12 dev container + .env.dev"
mkdir -p "$HOME/Library/Application Support/AntiChat-Dev"
if [ ! -f .env.dev ]; then
  printf 'COMPOSIO_API_KEY=dev-not-a-key\nRELAY_URL=http://localhost:3000\n' > .env.dev; echo "[fix] .env.dev"
fi
done_step ok

# ---------------------------------------------------------------- 13 smoke build + tests
step "13 make build"
make -s build || die 30 "make build"
done_step ok
step "13 make test-unit"
make -s test-unit || die 40 "make test-unit"
done_step ok

# ---------------------------------------------------------------- 14 toolchain.lock
step "14 toolchain.lock"
LOCK_NEW="$(cat <<EOF
xcode=$XCODE_PIN (build $XCB)
swift=$(swift --version 2>&1 | head -1)
macos_sdk=$(xcrun --show-sdk-version)
node=$(node --version | tr -d v)  python_tools=$(python3 --version | awk '{print $2}')  python_video=$(mise exec python@3.12 -- python --version | awk '{print $2}')  uv=$(uv --version | awk '{print $2}')  vendir=$(jq_get vendir version)  create-dmg=$(jq_get create-dmg version)  cmake=$(cmake --version | head -1 | awk '{print $3}')  ninja=$(ninja --version)
mise=$(jq_get mise version)  xcodegen=$(jq_get xcodegen version)  xcbeautify=$(jq_get xcbeautify version)  swiftlint=$(jq_get swiftlint version)  swiftformat=$(jq_get swiftformat version)
git-lfs=$(git lfs version | awk '{print $1}' | cut -d/ -f2) (system, $(command -v git-lfs))
EOF
)"
if [ -f tools/toolchain.lock ]; then
  if [ "$LOCK_NEW" = "$(cat tools/toolchain.lock)" ]; then echo "[ok] toolchain.lock unchanged"
  else echo "[warn] toolchain differs from tools/toolchain.lock:"; diff <(echo "$LOCK_NEW") tools/toolchain.lock || true; fi
else
  echo "$LOCK_NEW" > tools/toolchain.lock; echo "[fix] wrote tools/toolchain.lock"
fi
done_step ok

print_summary
echo "bootstrap OK in $(( $(date +%s) - T_START ))s (log: $LOG)"
