#!/usr/bin/env python3
"""sha256 lock of fixture files (M0.T01 step 6/9; environment.md §2).

  lock.py write <dir> <lockfile> [--only SUBDIR ...] [--exclude GLOB ...]
  lock.py check <dir> <lockfile> [same filters]   -> exit 20 on mismatch (bootstrap code)

Paths are relative to <dir>, sorted. Hidden files/dirs (.git, .work, .gitattributes) and the
lockfile itself are skipped. Git LFS pointer files are hashed as checked out (run `git lfs pull` first).
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import sys


def scan(root: str, only: list[str], exclude: list[str], lockfile: str) -> dict[str, dict]:
    out = {}
    bases = [os.path.join(root, o) for o in only] if only else [root]
    for base in bases:
        for dp, dns, fns in os.walk(base):
            dns[:] = sorted(d for d in dns if not d.startswith("."))
            for fn in sorted(fns):
                if fn.startswith("."):
                    continue
                full = os.path.join(dp, fn)
                rel = os.path.relpath(full, root)
                if os.path.abspath(full) == os.path.abspath(lockfile):
                    continue
                if any(fnmatch.fnmatch(rel, g) for g in exclude):
                    continue
                h = hashlib.sha256()
                with open(full, "rb") as f:
                    for chunk in iter(lambda: f.read(1 << 20), b""):
                        h.update(chunk)
                out[rel] = {"sha256": h.hexdigest(), "size": os.path.getsize(full)}
    return dict(sorted(out.items()))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["write", "check"])
    ap.add_argument("dir")
    ap.add_argument("lockfile")
    ap.add_argument("--only", action="append", default=[])
    ap.add_argument("--exclude", action="append", default=[])
    a = ap.parse_args()
    files = scan(a.dir, a.only, a.exclude, a.lockfile)
    if a.mode == "write":
        with open(a.lockfile, "w") as f:
            json.dump({"version": 1, "files": files}, f, indent=1, sort_keys=True)
            f.write("\n")
        print(f"[ok] {len(files)} files locked -> {a.lockfile}")
        return 0
    want = json.load(open(a.lockfile))["files"]
    bad = 0
    for rel in sorted(set(want) | set(files)):
        if rel not in files:
            print(f"missing {rel}"); bad += 1
        elif rel not in want:
            print(f"unlocked {rel}"); bad += 1
        elif files[rel]["sha256"] != want[rel]["sha256"]:
            print(f"mismatch {rel} expected {want[rel]['sha256']} actual {files[rel]['sha256']}"); bad += 1
    print(f"[{'ok' if not bad else 'fail'}] {len(files)} files, {bad} problem(s)")
    return 20 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
