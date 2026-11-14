#!/usr/bin/env bash
# GIT_EXE for the patched sd.cpp copy (tools/binaries/build.sh, A-M9-T05a). The copy in build/sdcpp-src has no .git,
# so sd.cpp's and ggml's CMake `git describe` / `rev-parse --short HEAD` would walk up into the AntiChat repo and
# stamp AntiChat's HEAD into sd-server/sd-cli (a different binary per AntiChat commit). This wrapper runs git in the
# pinned submodule directory that corresponds to the copy instead: PINNED_GIT_COPY=<copy root>, PINNED_GIT_SRC=<submodule>.
# Abbreviations are fixed-length, so the stamp does not depend on how many objects the local clone holds.
set -euo pipefail
here="$(pwd -P)"
copy="$(cd "${PINNED_GIT_COPY:?}" && pwd -P)"
case "$here" in
  "$copy") dir="$PINNED_GIT_SRC" ;;
  "$copy"/*) dir="$PINNED_GIT_SRC/${here#"$copy"/}" ;;
  *) echo "git-pinned: $here is outside $copy" >&2; exit 2 ;;
esac
args=()
for a in "$@"; do
  case "$a" in
    --short) args+=(--short=8) ;;   # ggml/sd.cpp: rev-parse --short HEAD
    *) args+=("$a") ;;
  esac
done
exec git -C "$dir" "${args[@]}"
