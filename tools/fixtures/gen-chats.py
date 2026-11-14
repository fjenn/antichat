#!/usr/bin/env python3
"""Big chat-database generator (M1.T04 step 7; NFR-U8/U10/U11 perf tests, AT-012).

Writes an AntiChat v1 database (schema = Packages/Storage/Schema/v1_core.sql, the frozen DDL that
MigrationV1Tests checks against migration `v1_core`) holding:
  * --chats N chats with 2..12 messages each (seeded vocabulary, deterministic),
  * --long K:M  K of them with M messages each (default 1:1000),
  * --turns T   one chat with T user/assistant turns, every 25th reply with a regenerated sibling (default 500),
  * the fixture token (`zebracorn`) in exactly one message body,
  * --memories N --memory-topics K: N active memory items over K topics (M8.T03 visual QA; default 0 = none),
    each with its `add` event and its `chunk(source='memory')` mirror, as MemoryStore writes them,
  * --projects P --project-files F: P projects (instructions + F copied text files each, 3 chats moved in) (M8.T07),
  * --evil E: E regular chats in Evil mode (M8.T07),
  * --images I: I small PNG pictures attached to user messages (file_blob + attachment; files under --media-dir).
The file opens in AntiChat without migrating (`grdb_migrations` has every identifier of the frozen DDL).

Usage: python3 -I tools/fixtures/gen-chats.py --seed fixtures/chats/big-10k/seed.json --chats 10000 --long 1:1000
       [--turns 500] [--memories 12 --memory-topics 4] [--projects 2 --project-files 4 --evil 1 --images 50]
       [--out build/fixtures/big-10k.sqlite] [--media-dir <dir, default: <out>-media>]
stdlib + sqlite3 only.
"""
import argparse
import hashlib
import json
import pathlib
import random
import sqlite3
import sys
import uuid
import struct
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCHEMA = ROOT / "Packages/Storage/Schema/v1_core.sql"
SEEDS = [ROOT / "fixtures/chats/big-10k/seed.json", ROOT / "tools/fixtures/seeds/big-10k.json"]


class Gen:
    def __init__(self, seed, rng):
        self.seed = seed
        self.rng = rng
        self.clock = float(seed["base_time"])

    def tick(self, seconds=None):
        self.clock += seconds if seconds is not None else self.rng.uniform(1, 90)
        return round(self.clock, 3)

    def uuid7(self, ts):
        """RFC 9562 UUIDv7 from `ts` (seconds) and the seeded RNG (deterministic output)."""
        ms = int(ts * 1000) & ((1 << 48) - 1)
        rand_a = self.rng.getrandbits(12)
        rand_b = self.rng.getrandbits(62)
        value = (ms << 80) | (0x7 << 76) | (rand_a << 64) | (0b10 << 62) | rand_b
        return str(uuid.UUID(int=value))

    def sentence(self, lo, hi):
        words = [self.rng.choice(self.seed["words"]) for _ in range(self.rng.randint(lo, hi))]
        return " ".join(words).capitalize() + "."

    def user_text(self, topic):
        return f"{self.rng.choice(self.seed['user_openers'])} {topic}? {self.sentence(4, 14)}"

    def reply_text(self):
        return " ".join(self.sentence(6, 18) for _ in range(self.rng.randint(1, 4)))


# M8.T03: a fixed fact bank (topic → facts); --memory-topics takes the first K topics, facts round-robin over them.
MEMORY_BANK = [
    ("Food", ["Vegetarian", "Likes Thai curry", "Allergic to peanuts", "Drinks oat milk", "Bakes sourdough on weekends"]),
    ("Work", ["Works as a night nurse", "Team uses Swift", "Prefers short summaries", "Starts work at 7 am", "Writes in British English"]),
    ("Family", ["Has two daughters", "Partner is called Sam", "Mother lives in Lisbon", "Has a golden retriever", "Visits family in August"]),
    ("Hobbies", ["Plays jazz piano", "Runs on Sundays", "Reads science fiction", "Learning Portuguese", "Climbs at an indoor gym"]),
    ("Travel", ["Prefers trains to planes", "Planning a trip to Japan", "Has a window-seat preference", "Lived in Berlin", "Uses metric units"]),
    ("Home", ["Lives in a flat in Porto", "Has a small balcony garden", "Uses a Mac mini", "Works from home on Fridays", "Has solar panels"]),
]


