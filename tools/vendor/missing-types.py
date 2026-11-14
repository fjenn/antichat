#!/usr/bin/env python3
"""Map `cannot find … in scope` errors to their defining upstream file (M0.T02 step 7.1).

Usage: swift build --target OsaurusVendored 2>&1 | python3 -I tools/vendor/missing-types.py --repo /tmp/osaurus/Packages/OsaurusCore

For each missing symbol prints `<symbol>\t<defining file(s) relative to Packages/OsaurusCore>\t<DENY?>\t<first referencing file>`.
Members referenced through a type (`cannot find 'X' in scope` for an extension method) are found by the
same declaration regex. Exit 0 always (it is a report).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ERR = re.compile(r"^(?P<file>/[^:]+):\d+:\d+: error: (?:cannot find type '(?P<t>\w+)' in scope|cannot find '(?P<v>\w+)' in scope|"
                 r"type '(?P<m>\w+)' has no member|value of type '[^']+' has no member '(?P<mem>\w+)')")
DENY = re.compile(r"Orchestrator|/Agents?/|HTTPServer|/Server/|Bonjour|/Relay/|Identity|Aptabase|Sentry|"
                  r"Plugin|/VM/|Sandbox/VM|Channels|ComputerUse|AppleScript|BrowserUse|Billing|ModelsProxy")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    a = ap.parse_args()
    repo = Path(a.repo)
    sources = {p: p.read_text(errors="replace") for p in repo.rglob("*.swift") if "/Tests/" not in str(p)}
    seen: dict[str, str] = {}
    for line in sys.stdin:
        m = ERR.match(line)
        if not m:
            continue
        sym = m.group("t") or m.group("v") or m.group("m") or m.group("mem")
        seen.setdefault(sym, Path(m.group("file")).name)
    for sym, ref in sorted(seen.items()):
        decl = re.compile(rf"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|private|fileprivate|final|static|"
                          rf"nonisolated|open|indirect)\s+)*(?:class|struct|enum|protocol|actor|typealias|func|let|var|case)\s+"
                          rf"{re.escape(sym)}\b", re.M)
        hits = sorted(str(p.relative_to(repo)) for p, t in sources.items() if decl.search(t))
        deny = any(DENY.search("/" + h) for h in hits)
        print(f"{sym}\t{', '.join(hits) or '(not found)'}\t{'DENY' if deny else ''}\t{ref}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
