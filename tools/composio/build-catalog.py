#!/usr/bin/env python3
"""Builds the bundled Composio app catalog (the "Plugins" page data) and its logos.

Usage (from the repo root, python3 standard library only):

    python3 tools/composio/build-catalog.py                 # full refresh: metadata + logos + catalog
    python3 tools/composio/build-catalog.py --offline       # rebuild the catalog from the cache only (after editing overrides.json)
    python3 tools/composio/build-catalog.py --no-logos      # skip logo download/convert; `logo` reflects the PNGs already there
    python3 tools/composio/build-catalog.py --cache DIR     # where downloads are kept (default: $TMPDIR/antichat-composio-catalog)
    python3 tools/composio/build-catalog.py --refresh       # ignore cached metadata and logos, fetch everything again
    python3 tools/composio/build-catalog.py --report        # also print apps whose summary is generated, not hand-written
    python3 tools/composio/build-catalog.py --out DIR       # write everything under DIR instead of into the repo (to
                                                            # look at a result before it replaces anything)
    python3 tools/composio/build-catalog.py --date 2026-11-16   # the value of "generated" (default: today when the content
                                                            # changed, else the day already in the catalog)

Sources (public, no API key; a generic User-Agent; nothing about the user is sent):
  * https://docs.composio.dev/toolkits.md            the full toolkit table: name, slug, tool count, auth schemes,
                                                     whether Composio provides the OAuth app
  * https://docs.composio.dev/toolkits/<slug>.md     per toolkit: description and Composio's category (only the first
                                                     few KB of each page are read)
  * https://logos.composio.dev/api/<slug>            the logo (SVG; a generic placeholder when Composio has none)

Outputs:
  * Packages/Tools/Sources/AntiChatTools/Resources/composio-catalog.json   (--out: DIR/composio-catalog.json)
  * Packages/UI/Sources/AntiChatUI/Resources/AppLogos/<slug>.png   128x128 PNG (--out: new and changed ones in DIR/logos/)
  * tools/composio/logo-sources.json     slug -> SHA-256 of the SVG its PNG was made from: a logo is drawn again only
                                         when Composio serves another SVG (--out: DIR/logo-sources.json)
  * tools/composio/summaries-todo.json   slug -> the generated line of every app without a written summary, for a
                                         later manual pass (--out: DIR/summaries-todo.json)

The catalog is the app's bundled, curated snapshot, refreshed with this tool at release time. Between releases the
app learns which apps exist from the relay (GET /v1/toolkits, relay/src/toolkits.ts's rules are the ones below) and
merges that list with this snapshot (LiveAppCatalog.swift): an app listed here keeps its entry; a new one gets a
summary derived like `generated_summary`, a category through "category_map" (written into the catalog, as is
"exclude") and Composio's own logo. Every app with a logo also carries "logo_sha256", the SHA-256 of its PNG.

Curation lives in tools/composio/overrides.json and survives every refresh:
  * "categories"     our categories in display order ("popular" first, "other" last)
  * "category_map"   Composio category -> our category id
  * "keywords_first" [our category id, [words...]] rules tried on name + description before the map
  * "keywords"       the same, tried in order when the map has no answer (Composio files many apps under
                     "model context protocol", which says nothing about what they do)
  * "exclude"        slugs never shown (deprecated, duplicates, developer-only plumbing)
  * "include"        slugs shown although a rule would drop them (useful no-sign-in utilities)
  * "apps"           per slug: "summary" (<= 45 chars), "categories", "popular" (rank), "name"

tools/composio/summaries.json holds the written one-liners of the long tail (slug -> summary, also hand-editable; an
"apps" summary in overrides.json wins). A toolkit that is in neither file gets a line derived from Composio's
description by `generated_summary` below: run with --report after a refresh and write a proper line for each one listed.

What is left out automatically: toolkits marked deprecated, toolkits without any tool, toolkits that only work with a
developer-supplied OAuth app (a user cannot connect those through the relay), no-sign-in utility toolkits not listed
in "include", and the second listing of an app that Composio has twice (`x` and `x_mcp`: the one with browser sign-in
is kept, then the plain one). A trailing " MCP" is dropped from display names.

Logos need macOS `sips` (SVG -> PNG); the PNGs are then reduced to at most 256 colours here (no other tool needed).
Without sips the logo step is skipped and `logo` reflects the PNGs already there.
"""
import argparse
import concurrent.futures
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OVERRIDES = os.path.join(HERE, "overrides.json")
SUMMARIES = os.path.join(HERE, "summaries.json")
CATALOG = os.path.join(ROOT, "Packages/Tools/Sources/AntiChatTools/Resources/composio-catalog.json")
LOGOS = os.path.join(ROOT, "Packages/UI/Sources/AntiChatUI/Resources/AppLogos")
LOGO_SOURCES = os.path.join(HERE, "logo-sources.json")
SUMMARIES_TODO = os.path.join(HERE, "summaries-todo.json")
DOCS = "https://docs.composio.dev"
LOGO_API = "https://logos.composio.dev/api/"
UA = "catalog-builder/1.0"
SUMMARY_MAX = 45
SLUG = re.compile(r"^[a-z0-9_-]{1,64}$")
ROW = re.compile(r"^\| \[(.*)\]\(/toolkits/(.*?)\.md\) \| `(.*?)` \| (\d+) \| (\d+) \| (.*?) \| (.*?) \|")


