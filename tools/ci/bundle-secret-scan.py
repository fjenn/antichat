#!/usr/bin/env python3
"""Static secret scan of a built app bundle (M7.T10, AT-255 c1; R-255: no Composio credential ships in the app).

  python3 -I tools/ci/bundle-secret-scan.py build/AntiChat.app --patterns tools/ci/secret-patterns.yml [--json OUT]

Every file under the bundle is read as bytes. Named patterns (Composio `ak_*`, `ck_*`, `uak_*`, the literal
`COMPOSIO_API_KEY`) run on all files. The entropy check reports printable strings made only of [A-Za-z0-9+/=_-]
(min..max length) that mix upper, lower and digits with Shannon entropy >= min_bits_per_char, unless an allow rule
(known digests/pins, UUIDs, values pinned in repo files, compiler symbol manglings) matches or the string reads as an
identifier (dictionary word); media/weights extensions are exempt from the entropy check only.
Findings are printed redacted (first 4 chars + length), never in full. Exit 0 = clean, 1 = findings, 2 = usage.
No third-party modules (runs under `python3 -I`).
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
TOKEN = re.compile(rb"[A-Za-z0-9+/=_-]{32,}")
PRINTABLE = re.compile(rb"[\x21-\x7e]{32,}")
EDGE = b"\'\"<>,;:()[]{}`"


def read_patterns(path: Path) -> dict:
    """Tiny reader for the documented subset of YAML used by secret-patterns.yml."""
    doc: dict = {}
    section = None
    item: dict | None = None
    for raw in path.read_text().splitlines():
        line = raw.split(" #", 1)[0].rstrip() if not raw.lstrip().startswith("#") else ""
        if not line.strip():
            continue
        if not line.startswith(" "):
            section = line.rstrip(":").strip()
            doc[section] = [] if section in ("patterns", "allow") else {}
            item = None
            continue
        s = line.strip()
        if s.startswith("- "):
            item = {}
            doc[section].append(item)
            s = s[2:]
        key, _, val = s.partition(":")
        val = val.strip()
        if len(val) >= 2 and val[0] == val[-1] == "'":
            val = val[1:-1]
        target = item if isinstance(doc[section], list) else doc[section]
        target[key.strip()] = val
    return doc


def entropy(b: bytes) -> float:
    n = len(b)
    return -sum(c / n * math.log2(c / n) for c in Counter(b).values())


def mixed(b: bytes) -> bool:
    return any(48 <= c <= 57 for c in b) and any(65 <= c <= 90 for c in b) and any(97 <= c <= 122 for c in b)


def pinned_values(files: str) -> set[bytes]:
    vals: set[bytes] = set()
    for rel in filter(None, (f.strip() for f in files.split(","))):
        p = REPO / rel
        if p.is_file():
            vals.update(m.group(0) for m in TOKEN.finditer(p.read_bytes()))
    return vals


SPLIT = re.compile(rb"[A-Z]?[a-z]+|[A-Z]+(?![a-z])")


class Words:
    """Identifier test: a CamelCase part (or its plural/-ed/-ing stem) of >= 5 letters is a dictionary word."""

    def __init__(self, path: str):
        self.words: set[bytes] = set()
        if path and Path(path).is_file():
            self.words = {w.strip().lower().encode() for w in open(path, errors="ignore") if len(w.strip()) >= 5}

    def identifier(self, t: bytes) -> bool:
        if not self.words:
            return False
        for w in SPLIT.findall(t):
            w = w.lower()
            if len(w) < 5:
                continue
            for cand in (w, *(w[: -len(s)] for s in (b"s", b"es", b"ed", b"ing", b"y", b"er") if w.endswith(s))):
                if len(cand) >= 5 and cand in self.words:
                    return True
        return False


def scan(root: Path, cfg: dict) -> tuple[list[dict], int, list[str]]:
    named = [(p["id"], re.compile(p["regex"].encode())) for p in cfg.get("patterns", [])]
    ent = cfg.get("entropy", {})
    min_len = int(ent.get("min_length", "32"))
    max_len = int(ent.get("max_length", "256"))
    min_bits = float(ent.get("min_bits_per_char", "4.6"))
    skip_ext = {e.strip().lower() for e in ent.get("skip_ext", "").split(",") if e.strip()}
    words = Words(ent.get("wordlist", ""))
    notes = [] if words.words else [f"wordlist {ent.get('wordlist')!r} not found: identifier test off"]
    keyish = re.compile(rb"^[A-Za-z0-9+/=_-]{%d,%d}$" % (min_len, max_len))
    allow_re = [re.compile(a["regex"].encode()) for a in cfg.get("allow", []) if "regex" in a]
    spans_re = [re.compile(a["span"].encode(), re.S) for a in cfg.get("allow", []) if "span" in a]
    allow_vals: set[bytes] = set()
    for a in cfg.get("allow", []):
        if "files" in a:
            allow_vals |= pinned_values(a["files"])

    findings: list[dict] = []
    nfiles = 0
    for dp, dns, fns in os.walk(root):
        dns.sort()
        for fn in sorted(fns):
            p = Path(dp) / fn
            if p.is_symlink() or not p.is_file():
                continue
            nfiles += 1
            data = p.read_bytes()
            rel = str(p.relative_to(root))
            for rid, rx in named:
                for m in rx.finditer(data):
                    findings.append({"file": rel, "rule": rid, "offset": m.start(), "preview": redact(m.group(0))})
            if p.suffix.lower() in skip_ext:
                continue
            skip = [(s.start(), s.end()) for rx in spans_re for s in rx.finditer(data)]
            for m in PRINTABLE.finditer(data):
                if any(a <= m.start() < b for a, b in skip):
                    continue
                tok = m.group(0).strip(EDGE)
                if not keyish.match(tok) or not mixed(tok) or entropy(tok) < min_bits:
                    continue
                if tok in allow_vals or any(a.search(tok) for a in allow_re) or words.identifier(tok):
                    continue
                findings.append({"file": rel, "rule": "high-entropy", "offset": m.start(), "preview": redact(tok)})
    return findings, nfiles, notes


def redact(b: bytes) -> str:
    s = b.decode("ascii", "replace")
    return f"{s[:4]}…({len(s)} chars)"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("bundle")
    ap.add_argument("--patterns", default=str(REPO / "tools/ci/secret-patterns.yml"))
    ap.add_argument("--json", help="write a JSON report here")
    a = ap.parse_args()
    root = Path(a.bundle)
    if not root.exists():
        print(f"bundle-secret-scan: {root} does not exist", file=sys.stderr)
        return 2
    findings, nfiles, notes = scan(root, read_patterns(Path(a.patterns)))
    for n in notes:
        print(f"note: {n}")
    for f in findings[:200]:
        print(f"FINDING {f['rule']}: {f['file']} @{f['offset']} {f['preview']}")
    if len(findings) > 200:
        print(f"… {len(findings) - 200} more")
    print(f"[{'ok' if not findings else 'fail'}] {nfiles} files scanned, {len(findings)} finding(s) in {root}")
    if a.json:
        Path(a.json).parent.mkdir(parents=True, exist_ok=True)
        Path(a.json).write_text(json.dumps({"bundle": str(root), "files": nfiles, "notes": notes, "findings": findings}, indent=1) + "\n")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