def insert_memories(db, g, n, k):
    k = max(1, min(k, len(MEMORY_BANK)))
    topics = MEMORY_BANK[:k]
    if n > sum(len(f) for _, f in topics):
        sys.exit(f"gen-chats: --memories {n} exceeds the {k}-topic fact bank")
    topic_ids = {}
    for name, _ in topics:
        ts = g.tick()
        topic_ids[name] = g.uuid7(ts)
        db.execute("INSERT INTO memory_topic (id, scope, project_id, name, created_at, updated_at) VALUES (?, 'global', NULL, ?, ?, ?)",
                   (topic_ids[name], name, ts, ts))
    for i in range(n):
        name, facts = topics[i % k]
        text = facts[i // k]
        key = "-".join(text.lower().split()[:4])[:64]
        ts = g.tick()
        item = g.uuid7(ts)
        db.execute("INSERT INTO memory_item (id, topic_id, scope, project_id, key, text, state, origin, created_at, updated_at) "
                   "VALUES (?, ?, 'global', NULL, ?, ?, 'active', 'user', ?, ?)", (item, topic_ids[name], key, text, ts, ts))
        after = json.dumps({"topic": name, "key": key, "text": text}, sort_keys=True)
        db.execute("INSERT INTO memory_event (id, item_id, op, before_json, after_json, created_at) VALUES (?, ?, 'add', NULL, ?, ?)",
                   (g.uuid7(ts), item, after, ts))
        db.execute("INSERT INTO chunk (source, source_id, chat_id, ord, text, created_at) VALUES ('memory', ?, NULL, 0, ?, ?)",
                   (item, f"{name}: {key}: {text}", ts))


def png_bytes(r, g_, b, size=8):
    """A tiny valid RGB PNG of one colour (distinct colours = distinct sha256)."""
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + bytes((r, g_, b)) * size for _ in range(size))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def store_blob(db, g, media_dir, data, ext, ts):
    sha = hashlib.sha256(data).hexdigest()
    path = media_dir / f"{sha}.{ext}"
    path.write_bytes(data)
    blob = g.uuid7(ts)
    db.execute("INSERT INTO file_blob (id, sha256, size, path, created_at, origin) VALUES (?, ?, ?, ?, ?, 'upload')",
               (blob, sha, len(data), str(path), ts))
    return blob


def insert_images(db, g, media_dir, n, regular):
    users = [ids[0] for ids in regular if ids]
    for i in range(n):
        mid = users[(i * 7) % len(users)]
        ts = db.execute("SELECT created_at FROM message WHERE id = ?", (mid,)).fetchone()[0]
        blob = store_blob(db, g, media_dir, png_bytes(i % 256, (i * 37) % 256, (i * 91) % 256), "png", ts)
        db.execute("INSERT INTO attachment (id, message_id, blob_id, display_name, uti, created_at) "
                   "VALUES (?, ?, ?, ?, 'public.png', ?)", (g.uuid7(ts), mid, blob, f"picture-{i + 1}.png", ts))


def insert_projects(db, g, media_dir, n, files, chat_ids):
    for p in range(n):
        ts = g.tick()
        pid = g.uuid7(ts)
        db.execute("INSERT INTO project (id, name, icon, memory_mode, created_at, updated_at) VALUES (?, ?, 'folder', 'global', ?, ?)",
                   (pid, f"Project {p + 1}", ts, ts))
        db.execute("INSERT INTO project_instruction (project_id, text, updated_at) VALUES (?, ?, ?)",
                   (pid, f"Answer as the project {p + 1} assistant. {g.sentence(6, 12)}", ts))
        for f in range(files):
            text = f"# Notes {p + 1}.{f + 1}\n\n{g.reply_text()}\n".encode()
            blob = store_blob(db, g, media_dir, text, "md", ts)
            db.execute("INSERT INTO project_file (id, project_id, blob_id, display_name, uti, size, origin, index_state, progress, created_at) "
                       "VALUES (?, ?, ?, ?, 'net.daringfireball.markdown', ?, 'copied', 'ready', 1, ?)",
                       (g.uuid7(ts), pid, blob, f"notes-{f + 1}.md", len(text), ts))
        for cid in chat_ids[p * 3:(p + 1) * 3]:
            db.execute("UPDATE chat SET project_id = ? WHERE id = ?", (pid, cid))


