#!/usr/bin/env python3
"""Visual QA: a local Hugging Face mirror for the onboarding / install legs (run `python3 -I`).

vq-m2.sh used to serve one installed model folder (`<container>/Models/installs/chat-0.8b`) with range-server.py. An
install folder holds symlinks into `../../store/sha256/…`, and range-server only serves files whose real path lies
under its root, so every request was a 404: S-04 showed every pack "Didn't finish" (M9 R8, M10 harness issue 1). Voice
and Photo were never in that folder at all.

This builds `<out>/<org>/<repo>/resolve/<commit>/<file>` (the URL path `-DownloadHost` keeps, see
DownloadRequest.rewritten) for every catalog file whose blob is in one of the content-addressed stores
(`<store>/<aa>/<sha256>`), as APFS clones (`cp -c`: no extra disk). Serve it with `range-server.py --literal`. A model
with a file in no store is left out (its pack then fails honestly: nothing is faked). Nothing is fetched from the
network; the app still sha256-verifies every byte against the signed catalog.
Usage: vq-mirror.py --catalog <catalog.json> --out <dir> --store <dir> [--store <dir> …]
"""
import argparse, json, os, subprocess, sys
from pathlib import Path

HF = "https://huggingface.co/"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--store", action="append", default=[], help="a <Models>/store/sha256 folder (repeatable)")
    a = ap.parse_args()
    models = json.load(open(a.catalog))["models"]
    stores = [Path(s) for s in a.store if Path(s).is_dir()]
    out = Path(a.out)
    served, skipped = [], []
    for mid, m in sorted(models.items()):
        plan = []
        for f in m["files"]:
            src = next((s for s in f["sources"] if s.startswith(HF)), None)
            blob = next((s / f["sha256"][:2] / f["sha256"] for s in stores
                         if (s / f["sha256"][:2] / f["sha256"]).is_file()), None)
            if not src or not blob or blob.stat().st_size != f["size"]:
                plan = None
                break
            plan.append((blob, out / src[len(HF):].split("?")[0], f["size"]))
        if not plan:
            skipped.append(mid)
            continue
        for blob, dest, size in plan:
            if dest.is_file() and dest.stat().st_size == size:
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.unlink(missing_ok=True)
            subprocess.run(["cp", "-c", str(blob), str(dest)], check=True)
        served.append(mid)
    print(f"vq-mirror: {len(served)} models → {out} ({','.join(served)}); not in any store: {','.join(skipped)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
