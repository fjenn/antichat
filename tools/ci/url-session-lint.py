#!/usr/bin/env python3
"""URLSession lint (architecture §3 rule 5, D-02; M1.T02). Run with `python3 -I`.

Bans `URLSession(` and `URLSessionConfiguration.` in compiled Swift outside Packages/Network/. Scope: every
tracked .swift file except test code (`*/Tests/*`, App/*Tests/), pristine upstream copies (Vendor/.upstream/)
and SwiftPM checkouts. Vendored lines are allowed only when patched to `NetworkGate.session(for:)` (line carries
an `ANTICHAT-PATCH` block) or listed in tools/ci/url-session-allowlist.yml (path, match, justification,
reviewer, until). AntiChatNetwork is a thin gate in M1; the full gate lands in M2.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_common import ROOT, allowed, load_allowlist, repo_files, validate_allowlist  # noqa: E402

BAN = re.compile(r"\bURLSession\s*\(|\bURLSessionConfiguration\s*\.")


def in_scope(r: str) -> bool:
    if r.startswith(("Packages/Network/", "Vendor/.upstream/")):
        return False
    if "/Tests/" in r or re.match(r"App/\w*Tests/", r) or r.startswith(("tools/", "_vendor-eval/")):
        return False
    return r.startswith(("App/", "Packages/", "Vendor/"))


def check(root: Path = ROOT, allowlist: Path | None = None) -> list[str]:
    allowlist = allowlist or root / "tools/ci/url-session-allowlist.yml"
    entries = load_allowlist(allowlist) if allowlist.exists() else []
    errs = validate_allowlist(entries, ("path", "match", "justification", "reviewer"), allowlist.name)
    for f in repo_files(root):
        r = str(f.relative_to(root))
        if not in_scope(r):
            continue
        in_patch = False
        for i, line in enumerate(f.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if "ANTICHAT-PATCH-END" in line:
                in_patch = False
            elif "ANTICHAT-PATCH:" in line:
                in_patch = True
            code = line.split("//", 1)[0]
            if BAN.search(code) and not (in_patch and "NetworkGate" in line) and not allowed(entries, r, line):
                errs.append(f"{r}:{i}: URLSession/URLSessionConfiguration outside AntiChatNetwork (architecture §3 rule 5)")
    return errs


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT
    errs = check(root)
    for e in errs:
        print(e)
    print(f"url-session-lint: {'FAIL ' + str(len(errs)) if errs else 'ok'}")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
