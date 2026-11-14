#!/bin/bash
# AT-NFR-D7 / AT-226 AC5 (M8.T10, M8.T11): after Remove everything or Uninstall, nothing of AntiChat is left.
#   tools/ci/zero-files.sh --paths tools/ci/antichat-paths.txt [--keychain-prefix app.antichat.] [--root <dir>]
#                          [--bundle-id app.antichat.AntiChat] [--models <moved folder>]
# Lists every path of the list that exists (`~` → $HOME or --root, `$TMPDIR` → the temp dir, `*` globbed), every
# Keychain generic password whose service starts with the prefix (`security dump-keychain`), and whether
# `defaults read <bundle id>` still succeeds. Prints `hits=<n>`; exit 0 only when n = 0.
set -u
paths="" prefix="app.antichat." root="$HOME" bundle="app.antichat.AntiChat" models="" tmp="${TMPDIR:-/tmp}"
while [ $# -gt 0 ]; do
  case "$1" in
    --paths) paths="$2"; shift 2 ;;
    --keychain-prefix) prefix="$2"; shift 2 ;;
    --root) root="$2"; tmp="$2/tmp"; shift 2 ;;
    --bundle-id) bundle="$2"; shift 2 ;;
    --models) models="$2"; shift 2 ;;
    *) echo "zero-files: unknown $1" >&2; exit 2 ;;
  esac
done
[ -f "$paths" ] || { echo "zero-files: --paths <file>" >&2; exit 2; }
hits=0
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  case "$line" in '<'*) [ -n "$models" ] && line="$models" || continue ;; esac
  p="${line/#\~/$root}"
  p="${p/\$TMPDIR/$tmp}"
  p="${p//app.antichat.AntiChat/$bundle}"
  shopt -s nullglob
  dir="$(dirname "$p")" base="$(basename "$p")"
  for f in "$dir"/$base; do
    if [ -e "$f" ] || [ -L "$f" ]; then echo "path: $f"; hits=$((hits + 1)); fi
  done
  shopt -u nullglob
done < "$paths"
if [ -n "$prefix" ] && command -v security >/dev/null; then
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    echo "keychain: $svc"; hits=$((hits + 1))
  done < <(security dump-keychain 2>/dev/null | sed -n 's/.*"svce"<blob>="\(.*\)"$/\1/p' | grep "^${prefix//./\\.}" | sort -u)
fi
if [ "$root" = "$HOME" ] && defaults read "$bundle" >/dev/null 2>&1; then
  echo "defaults: $bundle"; hits=$((hits + 1))
fi
echo "hits=$hits"
[ "$hits" -eq 0 ]