def get(url, limit=None, timeout=30):
    """The body of `url` (only the first `limit` bytes when given)."""
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read(limit) if limit else r.read()
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError):
            if attempt == 2:
                raise
    return b""


def pool(fn, items, workers=12):
    with concurrent.futures.ThreadPoolExecutor(workers) as ex:
        return list(ex.map(fn, items))


# ---------------------------------------------------------------------------------------------- metadata

def load_index(cache, online, refresh):
    path = os.path.join(cache, "toolkits.md")
    if online and (refresh or not os.path.exists(path)):
        with open(path, "wb") as f:
            f.write(get(DOCS + "/toolkits.md", timeout=90))
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = ROW.match(line)
            if not m:
                continue
            name, page, slug, tools, triggers, auth, managed = m.groups()
            rows.append({
                "slug": slug.lower(), "page": page, "name": name.strip(), "tools": int(tools), "triggers": int(triggers),
                "auth": [a.strip() for a in auth.split(",") if a.strip()], "managed": managed.strip() == "Yes",
            })
    return rows


def load_details(cache, rows, online, refresh):
    """slug -> {description, category}, from the head of every toolkit page (cached in details.json)."""
    path = os.path.join(cache, "details.json")
    details = {}
    if os.path.exists(path) and not refresh:
        with open(path, encoding="utf-8") as f:
            details = json.load(f)
    missing = [r for r in rows if r["slug"] not in details]
    if missing and online:
        def one(r):
            try:
                head = get(f"{DOCS}/toolkits/{r['page']}.md", limit=6000).decode("utf-8", "replace")
            except Exception:
                return r["slug"], None
            body = head.split("\n# ", 1)[-1]
            lines = [l.strip() for l in body.split("\n")[1:]]
            desc = next((l for l in lines if l and not l.startswith(("-", "#", "|", ">"))), "")
            cat = re.search(r"\*\*Category:\*\*\s*(.+)", head)
            return r["slug"], {"description": desc, "category": cat.group(1).strip() if cat else ""}
        for n, (slug, d) in enumerate(pool(one, missing), 1):
            if d is not None:
                details[slug] = d
        with open(path, "w", encoding="utf-8") as f:
            json.dump(details, f, ensure_ascii=False, indent=0, sort_keys=True)
    return details


# ---------------------------------------------------------------------------------------------- curation

def auth_kind(row):
    """"oauth" (sign in in the browser), "apikey" (paste a key), "none", "other"; None = a user cannot connect it."""
    a = set(row["auth"])
    user_oauth = "DCR_OAUTH" in a or (row["managed"] and a & {"OAUTH2", "OAUTH1"})
    if user_oauth:
        return "oauth"
    if a & {"API_KEY", "BEARER_TOKEN"}:
        return "apikey"
    if a & {"BASIC", "BASIC_WITH_JWT"}:
        return "other"
    if a == {"NO_AUTH"}:
        return "none"
    # Only OAuth through an app the developer would have to register (or service-to-service / SAML credentials).
    return None


