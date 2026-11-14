#!/usr/bin/env python3
"""Project limit fixtures (M8.T04, AT-064): 101 small text files for the 100-file limit, and (with --sparse) one
2.1 GB sparse file for the 2 GB boundary, created at test time, never committed.

Usage: python3 -I tools/fixtures/make-project-limits.py --out /tmp/project-limits [--sparse]
stdlib only; deterministic contents.
"""
import argparse
import pathlib


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=pathlib.Path, required=True)
    ap.add_argument("--count", type=int, default=101)
    ap.add_argument("--sparse", action="store_true", help="also write big-2.1GB.bin (sparse)")
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    for i in range(1, a.count + 1):
        (a.out / f"note-{i:03d}.md").write_text(f"# Note {i}\n\nThis is project limit fixture note number {i}.\n")
    if a.sparse:
        with open(a.out / "big-2.1GB.bin", "wb") as f:
            f.truncate(int(2.1 * 1024 ** 3))
    print(f"make-project-limits: {a.count} notes{' + sparse 2.1 GB' if a.sparse else ''} in {a.out}")


if __name__ == "__main__":
    main()
