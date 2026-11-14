#!/usr/bin/env python3
"""Print the result.json object of one AT run (docs/prd/M1.md convention 2). Run with `python3 -I`.

  result.py <AT-ID> <cmd> <exit> [--started ISO] [--log PATH] [--root DIR]

Fields: id, date, commit (`git rev-parse HEAD`, "+dirty" when the tree has tracked changes), cmd, exit,
pass, plus started/log and `pending` (legs listed in build/at/<AT-ID>/pending.txt; blank lines and `#`
comments ignored). pass = exit == 0 and no pending legs.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys


def git(root: str, *args: str) -> str:
    try:
        return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("id")
    ap.add_argument("cmd")
    ap.add_argument("exit", type=int)
    ap.add_argument("--started")
    ap.add_argument("--log")
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    a = ap.parse_args(argv)

    commit = git(a.root, "rev-parse", "HEAD") or "unknown"
    if git(a.root, "status", "--porcelain", "--untracked-files=no"):
        commit += "+dirty"
    pending: list[str] = []
    pfile = os.path.join(a.root, "build", "at", a.id, "pending.txt")
    if os.path.exists(pfile):
        with open(pfile, encoding="utf-8") as f:
            pending = [ln.strip() for ln in f if ln.strip() and not ln.lstrip().startswith("#")]
    obj = {
        "id": a.id,
        "date": dt.date.today().isoformat(),
        "commit": commit,
        "cmd": a.cmd,
        "exit": a.exit,
        "pass": a.exit == 0 and not pending,
    }
    if pending:
        obj["pending"] = pending
    if a.started:
        obj["started"] = a.started
        obj["finished"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if a.log:
        obj["log"] = a.log
    json.dump(obj, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
