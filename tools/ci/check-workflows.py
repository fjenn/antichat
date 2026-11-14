#!/usr/bin/env python3
"""R-285 AC7 (M4.T03): a CI job exists that runs on changes to the given paths. Stdlib only, `python3 -I`.

  check-workflows.py --job child-safety --paths 'Packages/ChildSafetyCheck/**,catalog/models.yaml'

Passes when .github/workflows/ci.yml defines the job and the job's text names every path (its path filter step;
`**` globs are matched by their directory prefix) and runs the ChildSafetyCheck tests.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def job_block(text: str, job: str) -> str | None:
    m = re.search(rf"^  {re.escape(job)}:\s*$", text, re.M)
    if not m:
        return None
    nxt = re.search(r"^  [A-Za-z0-9_-]+:\s*$", text[m.end():], re.M)
    return text[m.end(): m.end() + nxt.start()] if nxt else text[m.end():]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--job", required=True)
    ap.add_argument("--paths", required=True)
    ap.add_argument("--workflow", default=str(ROOT / ".github/workflows/ci.yml"))
    a = ap.parse_args()
    text = Path(a.workflow).read_text(encoding="utf-8")
    block = job_block(text, a.job)
    errs = []
    if block is None:
        errs.append(f"{a.workflow}: job '{a.job}' missing")
    else:
        for p in [x.strip() for x in a.paths.split(",") if x.strip()]:
            prefix = p.split("**")[0]
            if prefix not in block:
                errs.append(f"job '{a.job}': path {p} not filtered")
        if "Packages/ChildSafetyCheck" not in block or "swift test" not in block:
            errs.append(f"job '{a.job}': does not run the ChildSafetyCheck tests")
    for e in errs:
        print(e)
    print(f"check-workflows: {'FAIL ' + str(len(errs)) if errs else 'ok'} (job {a.job})")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
