#!/bin/zsh
# AT-008 leg 4, long-chat variant (fix/u5-renderer): the same in-process renderer probe as at-008-probe.sh, but the
# reply streams into a chat that already holds TURNS finished turns (default 40 = 80 rows) whose replies are
# Markdown (headings, paragraphs, lists, code, tables, math: slices of the mixed-3k reply), so the transcript's
# finished rows are on screen and in the view graph while the reply streams.
# Usage: tools/at/run.sh AT-008 -- tools/at/at-008-longchat.sh [CPU_SCALE=0.25] [TURNS=40]
# Output: build/at/AT-008/longchat/{renderer.json, summary.json, …} (AT008_APP selects the app, as in at-008-probe.sh)
set -u
ROOT=${0:A:h:h:h}
SCALE=${1:-0.25}
TURNS=${2:-40}
OUT=$ROOT/build/at/AT-008/longchat
mkdir -p "$OUT"
DB=$OUT/seed.sqlite
CHAT=$("$ROOT/tools/at/longchat-db.sh" "$DB" "$TURNS") || exit 2
echo "long chat $CHAT ($TURNS turns) in $DB"
AT008_OUT=$OUT AT008_DB=$DB AT008_CHAT=$CHAT exec "$ROOT/tools/at/at-008-probe.sh" "$SCALE" mixed-3k
