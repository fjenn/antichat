#!/bin/zsh
# A chat database with one long chat for the renderer / transcript checks (fix/u5-renderer): TURNS finished turns
# (default 40 = 80+ rows) whose replies are Markdown (headings, paragraphs, lists, code, tables, math: ~2.5 KB slices
# of the mixed-3k reply). Prints the long chat's id.
# Usage: tools/at/longchat-db.sh <out.sqlite> [TURNS=40]   (ANTICHAT_FIXTURES=<main>/fixtures in a worktree)
# Used by tools/at/at-008-longchat.sh and the long-chat XCUITest leg (ImageEditTests.testEditGeneratedImageInLongChat:
# TEST_RUNNER_ANTICHAT_LONGCHAT_DB / TEST_RUNNER_ANTICHAT_LONGCHAT_ID).
set -u
ROOT=${0:A:h:h:h}
DB=${1:?out.sqlite}
TURNS=${2:-40}
rm -f "$DB"
SEED=${ANTICHAT_FIXTURES:-$ROOT/fixtures}/chats/big-10k/seed.json  # a worktree without the fixtures checkout: ANTICHAT_FIXTURES=<main>/fixtures
[[ -f $SEED ]] || SEED=$ROOT/tools/fixtures/chats/big-10k/seed.json
python3 -I "$ROOT/tools/fixtures/gen-chats.py" --seed "$SEED" --chats 2 --long 0:0 --turns "$TURNS" --out "$DB" >/dev/null || exit 2
SCRIPT=$ROOT/fixtures/scripts/mixed-3k.jsonl
[[ -f $SCRIPT ]] || SCRIPT=$ROOT/tools/fixtures/scripts/mixed-3k.jsonl
python3 -I - "$DB" "$SCRIPT" <<'PY' || exit 2
import json, re, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
text = "".join(json.loads(l)["v"] for l in open(sys.argv[2]) if l.startswith("{") and json.loads(l).get("t") == "textDelta")
blocks, open_ = [], False
for b in (x for x in re.split(r"\n\n+", text) if x.strip()):  # a fenced block stays whole
    if open_: blocks[-1] += "\n\n" + b
    else: blocks.append(b)
    if b.count("```") % 2: open_ = not open_
# ~2.5 KB replies: consecutive runs of the reply's blocks, rotating through it (each has a few block kinds).
replies, cur = [], []
for b in blocks * 3:
    cur.append(b)
    if sum(len(x) for x in cur) > 2500:
        replies.append("\n\n".join(cur)); cur = []
chat = db.execute("SELECT chat_id FROM message GROUP BY chat_id ORDER BY COUNT(*) DESC LIMIT 1").fetchone()[0]
ids = [r[0] for r in db.execute("SELECT id FROM message WHERE chat_id = ? AND role = 'assistant' ORDER BY created_at", (chat,))]
for i, mid in enumerate(ids):
    db.execute("UPDATE message_part SET body = ? WHERE message_id = ? AND idx = 0", (replies[i % len(replies)], mid))
db.commit()
print(chat)
PY