def insert_chat(db, g, title, created, mode="normal"):
    chat_id = g.uuid7(created)
    db.execute(
        "INSERT INTO chat (id, title, title_state, mode, created_at, updated_at) VALUES (?, ?, 'auto', ?, ?, ?)",
        (chat_id, title, mode, created, created),
    )
    return chat_id


def insert_message(db, g, chat_id, parent, role, text, position=0):
    ts = g.tick()
    mid = g.uuid7(ts)
    provenance = None
    if role == "assistant":
        provenance = json.dumps(
            {"model_sha": "sha256-fixture", "mode": "normal", "sampling_json": {"temperature": 0.7},
             "tok_per_s": round(g.rng.uniform(20, 120), 1)}, sort_keys=True)
    db.execute(
        "INSERT INTO message (id, chat_id, parent_id, position, role, status, model_id, engine, provenance_json, "
        "created_at) VALUES (?, ?, ?, ?, ?, 'done', ?, ?, ?, ?)",
        (mid, chat_id, parent, position, role, "chat-0.8b" if role == "assistant" else None,
         "mlx" if role == "assistant" else None, provenance, ts),
    )
    db.execute("INSERT INTO message_part (message_id, idx, kind, body) VALUES (?, 0, 'text', ?)", (mid, text))
    if parent is not None:
        db.execute("UPDATE message SET active_child_id = ? WHERE id = ?", (mid, parent))
    return mid


def linear_chat(db, g, topic, n_messages, title=None, mode="normal"):
    chat_id = insert_chat(db, g, title or g.rng.choice(g.seed["title_templates"]).format(topic=topic).capitalize(),
                          g.tick(600), mode)
    parent = None
    ids = []
    for i in range(n_messages):
        role = "user" if i % 2 == 0 else "assistant"
        parent = insert_message(db, g, chat_id, parent, role, g.user_text(topic) if role == "user" else g.reply_text())
        ids.append(parent)
    db.execute("UPDATE chat SET leaf_message_id = ?, updated_at = ? WHERE id = ?", (parent, g.clock, chat_id))
    return chat_id, ids


