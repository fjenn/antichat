#!/usr/bin/env python3
"""No retyped tier budgets (M7.T14 step 1; A-M7-04, A-M6-06). Run with `python3 -I` (stdlib only).

The per-tier budgets live only in Packages/Harness/Resources/tier-budgets.json; code and tests read them through
`TierBudgets` (Harness passes the numbers into AntiChatTools APIs). This check fails when a tracked Swift / TypeScript
/ Markdown file under the code roots retypes a `section.key: value` tuple of that file, i.e. a line that names a
per-tier row (its snake_case or camelCase key) together with one tier and that tier's value (`"T2": 8`,
`maxPerStep["T2"] == 8`, `max_per_step T2 = 8`, …).

  * Scanned: Packages/, App/, tools/, relay/, site/ (*.swift, *.ts, *.md). Not scanned: docs/ (the PRD and the
    blueprint are the cited source of the numbers), vendored code (Vendor/, vendor/), build output, fixtures/.
  * A line may opt out with `budget-ok: <reason>` (e.g. a test asserting a fallback constant that is not a budget).

  --root <dir>   repository root (tests)
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

BUDGETS = "Packages/Harness/Resources/tier-budgets.json"
ROOTS = ("Packages/", "App/", "tools/", "relay/", "site/")
EXTS = (".swift", ".ts", ".md")
SKIP = ("Vendor/", "vendor/", "/.build/", "build/", "fixtures/", "node_modules/")


def camel(snake: str) -> str:
    head, *rest = snake.split("_")
    return head + "".join(w[:1].upper() + w[1:] for w in rest)


def rows(budgets: dict) -> list[tuple[str, str, dict[str, object]]]:
    """(section, key, {tier: value}) for every per-tier row (a dict keyed T0…T4)."""
    out = []
    for section, body in budgets.items():
        if not isinstance(body, dict):
            continue
        for key, val in body.items():
            if isinstance(val, dict) and val and all(re.fullmatch(r"T[0-4]", k) for k in val):
                out.append((section, key, val))
    return out


def literal(v: object) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float) and v.is_integer():
        return rf"{int(v)}(?:\.0+)?"
    return re.escape(str(v))


def patterns(budgets: dict) -> list[tuple[str, re.Pattern[str], re.Pattern[str]]]:
    out = []
    for section, key, val in rows(budgets):
        names = {key, camel(key)}
        name_rx = re.compile(r"\b(?:" + "|".join(re.escape(n) for n in sorted(names)) + r")\b")
        tier_rx = re.compile("|".join(rf"\bT{t[1]}\b[\"'\]\s:=,()]{{1,8}}{literal(v)}(?![\d.])" for t, v in val.items()))
        out.append((f"{section}.{key}", name_rx, tier_rx))
    return out


def tracked(root: Path) -> list[str]:
    r = subprocess.run(["git", "-C", str(root), "ls-files"], capture_output=True, text=True, check=True)
    return [f for f in r.stdout.splitlines()
            if f.startswith(ROOTS) and f.endswith(EXTS) and not any(s in f for s in SKIP) and f != BUDGETS]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    a = ap.parse_args()
    root = Path(a.root)
    budgets = json.loads((root / BUDGETS).read_text(encoding="utf-8"))
    pats = patterns(budgets)
    errors = 0
    files = tracked(root)
    for f in files:
        try:
            text = (root / f).read_text(encoding="utf-8")
        except (UnicodeDecodeError, FileNotFoundError):
            continue
        for i, line in enumerate(text.splitlines(), 1):
            if "budget-ok:" in line:
                continue
            for row, name_rx, tier_rx in pats:
                if name_rx.search(line) and tier_rx.search(line):
                    print(f"{f}:{i}: retypes tier budget {row} (read it through TierBudgets): {line.strip()[:160]}")
                    errors += 1
                    break
    print(f"no-retyped-budgets: {len(pats)} rows, {len(files)} files, {errors} error(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
