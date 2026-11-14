#!/usr/bin/env python3
"""Forbidden-dependency audit (architecture §3 rule 4, P-platform-08; A-M0-04). Run with `python3 -I`.

Fails if any shipped target links AsyncHTTPClient, swift-nio, Sentry, Aptabase, Firebase or PostHog.
Checked on the LINKED target closure (A-M0-04), not on presence in Package.resolved: swift-nio is resolved
(MCP swift-sdk's MCPConformanceServer executable) but no AntiChat product links it, so it is only reported.
Shipped roots = every non-test target of the root package and of local path packages (ChildSafetyCheck).
Exit 1 with `package/target <- root` lines on violation.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_common import ROOT, Graph  # noqa: E402

FORBIDDEN = re.compile(r"(async-http-client|swift-nio|sentry|aptabase|firebase|posthog)", re.I)
FORBIDDEN_TARGET = re.compile(r"^(AsyncHTTPClient|NIO\w*|Sentry\w*|Aptabase\w*|Firebase\w*|PostHog\w*)$")


def main() -> int:
    g = Graph()
    errors: list[str] = []
    roots = []
    for ident in [g.root_id] + [i for i in g.package_deps(g.root_id) if (g.paths.get(i) or Path("/")).is_relative_to(ROOT / "Packages")]:
        for t in g.pkgs[ident]["targets"]:
            if t["type"] in ("regular", "executable", "system", "binary", "macro"):
                roots.append((ident, t["name"]))
    linked: dict[tuple[str, str], str] = {}
    for r in roots:
        for node in g.closure(*r):
            linked.setdefault(node, f"{r[0]}/{r[1]}")
    for (pk, tn), root in sorted(linked.items()):
        if FORBIDDEN.search(pk) or FORBIDDEN_TARGET.match(tn):
            errors.append(f"forbidden: {pk}/{tn} <- {root}")
    resolved = json.loads((ROOT / "Package.resolved").read_text())
    present = sorted(p["identity"] for p in resolved.get("pins", []) if FORBIDDEN.search(p["identity"]))
    linked_pkgs = {pk for pk, _ in linked}
    for p in present:
        if p.lower() not in linked_pkgs:
            print(f"info: {p} is in Package.resolved but not linked by any shipped target (A-M0-04)")
    print(f"forbidden-deps: {len(roots)} roots, {len(linked)} linked targets, {len(linked_pkgs)} packages")
    for e in errors:
        print(e)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
