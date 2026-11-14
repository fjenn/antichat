#!/usr/bin/env python3
"""Manifest + size report of a runtime component zip (M6.T15 step 5; generic, D-026: M5.T01's video runtime
uses it too). Stdlib only. Run with `python3 -I`.

    runtime-manifest.py --name filetools-runtime --version 0.1.0 --root build/runtimes/filetools \
        --zip build/runtimes/filetools-runtime-0.1.0.zip --out build/runtimes/filetools-runtime-0.1.0.json \
        [--size-report build/at/AT-018/<date>/size.json --size-limit 90000000]

Manifest: {name, version, zip: {path, sha256, size_bytes}, tree_bytes, files: [{path, size, sha256, mode,
link?}]} with paths relative to the root, sorted (byte order). Exit 1 when --size-limit is exceeded.
--verify-dir DIR checks an unzipped tree against an existing manifest (--out) instead (exit 1 on a mismatch).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tree(root: Path) -> list[dict]:
    rows = []
    for dirpath, dirnames, filenames in os.walk(root):
        for n in filenames + [d for d in dirnames if os.path.islink(os.path.join(dirpath, d))]:
            p = Path(dirpath) / n
            rel = p.relative_to(root).as_posix()
            st = p.lstat()
            if p.is_symlink():
                rows.append({"path": rel, "link": os.readlink(p), "mode": oct(st.st_mode & 0o7777)})
            else:
                rows.append({"path": rel, "size": st.st_size, "sha256": sha256(p), "mode": oct(st.st_mode & 0o7777)})
    rows.sort(key=lambda r: r["path"].encode())
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--name", required=False)
    ap.add_argument("--version", required=False)
    ap.add_argument("--root", type=Path)
    ap.add_argument("--zip", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--size-report", type=Path)
    ap.add_argument("--size-limit", type=int)
    ap.add_argument("--verify-dir", type=Path)
    a = ap.parse_args()

    if a.verify_dir:
        want = {r["path"]: r for r in json.loads(a.out.read_text())["files"]}
        got = {r["path"]: r for r in tree(a.verify_dir)}
        bad = sorted(set(want) ^ set(got)) + sorted(p for p in set(want) & set(got)
                                                     if want[p].get("sha256") != got[p].get("sha256")
                                                     or want[p].get("link") != got[p].get("link"))
        for p in bad[:20]:
            print(f"mismatch: {p}", file=sys.stderr)
        print(f"verify {a.verify_dir}: {len(got)} entries, {len(bad)} mismatches")
        return 1 if bad else 0

    files = tree(a.root)
    tree_bytes = sum(r.get("size", 0) for r in files)
    z = {"path": a.zip.name, "sha256": sha256(a.zip), "size_bytes": a.zip.stat().st_size}
    manifest = {"name": a.name, "version": a.version, "zip": z, "tree_bytes": tree_bytes, "file_count": len(files),
                "files": files}
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(manifest, indent=1) + "\n")
    print(f"[manifest] {a.out}: {len(files)} entries, tree {tree_bytes / 1e6:.1f} MB, "
          f"zip {z['size_bytes'] / 1e6:.1f} MB sha256 {z['sha256']}")
    ok = a.size_limit is None or z["size_bytes"] <= a.size_limit
    if a.size_report:
        a.size_report.parent.mkdir(parents=True, exist_ok=True)
        a.size_report.write_text(json.dumps({
            "name": a.name, "version": a.version, "zip": z["path"], "zip_sha256": z["sha256"],
            "zip_bytes": z["size_bytes"], "zip_mb": round(z["size_bytes"] / 1e6, 2), "tree_bytes": tree_bytes,
            "limit_bytes": a.size_limit, "pass": ok,
            "measured_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }, indent=1) + "\n")
    if not ok:
        print(f"[manifest] zip {z['size_bytes']} B exceeds the limit {a.size_limit} B", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