def first_sentence(text):
    text = re.sub(r"\s+", " ", text or "").strip()
    m = re.match(r"(.+?[.!?])(\s|$)", text)
    return (m.group(1) if m else text).rstrip(".!? ")


FILLER = re.compile(
    r"^(?:(?:the|a|an)\s+)?(?:(?:powerful|leading|comprehensive|popular|modern|simple|robust|flexible|all-in-one|"
    r"cloud-based|cloud based|online|web-based|ai-powered|ai powered|open-source|open source|versatile|"
    r"user-friendly|unified|complete|innovative)[\s,]+)*", re.I)
LEAD = re.compile(
    r"^(?:(?:is|are|provides?|offers?|delivers?|enables?|allows?|lets?|helps?|gives?)\s+)"
    r"(?:(?:users?|you|businesses|teams|developers|companies|organizations|customers)\s+(?:to\s+)?)?"
    r"(?:(?:the|a|an)\s+)?", re.I)


def clip(text, limit=SUMMARY_MAX):
    """`text` cut at a word boundary to at most `limit` characters, without a dangling joining word."""
    text = text.strip().rstrip(".,;:!? ")
    if len(text) <= limit:
        return text
    cut = text[:limit + 1]
    cut = cut[:cut.rfind(" ")] if " " in cut else text[:limit]
    words = cut.split(" ")
    while len(words) > 1 and words[-1].lower().strip(",;:") in DANGLING:
        words.pop()
    return " ".join(words).rstrip(".,;:!?-&/ ")


DANGLING = {"and", "or", "for", "to", "with", "of", "in", "on", "the", "a", "an", "by", "that", "which", "from", "as",
            "at", "your", "their", "its", "is", "are", "via", "into", "through", "using", "such", "like", "including",
            "other", "&", "-", "it", "you", "can", "who", "where", "when", "while", "across", "between", "within"}


def generated_summary(name, description):
    """A plain line for the long tail: the first clause of the description without the name and the filler."""
    s = first_sentence(description)
    low = s.lower()
    for prefix in (name.lower(), re.sub(r"[^a-z0-9]+", "", name.lower())):
        if prefix and low.startswith(prefix):
            s = s[len(prefix):].lstrip(" ,:-–—'s")
            break
    else:
        # "<Brand words> is a ..." where the brand is spelled differently from the listed name.
        m = re.match(r"^[^,.;:]{1,40}?\s+(?=(?:is|are|provides|offers|delivers|enables|allows|lets|helps)\s)", s)
        if m:
            s = s[m.end():]
    s = re.sub(r"^\([^)]*\)\s*", "", s)
    s = LEAD.sub("", s, count=1)
    s = FILLER.sub("", s, count=1)
    s = re.split(r"\s+(?:that|which|designed to|built to|enabling|allowing|offering|providing|featuring|helping)\s+", s)[0] \
        if len(s) > SUMMARY_MAX else s
    s = re.split(r"[;:(—–]| - ", s)[0] if len(s) > SUMMARY_MAX else s
    s = clip(s)
    if len(s) < 8:
        s = clip(first_sentence(description))
    if not s:
        return ""
    return s[0].upper() + s[1:]


def categorise(row, detail, ov):
    text = " " + re.sub(r"[^a-z0-9]+", " ", (row["name"] + " " + detail.get("description", "")).lower()) + " "
    for target, words in ov.get("keywords_first", []):
        if any(f" {w} " in text for w in words):
            return [target]
    cat = ov["category_map"].get((detail.get("category") or "").strip().lower())
    if cat and cat != "other":
        return [cat]
    for target, words in ov["keywords"]:
        if any(f" {w} " in text for w in words):
            return [target]
    return ["other"]


