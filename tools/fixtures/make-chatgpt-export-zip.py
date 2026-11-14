#!/usr/bin/env python3
"""M8.T06 (AT-092, R-092 AC1/AC3): a ChatGPT data-export zip from the M0.T11 conversation fixtures.

  fixtures/chats/chatgpt-export/export.zip
    conversations.json   the conversations of chatgpt-export.json, chatgpt-tree.json and chatgpt-citations.json
                         (LibreChat@8d3da9b test data, MIT; the citations sample's id, shared with the first export
                         conversation, gets a `-citations` suffix) + one synthetic conversation with: 2 user images
                         (`file-…` asset pointers: PNG + WebP), 1 DALL·E result (`dalle-generations/`), a code tool
                         call + its execution output, and a canvas (`canmore.create_textdoc`) part
    file-<id>-<name>.png|webp, dalle-generations/file-<id>-<name>.webp   synthetic images (seed 20261030)
    user.json, message_feedback.json   synthetic, ignored by the importer
Deterministic: stored entries, fixed mtime, seeded pixels. `export.zip` is also used by M10 AT-FA-09.

Usage: tools/.venv/bin/python3 -I tools/fixtures/make-chatgpt-export-zip.py [--out fixtures/chats/chatgpt-export]
"""
from __future__ import annotations

import argparse
import io
import json
import os
import random
import zipfile

SEED = 20261030
ZIP_TIME = (2026, 10, 30, 0, 0, 0)


def image(rng: random.Random, fmt: str, size=(64, 48)) -> bytes:
    from PIL import Image
    img = Image.new("RGB", size)
    img.putdata([(rng.randrange(256), rng.randrange(256), rng.randrange(256)) for _ in range(size[0] * size[1])])
    buf = io.BytesIO()
    img.save(buf, format=fmt, **({"lossless": True} if fmt == "WEBP" else {}))
    return buf.getvalue()


def node(mid, parent, children, role, content, t, recipient="all", meta=None):
    return {"id": mid, "parent": parent, "children": children, "message": None if role is None else {
        "id": mid, "author": {"role": role, "name": None, "metadata": {}}, "create_time": t, "update_time": None,
        "content": content, "status": "finished_successfully", "end_turn": True, "weight": 1.0,
        "metadata": meta or {}, "recipient": recipient}}


def synthetic() -> dict:
    t0 = 1761800000.0
    ids = ["sy-root", "sy-u1", "sy-a1", "sy-a2", "sy-t2", "sy-a3", "sy-u4", "sy-a4", "sy-a5", "sy-a6"]
    up = lambda k: {"content_type": "image_asset_pointer", "asset_pointer": f"file-service://{k}", "size_bytes": 1,
                    "width": 64, "height": 48}
    m = {}
    chain = [
        ("sy-root", None, None, None),
        ("sy-u1", "user", {"content_type": "multimodal_text", "parts": [up("file-Aa11Bb22"), up("file-Cc33Dd44"),
                                                                       "What is different between these two pictures?"]}, "all"),
        ("sy-a1", "assistant", {"content_type": "text", "parts": ["The first is warmer; the second has more blue."]}, "all"),
        ("sy-u4", "user", {"content_type": "text", "parts": ["Count the pixels with Python, then draw me a kiln."]}, "all"),
        ("sy-a2", "assistant", {"content_type": "code", "language": "python", "text": "print(64 * 48)"}, "python"),
        ("sy-t2", "tool", {"content_type": "execution_output", "text": "3072"}, "all"),
        ("sy-a3", "assistant", {"content_type": "text", "parts": ["Each picture has 3,072 pixels."]}, "all"),
        ("sy-a4", "tool", {"content_type": "multimodal_text", "parts": [up("file-Ee55Ff66")]}, "all"),
        ("sy-a5", "assistant", {"content_type": "code", "language": "json",
                                "text": json.dumps({"name": "kiln_notes", "type": "document",
                                                    "content": "# Kiln notes\nFire to cone 10."})}, "canmore.create_textdoc"),
        ("sy-a6", "assistant", {"content_type": "text", "parts": ["Here is the kiln, and a canvas with notes."]}, "all"),
    ]
    order = [c[0] for c in chain]
    for i, (mid, role, content, recipient) in enumerate(chain):
        parent = order[i - 1] if i else None
        children = [order[i + 1]] if i + 1 < len(order) else []
        meta = {"model_slug": "gpt-4o"} if role == "assistant" else ({"is_visually_hidden_from_conversation": True} if role is None else {})
        m[mid] = node(mid, parent, children, role, content, t0 + i, recipient or "all", meta)
    return {"title": "Pictures, code and a canvas", "create_time": t0, "update_time": t0 + 20, "mapping": m,
            "current_node": "sy-a6", "conversation_id": "sy-0000-synthetic", "id": "sy-0000-synthetic",
            "default_model_slug": "gpt-4o", "is_archived": False}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="fixtures/chats/chatgpt-export")
    a = ap.parse_args()
    rng = random.Random(SEED)
    convs = []
    seen = set()
    for f in ("chatgpt-export.json", "chatgpt-tree.json", "chatgpt-citations.json"):
        for c in json.load(open(os.path.join(a.out, f), encoding="utf-8")):
            # the LibreChat citations sample reuses the first export conversation's id: one export never does
            if c.get("conversation_id") in seen:
                c["conversation_id"] = c["id"] = c["conversation_id"] + "-citations"
            seen.add(c.get("conversation_id"))
            convs.append(c)
    convs.append(synthetic())
    files = [
        ("file-Aa11Bb22-sunset.png", image(rng, "PNG")),
        ("file-Cc33Dd44-lake.webp", image(rng, "WEBP")),
        ("dalle-generations/file-Ee55Ff66-kiln.webp", image(rng, "WEBP")),
    ]
    path = os.path.join(a.out, "export.zip")
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as z:
        def put(name, data):
            info = zipfile.ZipInfo(name, date_time=ZIP_TIME)
            info.external_attr = 0o644 << 16
            z.writestr(info, data)
        put("conversations.json", json.dumps(convs, indent=1, ensure_ascii=False) + "\n")
        put("user.json", json.dumps({"id": "user-synthetic", "email": "fixture@example.invalid"}) + "\n")
        put("message_feedback.json", "[]\n")
        for name, data in files:
            put(name, data)
    print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
