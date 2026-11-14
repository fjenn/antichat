#!/usr/bin/env bash
# M8.T08 (AT-NFR-PR4; NFR-PR4): after `make run` + one chat, the app's data directories are 0700, the database files
# 0600, and no AntiChat database exists outside the documented container.
#   tools/ci/data-at-rest.sh [container]   (default: $ANTICHAT_DEV_CONTAINER, else ~/Library/Application Support/AntiChat-Dev)
set -euo pipefail
container="${1:-${ANTICHAT_DEV_CONTAINER:-$HOME/Library/Application Support/AntiChat-Dev}}"
name="$(basename "$container")"; [[ "$name" == AntiChat* ]] || name="AntiChat-Dev"
fail=0
check() {  # path wanted-mode
  [[ -e "$1" ]] || { echo "skip (absent) $1"; return 0; }
  local m; m="$(stat -f '%Lp' "$1")"
  if [[ "$m" == "$2" ]]; then echo "ok   $m $1"; else echo "FAIL $m (want $2) $1"; fail=1; fi
}
check "$container" 700
check "$HOME/Library/Caches/AntiChat" 700
check "$HOME/Library/Logs/$name" 700
for f in "$container"/antichat.sqlite "$container"/antichat.sqlite-wal "$container"/antichat.sqlite-shm; do check "$f" 600; done
if [[ -d "$container/Backups" ]]; then
  while IFS= read -r f; do check "$f" 600; done < <(find "$container/Backups" -type f -name '*.sqlite*')
fi
# The app-writable roots only, shallow: a walk of all of ~/Library would touch other apps' TCC-protected data and
# raise "access data from other apps" prompts on the runner.
stray="$(find "$HOME/Library/Application Support" "$HOME/Library/Caches" "$HOME/Library/Logs" -maxdepth 3 \
  -name 'antichat.sqlite*' -not -path "$container/*" \
  -not -path '*/Application Support/AntiChat/*' -not -path '*/Application Support/AntiChat-Dev/*' 2>/dev/null || true)"
if [[ -n "$stray" ]]; then echo "FAIL database outside the documented path:"; echo "$stray"; fail=1; else echo "ok   no database outside the container"; fi
[[ $fail == 0 ]] && echo "AT AT-NFR-PR4 PASS modes=ok" || echo "AT AT-NFR-PR4 FAIL modes"
exit $fail