def twins(rows, excluded, included):
    """Slugs to drop because the same app is listed twice (`notion` and `notion_mcp`, the vendor's own MCP server):
    the one people can sign in to in the browser wins, then the plain one."""
    def usable(r):
        k = auth_kind(r)
        return r["tools"] > 0 and r["slug"] not in excluded and k is not None and (k != "none" or r["slug"] in included)
    by = {r["slug"]: r for r in rows if usable(r)}
    out = set()
    for slug, mcp in by.items():
        base = by.get(slug[:-4]) if slug.endswith("_mcp") else None
        if base:
            out.add(base["slug"] if auth_kind(mcp) == "oauth" and auth_kind(base) != "oauth" else slug)
    return out


def build(rows, details, ov, have_logo):
    known = {c["id"] for c in ov["categories"]}
    excluded, included = set(ov.get("exclude", [])), set(ov.get("include", []))
    doubles = twins(rows, excluded, included)
    written = {}
    if os.path.exists(SUMMARIES):
        with open(SUMMARIES, encoding="utf-8") as f:
            written = json.load(f)
    apps, dropped, generated = [], {}, []
    for r in rows:
        slug = r["slug"]
        d = details.get(slug, {})
        o = ov["apps"].get(slug, {})
        kind = auth_kind(r)
        text = (r["name"] + " " + d.get("description", "")).lower()
        why = None
        if not SLUG.match(slug):
            why = "slug"
        elif slug in excluded:
            why = "excluded"
        elif "deprecated" in text:
            why = "deprecated"
        elif r["tools"] == 0:
            why = "no tools"
        elif kind is None:
            why = "needs a developer OAuth app"
        elif kind == "none" and slug not in included:
            why = "no-sign-in utility"
        elif slug in doubles:
            why = "listed twice"
        if why:
            dropped.setdefault(why, []).append(slug)
            continue
        name = o.get("name") or re.sub(r"\s+MCP$", "", r["name"]).strip() or r["name"]
        summary = o.get("summary") or written.get(slug)
        if not summary:
            summary = generated_summary(name, d.get("description", "")) or name
            generated.append(slug)
        if len(summary) > SUMMARY_MAX:
            raise SystemExit(f"summary of {slug} is {len(summary)} characters (max {SUMMARY_MAX}): {summary}")
        cats = [c for c in (o.get("categories") or categorise(r, d, ov)) if c != "popular"]
        bad = [c for c in cats if c not in known]
        if bad or not cats:
            raise SystemExit(f"{slug}: unknown or missing categories {bad}")
        popular = o.get("popular")
        if popular is not None:
            cats = ["popular"] + cats
        apps.append({"slug": slug, "name": name, "summary": summary, "categories": cats, "auth": kind,
                     "popular": popular, "logo": slug in have_logo})
    for slug in ov["apps"]:
        if slug not in {a["slug"] for a in apps}:
            print(f"note: overrides.json has '{slug}' but the catalog does not (gone or excluded)", file=sys.stderr)
    apps.sort(key=lambda a: (a["name"].lower(), a["slug"]))
    return apps, dropped, generated


# ---------------------------------------------------------------------------------------------- logos

def logo_file(slug, out_logos=None):
    """The PNG of `slug`: the one a --out run just wrote, else the one in the repo; None when there is none."""
    for d in ([out_logos] if out_logos else []) + [LOGOS]:
        p = os.path.join(d, slug + ".png")
        if os.path.exists(p):
            return p
    return None


