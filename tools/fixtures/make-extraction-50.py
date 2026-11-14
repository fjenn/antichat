#!/usr/bin/env python3
"""M7.T02 (AT-249 c2): `fixtures/web/extraction-960/articles-50/` = 50 `<id>.html` + `<id>.gold.txt` pairs.

Source: scrapinghub/article-extraction-benchmark@4a3bc979f7 (MIT): `html/<id>.html.gz` and `ground-truth.json`
(`articleBody`). The first 50 ids in sorted order are taken (deterministic). Network once (Q-007), via the GitHub
raw host. Run with `python3 -I tools/fixtures/make-extraction-50.py [--fixtures DIR]`.
"""
from __future__ import annotations

import argparse
import gzip
import json
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REPO = "scrapinghub/article-extraction-benchmark"
SHA = "4a3bc979f76c0df73cb95fe272e2fc1b96f9f010"
RAW = f"https://raw.githubusercontent.com/{REPO}/{SHA}"


def get(path: str) -> bytes:
    with urllib.request.urlopen(urllib.request.Request(f"{RAW}/{path}", headers={"User-Agent": "antichat-fixtures"}),
                                timeout=60) as r:
        return r.read()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixtures", default=str(ROOT / "fixtures"))
    ap.add_argument("--count", type=int, default=50)
    a = ap.parse_args()
    out = Path(a.fixtures) / "web" / "extraction-960" / "articles-50"
    out.mkdir(parents=True, exist_ok=True)
    truth = json.loads(get("ground-truth.json"))
    ids = sorted(truth)[: a.count]
    for i in ids:
        html = gzip.decompress(get(f"html/{i}.html.gz"))
        (out / f"{i}.html").write_bytes(html)
        (out / f"{i}.gold.txt").write_text(truth[i]["articleBody"].strip() + "\n", encoding="utf-8")
    (out / "MANIFEST.json").write_text(json.dumps({"source": f"{REPO}@{SHA}", "licence": "MIT", "ids": ids,
                                                    "gold_field": "articleBody"}, indent=1) + "\n")
    print(f"wrote {len(ids)} pairs to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
