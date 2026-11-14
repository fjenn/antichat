#!/usr/bin/env python3
"""Build the synthetic Claude data-export fixture (M0.T11 step 2, P-platform-10).

No real Claude export sample exists (D-004), so this writes one from the documented field set:
  conversation: uuid, name, summary, created_at, updated_at, current_leaf_message_uuid, chat_messages
  message:      uuid, parent_message_uuid, sender ("human"|"assistant") or role ("user"|"human"|"assistant"),
                text and/or content (string, or array of {type, text|thinking} blocks), created_at, updated_at,
                attachments, files
per sugurutakahashi-1234/ai-chat-md-export@e681a7e:src/infrastructure/parsers/claude/schema.ts (MIT)
plus the tree fields `parent_message_uuid` / `current_leaf_message_uuid` that P-platform-10 names.
The root's parent is the all-zero v4 sentinel 00000000-0000-4000-8000-000000000000 [ASSUMPTION: the
value seen in community write-ups of Claude exports; the importer also accepts null/missing].

Three conversations: linear; one edit branch; two nested branches + a dangling parent + an empty
(skipped) message whose child is re-parented. The expected tree for each is written BY HAND in the
SPEC below (`exp` = the expected parent after skipping unusable nodes), not computed from the export,
so it is an independent oracle for ImportRoundTripTests.

Usage: python3 -I tools/fixtures/make-claude-export.py [--out fixtures/chats/claude-export]
Deterministic: seed 20261030, fixed timestamps, stored (uncompressed) zip entries with a fixed mtime.
"""
import argparse
import json
import os
import random
import time
import uuid
import zipfile

SEED = 20261030
ROOT_SENTINEL = "00000000-0000-4000-8000-000000000000"
ZIP_TIME = (2026, 10, 30, 0, 0, 0)