def fetch_logos(cache, slugs, online, refresh, out_logos=None, sources=None):
    """Downloads the SVG of every slug into the cache and writes 128x128 PNGs for the new and the changed ones
    (into `out_logos` when given, else into the repo). `sources` (slug -> SVG SHA-256) is updated in place.
    Returns the slugs with a logo. A logo that is there is never lost to a failed download or a placeholder."""
    raw = os.path.join(cache, "logos-svg")
    target = out_logos or LOGOS
    sources = sources if sources is not None else {}
    os.makedirs(raw, exist_ok=True)
    os.makedirs(target, exist_ok=True)
    sips = shutil.which("sips")
    if not sips:
        print("sips not found: logo step skipped", file=sys.stderr)
        return existing_logos()

    def one(slug):
        svg = os.path.join(raw, slug + ".svg")
        have = logo_file(slug, out_logos)
        if online and (refresh or not os.path.exists(svg)):
            try:
                data = get(LOGO_API + slug, timeout=30)
            except Exception:
                return (slug, None) if have else None
            with open(svg, "wb") as f:
                f.write(data)
        if not os.path.exists(svg):
            return (slug, None) if have else None
        with open(svg, "rb") as f:
            data = f.read()
        # Composio answers a generic grid placeholder for toolkits without a logo: the UI shows an initial instead.
        if b"<svg" not in data[:2000] or b"composio-fallback" in data:
            return (slug, None) if have else None
        digest = hashlib.sha256(data).hexdigest()
        # Unchanged upstream (or a PNG from before the SVG hashes were recorded): keep the PNG as it is.
        if have and sources.get(slug, digest) == digest:
            return slug, digest
        png = os.path.join(target, slug + ".png")
        tmp = png + ".tmp.png"
        try:
            subprocess.run([sips, "-s", "format", "png", "-z", "128", "128", svg, "--out", tmp],
                           check=True, capture_output=True, timeout=60)
            try:
                shrink_png(tmp)
            except Exception:
                pass  # the PNG as sips wrote it is kept
            if not png_ok(tmp):
                raise ValueError("not a 128x128 png")
            os.replace(tmp, png)
            return slug, digest
        except Exception:
            if os.path.exists(tmp):
                os.remove(tmp)
            return (slug, None) if have else None

    done = set()
    for r in pool(one, slugs, workers=8):
        if r:
            done.add(r[0])
            if r[1]:
                sources[r[0]] = r[1]
    return done


# A small palette quantiser so the logos stay tiny without any tool beyond the standard library: the 128x128 RGBA
# PNG that sips writes becomes an indexed PNG of at most 256 colours (median cut, alpha included).

def _chunks(data):
    pos = 8
    while pos < len(data):
        n = int.from_bytes(data[pos:pos + 4], "big")
        yield data[pos + 4:pos + 8], data[pos + 8:pos + 8 + n]
        pos += 12 + n


