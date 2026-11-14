#!/usr/bin/env python3
"""Vendor-sync rehearsal plan (M0.T03 step 2; upstream.md §7). Run with `python3 -I`.

  rehearsal-plan.py --repo <upstream clone> --head <sha> --months 6 [--allowlist Vendor/osaurus-allowlist.tsv]

Prints JSON: sha_0 = the last first-parent commit (from --head) whose committer date is at least `months`
calendar months and at least 183 days (6 months) before --head's committer date; sha_k (k = 1…months-1) =
the last first-parent commit at date(sha_0) + k calendar months; sha_months = --head. With --allowlist,
each step also lists how many allow-listed files exist upstream at that commit (the closure grows over the
window when upstream added the files later).
"""
from __future__ import annotations

import argparse
import calendar
import json
import subprocess
import sys
from datetime import datetime, timedelta, timezone


def git(repo: str, *args: str) -> str:
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=True).stdout


def add_months(t: datetime, k: int) -> datetime:
    y, m = divmod(t.month - 1 + k, 12)
    y, m = t.year + y, m + 1
    return t.replace(year=y, month=m, day=min(t.day, calendar.monthrange(y, m)[1]))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--head", required=True)
    ap.add_argument("--months", type=int, default=6)
    ap.add_argument("--allowlist")
    a = ap.parse_args()
    head = git(a.repo, "rev-parse", f"{a.head}^{{commit}}").strip()
    # First-parent history of the default branch as seen from head: (sha, committer time), newest first.
    hist = [(s, datetime.fromtimestamp(int(t), timezone.utc))
            for s, t in (l.split() for l in git(a.repo, "log", "--first-parent", "--format=%H %ct", head).splitlines())]
    head_t = hist[0][1]

    def last_at(t: datetime) -> tuple[str, datetime] | None:
        return next(((s, ct) for s, ct in hist if ct <= t), None)

    cutoff = min(add_months(head_t, -a.months), head_t - timedelta(days=183 * a.months / 6))
    first = last_at(cutoff)
    if first is None:
        print(f"history from {head[:7]} starts after {cutoff.isoformat()}", file=sys.stderr)
        return 1
    steps = [first]
    for k in range(1, a.months):
        steps.append(last_at(add_months(first[1], k)))
    steps.append(hist[0])
    rows = []
    paths = []
    if a.allowlist:
        paths = [l.split("\t")[:2] for l in open(a.allowlist) if l.strip() and not l.startswith("#")]
    for k, (s, t) in enumerate(steps):
        row = {"k": k, "sha": s, "short": s[:7], "committer_date": t.isoformat(),
               "first_parent_commits_since_prev": 0 if k == 0 else
               int(git(a.repo, "rev-list", "--first-parent", "--count", f"{steps[k - 1][0]}..{s}").strip())}
        if paths:
            tree = set(git(a.repo, "ls-tree", "-r", "--name-only", s).splitlines())
            for mode in ("vendored", "test", "watch"):
                want = [p for m, p in paths if m == mode]
                row[f"allowlisted_{mode}_present"] = f"{sum(p in tree for p in want)}/{len(want)}"
        rows.append(row)
    out = {"generated_by": "tools/vendor/rehearsal-plan.py", "repo": a.repo, "head": head, "months": a.months,
           "head_date": head_t.isoformat(), "sha_0_cutoff": cutoff.isoformat(),
           "span_days": round((head_t - steps[0][1]).total_seconds() / 86400, 2), "steps": rows}
    print(json.dumps(out, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
