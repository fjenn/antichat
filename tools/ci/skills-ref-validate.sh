#!/usr/bin/env bash
# AT-261 c2 (M7.T12; R-261 AC2): run the Agent Skills reference validator (agentskills/agentskills@69ef37e942,
# skills-ref) on skill folders and exported zips. A zip is unpacked into a temp folder first (the validator reads a
# folder; the zip's single top-level folder is the skill). Exit 0 only when every argument validates.
#   tools/ci/skills-ref-validate.sh build/at/AT-261/exports/*
# Needs uv (bootstrap); the first run fetches the pinned validator from GitHub, later runs use uv's cache.
set -euo pipefail
REF="git+https://github.com/agentskills/agentskills@69ef37e942#subdirectory=skills-ref"
[ $# -gt 0 ] || { echo "usage: $0 <skill dir | skill zip>..." >&2; exit 2; }
command -v uvx >/dev/null || { echo "uvx not found (run make bootstrap)" >&2; exit 2; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0; n=0
for arg in "$@"; do
  n=$((n + 1))
  dir="$arg"
  if [ -f "$arg" ]; then
    out="$tmp/$n"; mkdir -p "$out"
    ditto -x -k "$arg" "$out"
    tops=("$out"/*)
    if [ ${#tops[@]} -ne 1 ] || [ ! -d "${tops[0]}" ]; then
      echo "FAIL $arg: expected one top-level folder"; fail=1; continue
    fi
    dir="${tops[0]}"
  fi
  if uvx -q --from "$REF" skills-ref validate "$dir" >"$tmp/log" 2>&1; then
    echo "ok   $arg ($(head -1 "$tmp/log"))"
  else
    echo "FAIL $arg"; sed 's/^/     /' "$tmp/log"; fail=1
  fi
done
echo "skills-ref-validate: $n checked, $([ $fail -eq 0 ] && echo 'all valid' || echo 'FAILURES')"
exit $fail
