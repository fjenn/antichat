#!/usr/bin/env python3
"""Owner try-out preview only (build-release.sh with TRYOUT_PREVIEW=1, `make build-tryout`).

Copies the signed runtime zip of every catalog runtime (`<name>-<version>.zip` from --from) into the preview app's
`Contents/Resources/TryoutRuntimes/`, after checking its sha256 and size against the bundled catalog
(Packages/Platform/.../catalog-baseline.json). The preview installs runtimes from there (TryoutPreview.swift)
because the catalog URLs still point at the dev server until hosting is live. Any missing or mismatching zip stops
the build: a preview that cannot install File tools is not the preview the owner asked for.
Stdlib only.
"""
import argparse, hashlib, json, pathlib, shutil, sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Packages/Platform/Sources/AntiChatPlatform/Resources/catalog-baseline.json"


def sha256(p: pathlib.Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="src", required=True, help="folder with the signed runtime zips")
    ap.add_argument("--into", required=True, help="the app's Contents/Resources/TryoutRuntimes")
    ap.add_argument("--catalog", default=str(CATALOG))
    a = ap.parse_args()
    runtimes = json.loads(pathlib.Path(a.catalog).read_text()).get("runtimes", [])
    src, dst = pathlib.Path(a.src), pathlib.Path(a.into)
    dst.mkdir(parents=True, exist_ok=True)
    bad = 0
    for r in runtimes:
        name = f"{r['name']}-{r['version']}.zip"
        p = src / name
        if not p.is_file():
            print(f"error: {p} missing (build it, or set TRYOUT_RUNTIMES)", file=sys.stderr); bad += 1; continue
        size, digest = p.stat().st_size, sha256(p)
        if size != r["size_bytes"] or digest != r["sha256"]:
            print(f"error: {name}: sha256 {digest} size {size} != catalog {r['sha256']} {r['size_bytes']}", file=sys.stderr)
            bad += 1; continue
        shutil.copyfile(p, dst / name)
        print(f"  {name}: sha256 ok ({size} B)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
