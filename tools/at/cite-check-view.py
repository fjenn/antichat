#!/usr/bin/env python3
"""M7 bars-3 (AT-248 c1 probe): an install view of the on-demand `cite-check` model (MiniCheck, Core ML) inside a probe's
private Models overlay, as the app has it after its first web answer downloaded it. The files are APFS clones (no extra
disk) of the developer's dev copy, each checked against catalog/catalog.lock.json; manifest.json is the InstallManifest
form (model_id, catalog_version, engine, placement, files → sha256, sizes) and .verified stamps it. Never writes into the
developer's Models directory.
  python3 -I tools/at/cite-check-view.py <dev cite-check dir> <overlay installs/cite-check> <catalog.lock.json> [catalog version]
"""
import hashlib
import json
import subprocess
import sys
from pathlib import Path


def find(o):
    if isinstance(o, dict):
        if "cite-check" in o and isinstance(o["cite-check"], dict) and "files" in o["cite-check"]:
            return o["cite-check"]
        for v in o.values():
            r = find(v)
            if r:
                return r
    return None


def main() -> None:
    src, dst, lock = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    version = int(sys.argv[4]) if len(sys.argv) > 4 else 9
    entry = find(json.load(open(lock)))
    if not entry:
        raise SystemExit("cite-check not in the catalog lock")
    files, sizes = {}, {}
    for f in entry["files"]:
        s, d = src / f["path"], dst / f["path"]
        h = hashlib.sha256()
        with open(s, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        if h.hexdigest() != f["sha256"]:
            raise SystemExit(f"{s}: sha256 differs from the catalog lock")
        d.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["cp", "-cp", str(s), str(d)], check=True)
        files[f["path"]], sizes[f["path"]] = f["sha256"], f["size"]
    manifest = {"catalog_version": version, "engine": "coreml", "files": files, "model_id": "cite-check",
                "placement": "clone", "raw_tensor_files": [], "sizes": sizes}
    (dst / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True))
    (dst / ".verified").touch()
    print(f"cite-check view: {len(files)} files → {dst}")


if __name__ == "__main__":
    main()
