#!/usr/bin/env python3
"""`make vendor-fonts` (M6.T09 step 5, P-files-tools-05): the Noto fonts the file-out renderers embed.

  python3 -I tools/vendor/vendor-fonts.py           # download each pinned file, verify, write Vendor/fonts/vendored-fonts.json
  python3 -I tools/vendor/vendor-fonts.py --check   # offline: committed copies match the manifest

Sources are pinned to a tag's full commit SHA (raw.githubusercontent.com/<repo>/<sha>/<path>); every file's sha256 is
recorded in Vendor/fonts/vendored-fonts.json, which `tools/vendor-sync vendored-json` folds into Vendor/VENDORED.json.
Licence: SIL OFL 1.1 (the repo's LICENSE at the same SHA, copied to Vendor/fonts/licenses/).

Not bundled (A-M6-T09a): Noto Sans Arabic and the Noto Sans CJK region subsets. CoreText's PDF output gives both a
broken ToUnicode map (shaped Arabic and CFF-CID CJK glyphs do not extract from the text layer, R-273 AC3), and the CJK
set alone is ≈ 23 MB; Arabic and CJK draw with the macOS system faces (Geeza Pro, PingFang, Hiragino Sans, Apple SD
Gothic Neo), embedded as subsets — the task's documented fallback.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = "Packages/Tools/Sources/AntiChatTools/Resources/fonts"
MANIFEST = ROOT / "Vendor/fonts/vendored-fonts.json"
LICENSES = ROOT / "Vendor/fonts/licenses"

# repo → (tag, full commit SHA, licence path in the repo, [file paths])
SOURCES = {
    "notofonts/notofonts.github.io": ("noto-monthly-release-2026.11.01", "412a7edb2c8c535d1066157e5b17e661fd5591fe",
                                      "fonts/LICENSE", [
        "fonts/NotoSans/hinted/ttf/NotoSans-Regular.ttf",
        "fonts/NotoSans/hinted/ttf/NotoSans-Bold.ttf",
        "fonts/NotoSans/hinted/ttf/NotoSans-Italic.ttf",
        "fonts/NotoSans/hinted/ttf/NotoSans-BoldItalic.ttf",
        "fonts/NotoSerif/hinted/ttf/NotoSerif-Regular.ttf",
        "fonts/NotoSerif/hinted/ttf/NotoSerif-Bold.ttf",
        "fonts/NotoSerif/hinted/ttf/NotoSerif-Italic.ttf",
        "fonts/NotoSansMono/hinted/ttf/NotoSansMono-Regular.ttf",
        "fonts/NotoSansHebrew/hinted/ttf/NotoSansHebrew-Regular.ttf",
        "fonts/NotoSansHebrew/hinted/ttf/NotoSansHebrew-Bold.ttf",
    ]),
}


def sha256(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def lic_name(repo: str) -> str:
    return repo.split("/")[1] + ".LICENSE"


def manifest() -> list[dict]:
    out = []
    for repo, (tag, sha, lic, paths) in SOURCES.items():
        for p in paths:
            local = ROOT / OUT_DIR / Path(p).name
            out.append({"repo": repo, "tag": tag, "sha": sha, "upstream_path": p,
                        "local_path": f"{OUT_DIR}/{Path(p).name}", "license": "OFL-1.1",
                        "sha256": sha256(local.read_bytes()) if local.exists() else None,
                        "used_by": ["P-files-tools-05"], "license_file": f"Vendor/fonts/licenses/{lic_name(repo)}"})
    return out


def fetch(repo: str, sha: str, path: str) -> bytes:
    url = f"https://raw.githubusercontent.com/{repo}/{sha}/{path}"
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    if a.check:
        want = manifest()
        cur = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else None
        bad = [w["local_path"] for w in want if w["sha256"] is None]
        if cur != {"files": want} or bad:
            print(f"vendor-fonts: stale or missing ({bad or 'vendored-fonts.json differs'}); run `make vendor-fonts`")
            return 1
        print(f"vendor-fonts: ok ({len(want)} files)")
        return 0
    (ROOT / OUT_DIR).mkdir(parents=True, exist_ok=True)
    LICENSES.mkdir(parents=True, exist_ok=True)
    for repo, (_, sha, lic, paths) in SOURCES.items():
        (LICENSES / lic_name(repo)).write_bytes(fetch(repo, sha, lic))
        for p in paths:
            (ROOT / OUT_DIR / Path(p).name).write_bytes(fetch(repo, sha, p))
    MANIFEST.write_text(json.dumps({"files": manifest()}, indent=1) + "\n")
    print(f"vendor-fonts: {sum(len(v[3]) for v in SOURCES.values())} file(s); wrote {MANIFEST.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
