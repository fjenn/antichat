#!/usr/bin/env python3
"""Fetch CC0 photographs from Wikimedia Commons into fixtures/images/photos-cc0 (M0.T01 step 6).

- Candidates come from CirrusSearch restricted to `incategory:CC-zero filetype:bitmap
  filemime:image/jpeg` plus a topic word (fixed topic list, fixed order).
- The licence is re-checked per file: `extmetadata.LicenseShortName == "CC0"`.
- Each image is centre-cropped to a square and resized to 1024x1024 JPEG with `sips`.
- Faces are counted with Apple Vision (tools/fixtures/count-faces.swift) so that at least
  `--min-group` of the photos show >= 3 faces.
- Content review (no sexual content, no minors as subjects) is done by a reviewer looking at
  every output file before commit; files rejected there are listed with --exclude.
- Writes SOURCES.md (URL, author, licence per file) and candidates.json (provenance).

Usage: python3 -I tools/fixtures/fetch-cc0-photos.py --out fixtures/images/photos-cc0 [--exclude TITLE ...]
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://commons.wikimedia.org/w/api.php"
UA = "AntiChat-fixtures/0.1 (build tooling; contact via project repository)"
GROUP_TOPICS = ["group of people", "team photo adults", "conference attendees", "people meeting", "crowd street",
                "business meeting", "panel discussion", "workshop participants", "volunteers", "orchestra musicians",
                "group photo staff", "delegation"]
# Search-side filters: photographs only (no artworks), and no minors as subjects in group photos.
NOT_ART = "-painting -drawing -engraving -etching -lithograph -print -museum -MET -illustration -sculpture"
NOT_MINORS = "-child -children -kids -school -students -pupils -youth -adolescents -teen -family -girls -boys -baby"
PER_TOPIC = 2
OTHER_TOPICS = ["landscape", "city street", "food dish", "dog", "cat", "bird", "flower", "building",
                "mountain", "beach", "car", "bicycle", "market", "kitchen", "office desk", "bridge",
                "forest", "river", "train", "boat", "lake", "sunset", "tree", "horse", "coffee", "fruit",
                "street market vegetables", "lighthouse", "church", "skyline", "waterfall", "butterfly", "snow", "garden"]
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def fetch(url: str, timeout: int = 60) -> bytes:
    """GET with a polite pace (>= 1 s between calls) and backoff on 429/5xx."""
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    for attempt in range(8):
        time.sleep(1.0)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504) or attempt == 7:
                raise
            wait = int(e.headers.get("Retry-After") or 0) or 5 * (attempt + 1)
            print(f"http {e.code}, waiting {wait}s", file=sys.stderr)
            time.sleep(min(wait, 120))
        except (urllib.error.URLError, TimeoutError):
            if attempt == 7:
                raise
            time.sleep(5)
    raise RuntimeError("unreachable")


def get(params: dict) -> dict:
    params = {**params, "format": "json"}
    return json.loads(fetch(API + "?" + urllib.parse.urlencode(params)))


def search(topic: str, limit: int, extra: str = "") -> list[str]:
    q = f"incategory:CC-zero filetype:bitmap filemime:image/jpeg {topic} {NOT_ART} {extra}".strip()
    d = get({"action": "query", "list": "search", "srnamespace": 6, "srlimit": limit, "srsearch": q})
    return [s["title"] for s in d.get("query", {}).get("search", [])]


def info(titles: list[str]) -> dict[str, dict]:
    out = {}
    for i in range(0, len(titles), 40):
        chunk = titles[i:i + 40]
        d = get({"action": "query", "prop": "imageinfo", "titles": "|".join(chunk),
                 "iiprop": "url|size|mime|extmetadata|sha1", "iiurlwidth": 1280})
        for p in d.get("query", {}).get("pages", {}).values():
            ii = (p.get("imageinfo") or [None])[0]
            if ii:
                out[p["title"]] = ii
    return out


def strip_html(s: str) -> str:
    return html.unescape(re.sub(r"<[^>]+>", "", s or "")).strip()


def download(url: str, path: str) -> None:
    data = fetch(url, timeout=120)
    with open(path, "wb") as f:
        f.write(data)


def square_1024(src: str, dst: str) -> None:
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", src], capture_output=True, text=True, check=True).stdout
    w = int(re.search(r"pixelWidth: (\d+)", out).group(1))
    h = int(re.search(r"pixelHeight: (\d+)", out).group(1))
    side = min(w, h)
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "85", "-c", str(side), str(side), src, "--out", dst],
                   capture_output=True, check=True)
    subprocess.run(["sips", "-z", "1024", "1024", dst], capture_output=True, check=True)


def count_faces(paths: list[str]) -> dict[str, int]:
    script = os.path.join(ROOT, "tools/fixtures/count-faces.swift")
    out = subprocess.run(["swift", script, *paths], capture_output=True, text=True, check=True).stdout
    res = {}
    for line in out.splitlines():
        n, p = line.split("\t", 1)
        res[p] = int(n)
    return res


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--count", type=int, default=40)
    ap.add_argument("--min-group", type=int, default=5)
    ap.add_argument("--exclude", action="append", default=[])
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="cc0-")

    def candidates(topics: list[str], per: int, extra: str = "", cap: int | None = None) -> list[str]:
        """Round-robin over topics, at most `cap` titles per topic (variety, no near-duplicates)."""
        seen, lists = set(), []
        for t in topics:
            lst = [x for x in search(t, per, extra) if x not in a.exclude]
            lists.append(lst[:cap] if cap else lst)
        res = []
        for i in range(max(len(l) for l in lists)):
            for lst in lists:
                if i < len(lst) and lst[i] not in seen:
                    seen.add(lst[i])
                    res.append(lst[i])
        return res

    def usable(titles: list[str]) -> list[tuple[str, dict]]:
        meta = info(titles)
        res = []
        for t in titles:
            ii = meta.get(t)
            if not ii or ii.get("mime") != "image/jpeg":
                continue
            lic = (ii.get("extmetadata", {}).get("LicenseShortName", {}) or {}).get("value", "")
            if strip_html(lic) != "CC0":
                continue
            if min(ii.get("width", 0), ii.get("height", 0)) < 1024:
                continue
            res.append((t, ii))
        return res

    picked: list[dict] = []
    used: set[str] = set()

    def take(pool: list[tuple[str, dict]], want: int, need_group: bool) -> None:
        batch = []
        for t, ii in pool:
            if len([p for p in picked if p["group"] == need_group]) >= want:
                break
            if t in used:
                continue
            raw = os.path.join(tmp, f"raw-{len(used)}.jpg")
            sq = os.path.join(tmp, f"sq-{len(used)}.jpg")
            try:
                download(ii.get("thumburl") or ii["url"], raw)
                square_1024(raw, sq)
            except Exception as e:  # skip broken files
                print(f"skip {t}: {e}", file=sys.stderr)
                continue
            used.add(t)
            batch.append((t, ii, sq))
            if len(batch) % 8 == 0:
                flush(batch, need_group)
                batch.clear()
        flush(batch, need_group)

    def flush(batch, need_group):
        if not batch:
            return
        faces = count_faces([b[2] for b in batch])
        for t, ii, sq in batch:
            n = faces.get(sq, 0)
            is_group = n >= 3
            if need_group and not is_group:
                continue
            em = ii.get("extmetadata", {})
            picked.append({"title": t, "sq": sq, "faces": n, "group": need_group,
                           "page": ii.get("descriptionurl"), "url": ii.get("url"), "sha1": ii.get("sha1"),
                           "author": strip_html((em.get("Artist") or {}).get("value", "")) or "unknown",
                           "licence": strip_html((em.get("LicenseShortName") or {}).get("value", "")),
                           "licence_url": strip_html((em.get("LicenseUrl") or {}).get("value", ""))})

    take(usable(candidates(GROUP_TOPICS, 30, NOT_MINORS)), a.min_group, True)
    take(usable(candidates(OTHER_TOPICS, 8, cap=PER_TOPIC)), a.count - a.min_group, False)

    groups = [p for p in picked if p["group"]]
    if len(groups) < a.min_group or len(picked) < a.count:
        print(f"not enough: {len(picked)} picked, {len(groups)} group photos", file=sys.stderr)
        return 1
    picked = groups[:a.min_group] + [p for p in picked if not p["group"]][: a.count - a.min_group]
    for f in os.listdir(a.out):
        if re.fullmatch(r"\d{3}\.jpg", f):
            os.remove(os.path.join(a.out, f))
    lines = ["# photos-cc0 — sources", "",
             "40 CC0 photographs from Wikimedia Commons, fetched by `tools/fixtures/fetch-cc0-photos.py` "
             f"on {time.strftime('%Y-%m-%d')}. Licence re-checked per file (`extmetadata.LicenseShortName == \"CC0\"`). "
             "Each file is centre-cropped to a square and resized to 1024x1024 JPEG (sips). "
             "`faces` = Apple Vision face count (tools/fixtures/count-faces.swift). "
             "Every file was reviewed by eye before commit: no sexual content, no minors as subjects.", "",
             "| File | Faces | Commons page | Author | Licence |", "|---|---|---|---|---|"]
    manifest = []
    for i, p in enumerate(picked, 1):
        name = f"{i:03d}.jpg"
        os.replace(p["sq"], os.path.join(a.out, name))
        author = p["author"].replace("|", "/").replace("\n", " ")[:120]
        lines.append(f"| {name} | {p['faces']} | {p['page']} | {author} | {p['licence']} |")
        manifest.append({k: p[k] for k in ("title", "faces", "page", "url", "sha1", "author", "licence", "licence_url")} | {"file": name})
    open(os.path.join(a.out, "SOURCES.md"), "w").write("\n".join(lines) + "\n")
    json.dump(manifest, open(os.path.join(a.out, "candidates.json"), "w"), indent=2)
    print(f"wrote {len(picked)} photos ({len(groups[:a.min_group])} with >= 3 faces) to {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