# Each message: (key, parent key | None (root) | "!dangling", role field, role value, content kind, text, exp)
#   role field: "sender" or "role" (old exports); content kind: "text" (flat text field only),
#   "string" (content is a string), "blocks" (content array + flat text), "blocks-thinking"
#   (thinking block + text block), "empty" (no usable text -> skipped by the importer).
#   exp: expected parent key after import (None = root), or "skip" for a dropped node.
SPEC = [
    {
        "key": "linear",
        "name": "Synthetic: linear chat about sourdough starters",
        "leaf": "a2",
        "messages": [
            ("h1", None, "role", "user", "string", "How often should I feed a sourdough starter?", None),
            ("a1", "h1", "sender", "assistant", "text", "Once a day at room temperature, or weekly if it lives in the fridge.", "h1"),
            ("h2", "a1", "role", "human", "string", "And how much flour per feeding?", "a1"),
            ("a2", "h2", "role", "assistant", "blocks", "Equal weights of starter, flour and water is a common 1:1:1 ratio.", "h2"),
        ],
    },
    {
        "key": "edit-branch",
        "name": "Synthetic: one edit branch",
        "leaf": "a2b",
        "messages": [
            ("h1", None, "sender", "human", "blocks", "Suggest a name for a grey cat.", None),
            ("a1", "h1", "sender", "assistant", "blocks-thinking", "How about Pebble, Ash or Smokey?", "h1"),
            ("h2a", "a1", "sender", "human", "blocks", "Something longer, please.", "a1"),
            ("a2a", "h2a", "sender", "assistant", "blocks", "Sir Reginald Fluffington.", "h2a"),
            # The user edited h2a into h2b: a sibling under a1; the export's current leaf is on this branch.
            ("h2b", "a1", "sender", "human", "blocks", "Something that sounds like weather.", "a1"),
            ("a2b", "h2b", "sender", "assistant", "blocks", "Drizzle, Nimbus or Fog.", "h2b"),
        ],
    },
    {
        "key": "nested-branches",
        "name": "Synthetic: two nested branches, a dangling parent and a skipped empty message",
        "leaf": "a3",
        "messages": [
            ("h1", None, "sender", "human", "text", "Plan a three-day trip to Lisbon.", None),
            ("a1", "h1", "sender", "assistant", "blocks", "Day 1 Alfama, day 2 Belem, day 3 Sintra.", "h1"),
            # Branch 1 at a1: two edits of the follow-up question.
            ("h2a", "a1", "sender", "human", "blocks", "Make it cheaper.", "a1"),
            ("a2a", "h2a", "sender", "assistant", "blocks", "Swap Sintra for free viewpoints and walk instead of taxis.", "h2a"),
            ("h2b", "a1", "sender", "human", "blocks", "Add food recommendations.", "a1"),
            # Branch 2, nested under branch 1's second arm: the answer was regenerated.
            ("a2b1", "h2b", "sender", "assistant", "blocks", "Try pasteis de nata in Belem.", "h2b"),
            ("a2b2", "h2b", "sender", "assistant", "blocks-thinking", "Pasteis de nata, bifanas and grilled sardines.", "h2b"),
            ("h3", "a2b2", "role", "human", "string", "Where do I get the best sardines?", "a2b2"),
            # An assistant message with no usable text (e.g. an interrupted reply) -> skipped;
            # its child a3 is re-parented to the nearest usable ancestor h3.
            ("e3", "h3", "sender", "assistant", "empty", "", "skip"),
            ("a3", "e3", "sender", "assistant", "blocks", "The Santos Populares stalls in June, or any tasca in Alfama.", "h3"),
            # A message whose parent uuid is not in the conversation -> orphan, attached to the root h1
            # and flagged recovered (M0.md T11 failure mode 2).
            ("d1", "!dangling", "sender", "human", "blocks", "(message from a truncated export)", "h1"),
        ],
    },
]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join("fixtures", "chats", "claude-export"))
    args = ap.parse_args()
    rng = random.Random(SEED)

    def new_uuid() -> str:
        return str(uuid.UUID(int=rng.getrandbits(128), version=4))

    base = 1767225600  # 2026-01-01T00:00:00Z
    conversations, expected = [], []
    for ci, conv in enumerate(SPEC):
        ids = {m[0]: new_uuid() for m in conv["messages"]}
        conv_uuid = new_uuid()
        t0 = base + ci * 86400

        def ts(i: int) -> str:
            s = t0 + i * 60
            return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(s)) + ".000000Z"

        msgs = []
        for i, (key, parent, role_field, role_value, kind, text, _exp) in enumerate(conv["messages"]):
            if parent is None:
                parent_uuid = ROOT_SENTINEL
            elif parent == "!dangling":
                parent_uuid = new_uuid()  # not a message of this conversation
            else:
                parent_uuid = ids[parent]
            m = {"uuid": ids[key], role_field: role_value}
            if kind == "text":
                m["text"] = text
            elif kind == "string":
                m["content"] = text
            elif kind == "blocks":
                m["text"] = text
                m["content"] = [{"type": "text", "text": text}]
            elif kind == "blocks-thinking":
                m["text"] = text
                m["content"] = [{"type": "thinking", "thinking": "Synthetic reasoning for " + key + "."},
                                {"type": "text", "text": text}]
            elif kind == "empty":
                m["text"] = ""
                m["content"] = []
            m["created_at"] = ts(i)
            m["updated_at"] = ts(i)
            m["attachments"] = []
            m["files"] = []
            m["parent_message_uuid"] = parent_uuid
            msgs.append(m)
        conversations.append({
            "uuid": conv_uuid,
            "name": conv["name"],
            "summary": "",
            "created_at": ts(0),
            "updated_at": ts(len(msgs)),
            "account": {"uuid": "00000000-0000-4000-8000-0000000000aa"},
            "current_leaf_message_uuid": ids[conv["leaf"]],
            "chat_messages": msgs,
        })

        kept = [m for m in conv["messages"] if m[6] != "skip"]
        exp_parent = {m[0]: m[6] for m in kept}
        path, cur = [], conv["leaf"]
        while cur is not None:
            path.append(ids[cur])
            cur = exp_parent[cur]
        path.reverse()
        expected.append({
            "id": conv_uuid,
            "key": conv["key"],
            "nodes": len(kept),
            "edges": [[ids[k], ids[p] if p else None] for k, p in exp_parent.items()],
            "recovered": [ids[m[0]] for m in kept if m[1] == "!dangling"],
            "active_leaf": ids[conv["leaf"]],
            "active_path": path,
        })

    users = [{"uuid": "00000000-0000-4000-8000-0000000000aa", "full_name": "Synthetic Fixture User",
              "email_address": "fixture@example.invalid"}]
    os.makedirs(args.out, exist_ok=True)
    zpath = os.path.join(args.out, "synthetic-branches.zip")
    with zipfile.ZipFile(zpath, "w", compression=zipfile.ZIP_STORED) as z:
        for name, obj in (("conversations.json", conversations), ("users.json", users)):
            info = zipfile.ZipInfo(name, date_time=ZIP_TIME)
            info.external_attr = 0o644 << 16
            z.writestr(info, json.dumps(obj, indent=2, ensure_ascii=False) + "\n")
    with open(os.path.join(args.out, "synthetic-branches.expected.json"), "w") as f:
        json.dump({
            "fixture": "synthetic-branches.zip",
            "derived": "by hand: the `exp` column of tools/fixtures/make-claude-export.py SPEC (seed %d)" % SEED,
            "conversations": expected,
        }, f, indent=2)
        f.write("\n")
    print(zpath)

    # M8.T06: export.zip = the same conversations + one with 2 attachments (`extracted_content`) and a tool_use /
    # tool_result pair (AT-092; R-092 AC1/AC3).
    rng2 = random.Random(SEED + 1)
    u = lambda: str(uuid.UUID(int=rng2.getrandbits(128), version=4))
    cid, m1, m2, m3 = u(), u(), u(), u()
    t = "2026-10-29T10:%02d:00.000000Z"
    extra = {
        "uuid": cid, "name": "Attachments and a tool", "summary": "", "created_at": t % 0, "updated_at": t % 9,
        "current_leaf_message_uuid": m3,
        "chat_messages": [
            {"uuid": m1, "parent_message_uuid": ROOT_SENTINEL, "sender": "human", "created_at": t % 1, "updated_at": t % 1,
             "text": "Summarise both notes.", "content": [{"type": "text", "text": "Summarise both notes."}],
             "attachments": [
                 {"file_name": "notes-a.txt", "file_type": "txt", "file_size": 41, "extracted_content": "Note A: the kiln fires at 1240 degrees."},
                 {"file_name": "notes-b.md", "file_type": "md", "file_size": 38, "extracted_content": "# Note B\nGlaze G-17 uses 42% feldspar."}],
             "files": []},
            {"uuid": m2, "parent_message_uuid": m1, "sender": "assistant", "created_at": t % 2, "updated_at": t % 2,
             "text": "", "content": [
                 {"type": "tool_use", "name": "web_search", "input": {"query": "cone 10 temperature"}},
                 {"type": "tool_result", "name": "web_search", "content": [{"type": "text", "text": "Cone 10 is about 1300 C."}]}],
             "attachments": [], "files": []},
            {"uuid": m3, "parent_message_uuid": m2, "sender": "assistant", "created_at": t % 3, "updated_at": t % 3,
             "text": "Note A: 1240 degrees. Note B: 42% feldspar.",
             "content": [{"type": "text", "text": "Note A: 1240 degrees. Note B: 42% feldspar."}], "attachments": [], "files": []},
        ],
    }
    epath = os.path.join(args.out, "export.zip")
    with zipfile.ZipFile(epath, "w", compression=zipfile.ZIP_STORED) as z:
        for name, obj in (("conversations.json", conversations + [extra]), ("users.json", users), ("projects.json", [])):
            info = zipfile.ZipInfo(name, date_time=ZIP_TIME)
            info.external_attr = 0o644 << 16
            z.writestr(info, json.dumps(obj, indent=2, ensure_ascii=False) + "\n")
    print(epath)


if __name__ == "__main__":
    main()
