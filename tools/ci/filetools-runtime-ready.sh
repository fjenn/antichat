#!/bin/bash
# Prerequisite of the hosted File tools suites (make test-integration-stub / -real): the signed runtime zip that
# catalog/runtimes.yaml names must exist with exactly the catalog's sha256 (FileToolsIT installs it). A fresh worktree
# has none: build + sign it (make runtime-filetools SIGN=1, deterministic) and re-check. A sha that still differs, or a
# build that rewrote catalog/runtimes.yaml, fails the gate instead of letting the suites skip or test another runtime.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
ver=$(awk '/name: filetools-runtime/ {f=1} f && /version:/ {gsub(/"/,"",$2); print $2; exit}' catalog/runtimes.yaml)
sha=$(awk '/name: filetools-runtime/ {f=1} f && /sha256:/ {print $2; exit}' catalog/runtimes.yaml)
[ -n "$ver" ] && [ -n "$sha" ] || { echo "filetools-runtime-ready: no filetools-runtime entry in catalog/runtimes.yaml" >&2; exit 1; }
zip="build/runtimes/signed/filetools-runtime-$ver.zip"
have() { [ -f "$zip" ] && [ "$(shasum -a 256 "$zip" | cut -d' ' -f1)" = "$sha" ]; }
if have; then echo "filetools-runtime-ready: $zip ok ($sha)"; exit 0; fi
echo "filetools-runtime-ready: $zip missing or stale; building it (make runtime-filetools SIGN=1)"
cp catalog/runtimes.yaml "${TMPDIR:-/tmp}/runtimes.yaml.before.$$"
make runtime-filetools SIGN=1
if ! cmp -s catalog/runtimes.yaml "${TMPDIR:-/tmp}/runtimes.yaml.before.$$"; then
  cp "${TMPDIR:-/tmp}/runtimes.yaml.before.$$" catalog/runtimes.yaml
  echo "filetools-runtime-ready: the rebuilt runtime does not reproduce the catalog sha256 (catalog restored); fix the build" >&2
  exit 1
fi
have || { echo "filetools-runtime-ready: $zip sha256 != catalog $sha after the build" >&2; exit 1; }
echo "filetools-runtime-ready: built $zip ($sha)"
