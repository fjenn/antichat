#!/usr/bin/env python3
"""M10.T09: a local mirror of the catalog's Hugging Face files for the clean-VM final acceptance (run `python3 -I`).

The VM's own downloads go through the app's real downloader (DownloadCoordinator → TransferEngine → sha256 verify →
install), pointed at this mirror with the DEBUG `-DownloadHost http://127.0.0.1:<port>` (DownloadRequest.rewritten):
the path stays `/<org>/<repo>/resolve/<commit>/<file>`. The link to Hugging Face from this Mac is ~0.5 MB/s, so
fetching ~5 GB per VM pass from it would take hours; the mirror makes a pass repeatable. Every file is verified
against the signed catalog's sha256 here and again by the app.

Sources, in order: the developer's content-addressed store (`$ANTICHAT_DEV_CACHE/Models/store` or
`~/Library/Application Support/AntiChat-Dev/Models/store/sha256/<aa>/<sha>`, an APFS clone: no extra disk), a file
already in the mirror, else the catalog URL (anonymous HTTPS, resumed with Range).
Usage: fa-mirror.py --catalog site/public/catalog/v2/catalog.json --out build/fa/mirror --ids chat-0.8b,chat-2b,…
"""
import argparse, hashlib, json, os, subprocess, sys, urllib.request
from pathlib import Path

HF = "https://huggingface.co/"


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def fetch(url: str, dest: Path) -> None:
    part = dest.with_suffix(dest.suffix + ".part")
    have = part.stat().st_size if part.exists() else 0
    req = urllib.request.Request(url, headers={"Range": f"bytes={have}-"} if have else {})
    with urllib.request.urlopen(req, timeout=60) as r, open(part, "ab" if have and r.status == 206 else "wb") as f:
        while b := r.read(1 << 20):
            f.write(b)
    part.rename(dest)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--ids", required=True, help="comma-separated catalog model ids")
    ap.add_argument("--store", default=os.path.join(os.environ.get("ANTICHAT_DEV_CACHE") or os.path.expanduser(
        "~/Library/Application Support/AntiChat-Dev"), "Models", "store", "sha256"))
    a = ap.parse_args()
    models = json.load(open(a.catalog))["models"]
    out = Path(a.out)
    total = cloned = fetched = 0
    for mid in [m for m in a.ids.split(",") if m]:
        if mid not in models:
            print(f"fa-mirror: {mid} is not in the catalog", file=sys.stderr)
            return 2
        for f in models[mid]["files"]:
            src = next((s for s in f["sources"] if s.startswith(HF)), None)
            if not src:
                print(f"fa-mirror: {mid}/{f['path']} has no Hugging Face source", file=sys.stderr)
                return 2
            dest = out / src[len(HF):].split("?")[0]
            dest.parent.mkdir(parents=True, exist_ok=True)
            total += f["size"]
            if dest.exists() and dest.stat().st_size == f["size"] and sha256(dest) == f["sha256"]:
                continue
            dest.unlink(missing_ok=True)
            cas = Path(a.store) / f["sha256"][:2] / f["sha256"]
            if cas.is_file() and cas.stat().st_size == f["size"]:
                subprocess.run(["cp", "-c", str(cas), str(dest)], check=True)  # APFS clone
                cloned += 1
            else:
                print(f"fa-mirror: fetching {mid}/{f['path']} ({f['size'] / 1e6:.0f} MB)", flush=True)
                fetch(src, dest)
                fetched += 1
            if sha256(dest) != f["sha256"]:
                dest.unlink()
                print(f"fa-mirror: sha256 mismatch {mid}/{f['path']}", file=sys.stderr)
                return 1
    print(f"fa-mirror: {a.ids} → {out} ({total / 1e9:.2f} GB; {cloned} cloned, {fetched} fetched)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
