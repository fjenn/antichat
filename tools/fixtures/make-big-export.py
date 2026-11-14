#!/usr/bin/env python3
"""M8.T06 AT-092 AC2: a ~1 GB ChatGPT export zip for ImportPerfTests (written to build/fixtures, never committed).

  make-big-export.py --bytes 1073741824 --seed 7 --images 2000 [--out build/fixtures/chatgpt-1gb.zip]

Conversations of 20–80 messages (linear with an edit branch every 7th conversation), ~1 KB of seeded text per
message, `--images` user pictures (small seeded PNGs) referenced by `file-…` asset pointers. conversations.json is
streamed into the zip (zip64), so the generator never holds the export in memory. Deterministic per seed.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import random
import zipfile

WORDS = ("kiln glaze clay wheel studio firing cone feldspar slip bisque pottery member schedule batch shelf "
         "drying class workshop temperature recipe silica oxide reduction kickwheel trimming").split()


def png(rng: random.Random) -> bytes:
    from PIL import Image
    img = Image.new("RGB", (48, 32))
    img.putdata([(rng.randrange(256), rng.randrange(256), rng.randrange(256)) for _ in range(48 * 32)])
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def text(rng: random.Random, n: int) -> str:
    return " ".join(rng.choice(WORDS) for _ in range(n)).capitalize() + "."


def conversation(rng: random.Random, i: int, image_ids: list[str]) -> dict:
    t0 = 1700000000.0 + i * 600
    n = rng.randint(20, 80)
    mapping = {"root": {"id": "root", "parent": None, "children": [], "message": None}}
    prev = "root"
    for k in range(n):
        mid = f"c{i}-m{k}"
        role = "user" if k % 2 == 0 else "assistant"
        parts: list = [text(rng, rng.randint(120, 200))]
        if role == "user" and image_ids and k == 0:
            parts.insert(0, {"content_type": "image_asset_pointer", "asset_pointer": f"file-service://{image_ids.pop()}"})
        mapping[mid] = {"id": mid, "parent": prev, "children": [], "message": {
            "id": mid, "author": {"role": role}, "create_time": t0 + k,
            "content": {"content_type": "multimodal_text" if len(parts) > 1 else "text", "parts": parts},
            "metadata": {"model_slug": "gpt-4o"} if role == "assistant" else {}, "recipient": "all"}}
        mapping[prev]["children"].append(mid)
        prev = mid
    leaf = prev
    if i % 7 == 0 and n > 4:  # an edit branch off the third message
        bid = f"c{i}-b"
        mapping[bid] = {"id": bid, "parent": f"c{i}-m1", "children": [], "message": {
            "id": bid, "author": {"role": "user"}, "create_time": t0 + n + 1,
            "content": {"content_type": "text", "parts": [text(rng, 40)]}, "metadata": {}, "recipient": "all"}}
        mapping[f"c{i}-m1"]["children"].append(bid)
    return {"title": f"Big export {i}", "create_time": t0, "update_time": t0 + n, "mapping": mapping,
            "current_node": leaf, "conversation_id": f"big-{i}", "id": f"big-{i}"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bytes", type=int, default=1 << 30)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--images", type=int, default=2000)
    ap.add_argument("--out", default="build/fixtures/chatgpt-1gb.zip")
    a = ap.parse_args()
    rng = random.Random(a.seed)
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    image_ids = [f"file-big{n:05d}" for n in range(a.images)]
    pending = list(reversed(image_ids))
    written = 0
    convs = 0
    with zipfile.ZipFile(a.out, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as z:
        for n, iid in enumerate(image_ids):
            z.writestr(zipfile.ZipInfo(f"{iid}-pic.png", date_time=(2026, 1, 1, 0, 0, 0)), png(rng))
        with z.open(zipfile.ZipInfo("conversations.json", date_time=(2026, 1, 1, 0, 0, 0)), "w", force_zip64=True) as f:
            f.write(b"[")
            while written < a.bytes:
                body = json.dumps(conversation(rng, convs, pending), ensure_ascii=False).encode()
                f.write((b"," if convs else b"") + body)
                written += len(body) + 1
                convs += 1
            f.write(b"]")
    print(f"{a.out}: {convs} conversations, {written / 1e9:.2f} GB json, {a.images} images")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