def turns_chat(db, g, topic, turns):
    """`turns` user/assistant turns; every 25th reply has an older, inactive version (a regenerate)."""
    chat_id = insert_chat(db, g, f"{topic.capitalize()} ({turns} turns)", g.tick(600))
    parent = None
    for t in range(turns):
        user = insert_message(db, g, chat_id, parent, "user", g.user_text(topic))
        if t % 25 == 24:
            insert_message(db, g, chat_id, user, "assistant", g.reply_text(), position=0)  # older version
            parent = insert_message(db, g, chat_id, user, "assistant", g.reply_text(), position=1)
        else:
            parent = insert_message(db, g, chat_id, user, "assistant", g.reply_text())
    db.execute("UPDATE chat SET leaf_message_id = ?, updated_at = ? WHERE id = ?", (parent, g.clock, chat_id))
    return chat_id


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=pathlib.Path, help="seed JSON (default: fixtures/chats/big-10k/seed.json, "
                    "else tools/fixtures/seeds/big-10k.json)")
    ap.add_argument("--chats", type=int, default=10000, help="total chats (default 10000)")
    ap.add_argument("--long", default="1:1000", help="K:M = K chats with M messages each (default 1:1000)")
    ap.add_argument("--turns", type=int, default=500, help="one chat with this many turns (0 = none; default 500)")
    ap.add_argument("--memories", type=int, default=0, help="active memory items (M8.T03; default 0)")
    ap.add_argument("--memory-topics", type=int, default=4, help="topics the memories spread over (default 4)")
    ap.add_argument("--projects", type=int, default=0, help="projects with instructions and files (M8.T07; default 0)")
    ap.add_argument("--project-files", type=int, default=4, help="copied files per project (default 4)")
    ap.add_argument("--evil", type=int, default=0, help="regular chats in Evil mode (M8.T07; default 0)")
    ap.add_argument("--images", type=int, default=0, help="PNG pictures attached to user messages (M8.T07; default 0)")
    ap.add_argument("--out", type=pathlib.Path, default=ROOT / "build/fixtures/big-10k.sqlite")
    ap.add_argument("--media-dir", type=pathlib.Path, help="where pictures/project files go (default <out>-media)")
    ap.add_argument("--schema", type=pathlib.Path, default=SCHEMA)
    args = ap.parse_args()

    seed_path = args.seed or next((p for p in SEEDS if p.exists()), None)
    if seed_path is None or not seed_path.exists():
        sys.exit(f"gen-chats: no seed file ({args.seed or ', '.join(map(str, SEEDS))})")
    seed = json.loads(seed_path.read_text())
    long_k, long_m = (int(x) for x in args.long.split(":"))
    special = long_k + (1 if args.turns else 0)
    if args.chats < special + 1:
        sys.exit("gen-chats: --chats must exceed the long and turns chats")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    for suffix in ("", "-wal", "-shm"):
        pathlib.Path(str(args.out) + suffix).unlink(missing_ok=True)
    db = sqlite3.connect(args.out, isolation_level=None)
    db.execute("PRAGMA foreign_keys = ON")
    db.executescript(args.schema.read_text())
    # Every migration the frozen DDL contains (Migrations.identifiers), so the app opens the file without migrating.
    # Read from Migrations.swift (`identifiers = [...]`) so a new migration needs no edit here (M2.T01).
    import re
    mig = (ROOT / "Packages/Storage/Sources/AntiChatStorage/Database/Migrations.swift").read_text()
    idents = re.findall(r'"(v\d+_\w+)"', re.search(r"identifiers = \[([^\]]*)\]", mig).group(1))
    for ident in idents:
        db.execute("INSERT INTO grdb_migrations (identifier) VALUES (?)", (ident,))

    g = Gen(seed, random.Random(seed["rng_seed"]))
    topics = seed["topics"]
    lo, hi = seed["messages_per_chat"]
    db.execute("BEGIN")
    regular = []
    regular_chats = []
    for i in range(args.chats - special):
        evil = i >= args.chats - special - args.evil  # the chat mode is fixed at the first message (trigger)
        cid, ids = linear_chat(db, g, topics[i % len(topics)], g.rng.randint(lo, hi), mode="evil" if evil else "normal")
        regular.append(ids)
        regular_chats.append(cid)
    for k in range(long_k):
        linear_chat(db, g, g.rng.choice(topics), long_m, title=f"Long chat {k + 1} ({long_m} messages)")
    if args.turns:
        turns_chat(db, g, g.rng.choice(topics), args.turns)
    # The fixture token, in exactly one body of one regular chat.
    target = g.rng.choice(g.rng.choice(regular))
    db.execute("UPDATE message_part SET body = body || ? WHERE message_id = ? AND idx = 0",
               (f" The {seed['token']} is the search fixture.", target))
    if args.memories:
        insert_memories(db, g, args.memories, args.memory_topics)
    media_dir = args.media_dir or pathlib.Path(str(args.out) + "-media")
    if args.images or args.projects:
        media_dir.mkdir(parents=True, exist_ok=True)
    if args.images:
        insert_images(db, g, media_dir, args.images, regular)
    if args.projects:
        insert_projects(db, g, media_dir, args.projects, args.project_files, regular_chats)
    db.execute("COMMIT")
    db.execute("PRAGMA journal_mode = WAL")
    counts = {t: db.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
              for t in ("chat", "message", "message_part", "memory_item", "memory_topic", "attachment", "project",
                        "project_file")}
    hits = db.execute("SELECT COUNT(*) FROM message_part WHERE body LIKE ?", (f"%{seed['token']}%",)).fetchone()[0]
    bad = db.execute("PRAGMA foreign_key_check").fetchall()
    db.close()
    if hits != 1 or bad:
        sys.exit(f"gen-chats: self-check failed (token hits {hits}, foreign_key_check {len(bad)})")
    print(json.dumps({"out": str(args.out), "seed": str(seed_path), **counts, "token_hits": hits}, sort_keys=True))


if __name__ == "__main__":
    main()