def read_rgba(path):
    """(width, height, [(r, g, b, a), ...]) of an 8-bit RGB/RGBA non-interlaced PNG, else None."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    w = h = 0
    bpp = 4
    idat = []
    for kind, body in _chunks(data):
        if kind == b"IHDR":
            w, h = int.from_bytes(body[0:4], "big"), int.from_bytes(body[4:8], "big")
            depth, ctype, interlace = body[8], body[9], body[12]
            if depth != 8 or ctype not in (2, 6) or interlace:
                return None
            bpp = 4 if ctype == 6 else 3
        elif kind == b"IDAT":
            idat.append(body)
    raw = zlib.decompress(b"".join(idat))
    stride = w * bpp
    prev = bytearray(stride)
    px = []
    pos = 0
    for _ in range(h):
        ft = raw[pos]
        row = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        if ft == 1:
            for i in range(bpp, stride):
                row[i] = (row[i] + row[i - bpp]) & 255
        elif ft == 2:
            for i in range(stride):
                row[i] = (row[i] + prev[i]) & 255
        elif ft == 3:
            for i in range(stride):
                row[i] = (row[i] + (((row[i - bpp] if i >= bpp else 0) + prev[i]) >> 1)) & 255
        elif ft == 4:
            for i in range(stride):
                a = row[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                row[i] = (row[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        if bpp == 4:
            px.extend((row[i], row[i + 1], row[i + 2], row[i + 3]) if row[i + 3] else (0, 0, 0, 0)
                      for i in range(0, stride, 4))
        else:
            px.extend((row[i], row[i + 1], row[i + 2], 255) for i in range(0, stride, 3))
        prev = row
    return w, h, px


def quantise(px, limit=256):
    """(palette [(r, g, b, a)], index per pixel): median cut on alpha-weighted colour."""
    counts = {}
    for c in px:
        counts[c] = counts.get(c, 0) + 1

    def key(c):  # premultiplied, so nearly transparent pixels do not eat palette entries
        a = c[3]
        return (c[0] * a // 255, c[1] * a // 255, c[2] * a // 255, a)

    def box(items):
        lo = [255] * 4
        hi = [0] * 4
        for k, _, _ in items:
            for i in range(4):
                if k[i] < lo[i]:
                    lo[i] = k[i]
                if k[i] > hi[i]:
                    hi[i] = k[i]
        spans = [hi[i] - lo[i] for i in range(4)]
        axis = spans.index(max(spans))
        return [max(spans), axis, items]

    boxes = [box([(key(c), c, n) for c, n in counts.items()])]
    while len(boxes) < limit:
        best = max(boxes, key=lambda b: b[0] if len(b[2]) > 1 else -1)
        if best[0] <= 0 or len(best[2]) < 2:
            break
        axis = best[1]
        items = sorted(best[2], key=lambda it: it[0][axis])
        half = sum(n for _, _, n in items) / 2
        run = 0
        cut = 1
        for i, (_, _, n) in enumerate(items):
            run += n
            if run >= half:
                cut = min(max(i + 1, 1), len(items) - 1)
                break
        boxes.remove(best)
        boxes.append(box(items[:cut]))
        boxes.append(box(items[cut:]))

    palette, where = [], {}
    for b in boxes:
        total = sum(n for _, _, n in b[2])
        a = sum(c[3] * n for _, c, n in b[2]) / total
        if a < 1:
            col = (0, 0, 0, 0)
        else:
            wsum = sum(c[3] * n for _, c, n in b[2])
            col = tuple(min(255, round(sum(c[i] * c[3] * n for _, c, n in b[2]) / wsum)) for i in range(3)) + (round(a),)
        for _, c, _ in b[2]:
            where[c] = len(palette)
        palette.append(col)
    # Transparent entries first: the tRNS chunk can then stop at the last non-opaque colour.
    order = sorted(range(len(palette)), key=lambda i: palette[i][3])
    rank = {old: new for new, old in enumerate(order)}
    return [palette[i] for i in order], [rank[where[c]] for c in px]


def shrink_png(path):
    """Rewrites `path` as an indexed PNG when that is smaller."""
    img = read_rgba(path)
    if not img:
        return
    w, h, px = img
    palette, idx = quantise(px)

    def chunk(kind, body):
        return len(body).to_bytes(4, "big") + kind + body + zlib.crc32(kind + body).to_bytes(4, "big")

    rows = b"".join(b"\x00" + bytes(idx[y * w:(y + 1) * w]) for y in range(h))
    alphas = bytes(c[3] for c in palette)
    out = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", w.to_bytes(4, "big") + h.to_bytes(4, "big") + bytes([8, 3, 0, 0, 0]))
    out += chunk(b"PLTE", b"".join(bytes(c[:3]) for c in palette))
    if alphas.rstrip(b"\xff"):
        out += chunk(b"tRNS", alphas.rstrip(b"\xff"))
    out += chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")
    if len(out) < os.path.getsize(path):
        with open(path, "wb") as f:
            f.write(out)


def png_ok(path):
    with open(path, "rb") as f:
        head = f.read(24)
    return head[:8] == b"\x89PNG\r\n\x1a\n" and head[16:24] == (128).to_bytes(4, "big") * 2


def existing_logos():
    if not os.path.isdir(LOGOS):
        return set()
    return {f[:-4] for f in os.listdir(LOGOS) if f.endswith(".png")}


# ---------------------------------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description="Build composio-catalog.json and the app logos.")
    ap.add_argument("--cache", default=os.path.join(tempfile.gettempdir(), "antichat-composio-catalog"))
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--no-logos", action="store_true")
    ap.add_argument("--refresh", action="store_true")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--out", metavar="DIR", help="write the catalog, new logos and side files here, not into the repo")
    ap.add_argument("--date", help="value for 'generated' (default: today, or the committed day when nothing changed)")
    args = ap.parse_args()
    online = not args.offline
    os.makedirs(args.cache, exist_ok=True)
    out_logos = os.path.join(args.out, "logos") if args.out else None
    out = (lambda name, default: os.path.join(args.out, name) if args.out else default)
    if args.out:
        os.makedirs(args.out, exist_ok=True)

    with open(OVERRIDES, encoding="utf-8") as f:
        ov = json.load(f)
    rows = load_index(args.cache, online, args.refresh)
    details = load_details(args.cache, rows, online, args.refresh)
    apps, dropped, generated = build(rows, details, ov, set())
    slugs = [a["slug"] for a in apps]
    sources = {}
    if os.path.exists(LOGO_SOURCES):
        with open(LOGO_SOURCES, encoding="utf-8") as f:
            sources = json.load(f)
    have = existing_logos() if args.no_logos else fetch_logos(args.cache, slugs, online, args.refresh, out_logos, sources)
    for a in apps:
        png = logo_file(a["slug"], out_logos) if a["slug"] in have else None
        a["logo"] = png is not None
        if png:
            with open(png, "rb") as f:
                a["logo_sha256"] = hashlib.sha256(f.read()).hexdigest()
    if not args.no_logos:
        # Logos of apps that left the catalog are removed so the bundle does not carry dead files (a --out run
        # leaves the repo alone).
        if not args.out:
            for stale in existing_logos() - set(slugs):
                os.remove(os.path.join(LOGOS, stale + ".png"))
        with open(out("logo-sources.json", LOGO_SOURCES), "w", encoding="utf-8") as f:
            json.dump({k: sources[k] for k in sorted(sources) if k in set(slugs)}, f, indent=0)
            f.write("\n")
    with open(out("summaries-todo.json", SUMMARIES_TODO), "w", encoding="utf-8") as f:
        json.dump({a["slug"]: a["summary"] for a in apps if a["slug"] in set(generated)}, f, ensure_ascii=False,
                  indent=0, sort_keys=True)
        f.write("\n")

    day = args.date or datetime.date.today().isoformat()
    try:
        with open(CATALOG, encoding="utf-8") as f:
            old = json.load(f)
        if (old.get("categories") == ov["categories"] and old.get("apps") == apps and not args.date
                and old.get("category_map") == ov["category_map"] and old.get("exclude") == sorted(ov.get("exclude", []))):
            day = old["generated"]
    except (OSError, ValueError):
        pass
    catalog = {"generated": day, "categories": ov["categories"], "apps": apps}
    target = out("composio-catalog.json", CATALOG)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    compact = lambda v: json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    with open(target, "w", encoding="utf-8") as f:
        # "category_map" and "exclude" are for the apps the app learns about between releases (the relay's live
        # list, LiveAppCatalog.swift): it files a new app under our category and never shows an excluded one.
        f.write('{"generated":%s,"categories":%s,\n"category_map":%s,\n"exclude":%s,\n"apps":[\n' % (
            json.dumps(catalog["generated"]), compact(catalog["categories"]), compact(ov["category_map"]),
            compact(sorted(ov.get("exclude", [])))))
        f.write(",\n".join(json.dumps(a, ensure_ascii=False, separators=(",", ":")) for a in apps))
        f.write("\n]}\n")

    counts = {c["id"]: sum(c["id"] in a["categories"] for a in apps) for c in ov["categories"]}
    print(f"toolkits listed by Composio: {len(rows)}; in the catalog: {len(apps)}; with a logo: {sum(a['logo'] for a in apps)}")
    print("left out: " + ", ".join(f"{k} {len(v)}" for k, v in dropped.items()))
    print("per category: " + ", ".join(f"{k} {v}" for k, v in counts.items()))
    print(f"hand-written summaries: {len(apps) - len(generated)}; generated: {len(generated)}")
    if args.report:
        for a in apps:
            if a["slug"] in generated:
                print(f"  {a['slug']:<34} {a['categories'][-1]:<14} {a['summary']}")


if __name__ == "__main__":
    main()
