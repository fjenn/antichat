#!/usr/bin/env python3
"""AT-NFR-PR5 checker (M10.T03): the update check carries no stable identifier. Run with `python3 -I`.

Input: one or more feed-server.py request logs (JSON lines), e.g. one per fresh VM clone running the same build.
For every GET of the feed path (default /appcast-dev.xml):
  - query string empty (SUEnableSystemProfiling = NO → Sparkle sends no profile keys);
  - headers ⊆ {Host, User-Agent, Accept, Accept-Language, Accept-Encoding, Connection}; no Cookie/Authorization;
  - User-Agent matches ^AntiChat/<ver> Sparkle/2.10.1 (optional OS/arch tokens);
  - across all logs, each header value is identical (a value that differs between installs is a per-install id);
    Host may differ only by port.
Exit 0 = pass. Usage: pr5-check.py LOG [LOG…] [--feed-path /appcast-dev.xml]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from urllib.parse import urlparse

ALLOWED = {"host", "user-agent", "accept", "accept-language", "accept-encoding", "connection"}
UA = re.compile(r"^AntiChat/[0-9][0-9.]* Sparkle/2\.10\.1(\s.*)?$")


def check(logs: list[list[dict]], feed_path: str) -> list[str]:
    bad: list[str] = []
    seen: dict[str, set[str]] = {}
    n = 0
    for i, entries in enumerate(logs):
        for e in entries:
            u = urlparse(e["path"])
            if e.get("method") != "GET" or u.path != feed_path:
                continue
            n += 1
            if u.query:
                bad.append(f"log {i}: query string on the feed request: {u.query}")
            h = {k.lower(): v for k, v in e["headers"].items()}
            extra = set(h) - ALLOWED
            if extra:
                bad.append(f"log {i}: unexpected headers {sorted(extra)}")
            if not UA.match(h.get("user-agent", "")):
                bad.append(f"log {i}: User-Agent {h.get('user-agent')!r} is not AntiChat/<ver> Sparkle/2.10.1")
            for k, v in h.items():
                seen.setdefault(k, set()).add(v.rsplit(":", 1)[0] if k == "host" else v)
    if n == 0:
        bad.append(f"no GET {feed_path} in the logs")
    for k, vals in seen.items():
        if len(vals) > 1:
            bad.append(f"header {k} differs between requests/installs: {sorted(vals)}")
    return bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("logs", nargs="+")
    ap.add_argument("--feed-path", default="/appcast-dev.xml")
    a = ap.parse_args()
    logs = [[json.loads(l) for l in open(p) if l.strip()] for p in a.logs]
    bad = check(logs, a.feed_path)
    for b in bad:
        print(b)
    print(f"pr5-check: {'pass' if not bad else f'{len(bad)} problem(s)'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
