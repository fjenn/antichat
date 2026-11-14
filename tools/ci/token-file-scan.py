#!/usr/bin/env python3
"""AT-257 c2 (R-257 AC2, NFR-SEC4): issued OAuth tokens live in the Keychain only. Run with `python3 -I`.

    python3 -I tools/ci/token-file-scan.py --container ~/Library/Application\\ Support/AntiChat-Dev \\
        --needle-file build/at/AT-257/issued-tokens.txt [--also DIR ...]

Scans every file (byte search, so SQLite pages, WAL, binary plists and logs count) under the container, the app's
caches (`~/Library/Caches/AntiChat*`), `~/Library/Preferences/app.antichat*.plist`, `~/Library/Logs/AntiChat*` and
any `--also` directory for each needle (files over `--max-mb`, default 256 — model weights in `Models/` — are
skipped and counted; the app writes no token-sized record into a weight file) (one per line: access and refresh tokens the reference AS issued). Exit 1
with `path: token prefix` lines when one is found; exit 0 with a JSON summary otherwise. (`secret-scan.py` from
M7.T04 does not exist: T04 moved to M11 A3, D-026; this scanner stands alone.)
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from pathlib import Path


def roots(container: Path, also: list[str]) -> list[Path]:
    home = Path.home()
    out = [container]
    out += [Path(p) for p in glob.glob(str(home / "Library/Caches/AntiChat*"))]
    out += [Path(p) for p in glob.glob(str(home / "Library/Preferences/app.antichat*.plist"))]
    out += [Path(p) for p in glob.glob(str(home / "Library/Logs/AntiChat*"))]
    out += [Path(a).expanduser() for a in also]
    return [p for p in out if p.exists()]


def files(root: Path):
    if root.is_file():
        yield root
        return
    for dirpath, _dirs, names in os.walk(root, followlinks=False):
        for n in names:
            p = Path(dirpath) / n
            if p.is_file() and not p.is_symlink():
                yield p


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--container", required=True)
    ap.add_argument("--needle-file", required=True)
    ap.add_argument("--also", action="append", default=[])
    ap.add_argument("--max-mb", type=int, default=256)
    a = ap.parse_args()
    needles = [n.strip().encode() for n in Path(a.needle_file).read_text().splitlines() if len(n.strip()) >= 16]
    if not needles:
        print("token-file-scan: no needles (run the AT-257 tests first)", file=sys.stderr)
        return 2
    hits, scanned, size, skipped = [], 0, 0, 0
    for root in roots(Path(a.container).expanduser(), a.also):
        for f in files(root):
            try:
                if f.stat().st_size > a.max_mb * 1024 * 1024:
                    skipped += 1
                    continue
                data = f.read_bytes()
            except OSError:
                continue
            scanned += 1
            size += len(data)
            for n in needles:
                if n in data:
                    hits.append(f"{f}: {n[:6].decode()}…")
    for h in hits:
        print(h)
    print(json.dumps({"needles": len(needles), "files": scanned, "bytes": size, "hits": len(hits), "skipped_large": skipped,
                      "roots": [str(r) for r in roots(Path(a.container).expanduser(), a.also)]}))
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
