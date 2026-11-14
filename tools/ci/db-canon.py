#!/usr/bin/env python3
"""Canonical, order-independent dump of an AntiChat database's user data (M8.T01; reused by M8.T07).

  db-canon.py <antichat.sqlite> [--out <file.json>] [--roundtrip]   -> JSON on stdout (or --out), sha256 on stderr

--roundtrip (M8.T07, AT-093): the view an export-all zip promises to keep. Leaves out what the format does not carry
or re-creates by design: message_part.id (AUTOINCREMENT, re-assigned), file_blob.path (re-homed under the new media
folder), project.linked_folder_bookmark (machine-specific), memory events, non-active memory items; import_record
and memory_suggestion are never part of the dump.

Tables: chats, messages, parts, attachments, blobs, drafts, feedback, projects, project files/instructions and
memory (each only if present at that schema version). Rows are sorted by their key, REAL timestamps become ISO
8601 (UTC, ms), BLOB values become their sha256. The file is opened read-only and immutable (nothing is written,
not even -shm), so a WAL file must be checkpointed first (backups and fixtures are DELETE-journal files).
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import sqlite3
import sys

TABLES = {
    "chat": "id", "message": "id", "message_part": "message_id, idx", "attachment": "id", "file_blob": "id",
    "draft": "chat_id", "feedback": "message_id, kind", "project": "id", "project_file": "id",
    "project_instruction": "project_id", "memory_topic": "id", "memory_item": "id", "memory_event": "id",
}
TIME_COLS = ("_at", "ts")


def value(col: str, v):
    if isinstance(v, bytes):
        return "sha256:" + hashlib.sha256(v).hexdigest()
    if isinstance(v, float) and col.endswith(TIME_COLS):
        return datetime.datetime.fromtimestamp(v, datetime.timezone.utc).isoformat(timespec="milliseconds")
    return v


ROUNDTRIP_DROP = {"message_part": {"id"}, "file_blob": {"path"}, "project": {"linked_folder_bookmark"},
                  # M8.T16 review fix: imported project files are indexed again (the zip carries no chunks or text).
                  "project_file": {"index_state", "progress", "text_tokens", "mtime"}}
ROUNDTRIP_SKIP = {"memory_event"}
ROUNDTRIP_WHERE = {"memory_item": "state = 'active'"}


def dump(path: str, roundtrip: bool = False) -> dict:
    con = sqlite3.connect(f"file:{path}?mode=ro&immutable=1", uri=True)
    present = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    out = {}
    for table, key in TABLES.items():
        if table not in present or (roundtrip and table in ROUNDTRIP_SKIP):
            continue
        where = f" WHERE {ROUNDTRIP_WHERE[table]}" if roundtrip and table in ROUNDTRIP_WHERE else ""
        cur = con.execute(f"SELECT * FROM {table}{where} ORDER BY {key}")
        cols = [d[0] for d in cur.description]
        drop = ROUNDTRIP_DROP.get(table, set()) if roundtrip else set()
        out[table] = [{c: value(c, v) for c, v in zip(cols, row) if c not in drop} for row in cur]
    con.close()
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("db")
    ap.add_argument("--out")
    ap.add_argument("--roundtrip", action="store_true")
    a = ap.parse_args()
    text = json.dumps(dump(a.db, a.roundtrip), sort_keys=True, indent=1, ensure_ascii=False)
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
    else:
        print(text)
    print(hashlib.sha256(text.encode()).hexdigest(), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
