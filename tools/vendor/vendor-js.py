#!/usr/bin/env python3
"""`make vendor-js` (M1.T09; upstream.md §2 row Vendor/js, §8 "npm ci into a temp dir, copy dist, verify integrity").

  python3 -I tools/vendor/vendor-js.py           # npm ci (lockfile) in a temp dir, copy dist files, write Vendor/js/vendored-js.json
  python3 -I tools/vendor/vendor-js.py --check   # offline: committed copies match vendored-js.json and the lockfile pins

npm runs with --ignore-scripts (no install scripts execute). The tarball integrity (sha512) is verified by npm ci
against Vendor/js/package-lock.json; the copied file's sha256 is recorded in Vendor/js/vendored-js.json, which
`tools/vendor-sync vendored-json` folds into Vendor/VENDORED.json.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
JS = ROOT / "Vendor/js"
TOOLS_JS = "Packages/Tools/Sources/AntiChatTools/Resources/js"
# package → [(file inside the package, destination relative to ROOT, used_by)]
FILES = {
    "mermaid": [("dist/mermaid.min.js", "Packages/UI/Sources/AntiChatUI/Resources/mermaid/mermaid.min.js", "P-shell-04")],
    # M6.T09 (P-files-tools-05): RenderHost bundles (Tools resources, loaded through antichat-render://). docx ships
    # an IIFE build (global `docx`) next to the UMD one; the IIFE needs no module loader in WKWebView.
    "docx": [("dist/index.iife.js", f"{TOOLS_JS}/docx.iife.js", "P-files-tools-05")],
    "pptxgenjs": [("dist/pptxgen.bundle.js", f"{TOOLS_JS}/pptxgen.bundle.js", "P-files-tools-05")],
    "vega": [("build/vega.min.js", f"{TOOLS_JS}/vega.min.js", "P-files-tools-06")],
    "vega-lite": [("build/vega-lite.min.js", f"{TOOLS_JS}/vega-lite.min.js", "P-files-tools-06")],
    "vega-embed": [("build/vega-embed.min.js", f"{TOOLS_JS}/vega-embed.min.js", "P-files-tools-06")],
    # M6.T13 (A-M6-08, R-016 AC2): React previews in the sandboxed panel — UMD production builds + Babel standalone,
    # inlined into the preview page (never loaded by URL).
    "react": [("umd/react.production.min.js", f"{TOOLS_JS}/react.production.min.js", "A-M6-08")],
    "react-dom": [("umd/react-dom.production.min.js", f"{TOOLS_JS}/react-dom.production.min.js", "A-M6-08")],
    "@babel/standalone": [("babel.min.js", f"{TOOLS_JS}/babel.min.js", "A-M6-08")],
}


def sha256(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def lock_entry(lock: dict, pkg: str) -> dict:
    return lock["packages"][f"node_modules/{pkg}"]


def manifest(lock: dict) -> list[dict]:
    out = []
    for pkg, files in FILES.items():
        e = lock_entry(lock, pkg)
        for src, dst, used in files:
            p = ROOT / dst
            out.append({"package": pkg, "version": e["version"], "integrity": e["integrity"], "resolved": e["resolved"],
                        "license": e.get("license", "MIT"), "upstream_path": src, "local_path": dst,
                        "sha256": sha256(p) if p.exists() else None, "used_by": [used],
                        "license_file": f"Vendor/js/licenses/{pkg.replace('/', '__')}.LICENSE"})
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    lock = json.loads((JS / "package-lock.json").read_text())
    pinned = json.loads((JS / "package.json").read_text())["dependencies"]
    for pkg in FILES:
        if lock_entry(lock, pkg)["version"] != pinned[pkg]:
            print(f"vendor-js: {pkg} lock {lock_entry(lock, pkg)['version']} != package.json {pinned[pkg]}")
            return 1
    out = JS / "vendored-js.json"
    if a.check:
        want = manifest(lock)
        cur = json.loads(out.read_text()) if out.exists() else None
        bad = [w["local_path"] for w in want if w["sha256"] is None]
        if cur != {"files": want} or bad:
            print(f"vendor-js: stale or missing ({bad or 'vendored-js.json differs'}); run `make vendor-js`")
            return 1
        print(f"vendor-js: ok ({len(want)} files)")
        return 0
    with tempfile.TemporaryDirectory() as tmp:
        for f in ("package.json", "package-lock.json"):
            shutil.copy2(JS / f, Path(tmp) / f)
        subprocess.run(["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund", "--omit=optional"], cwd=tmp,
                       check=True)
        for pkg, files in FILES.items():
            for src, dst, _ in files:
                d = ROOT / dst
                d.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(Path(tmp) / "node_modules" / pkg / src, d)
            lic = next((Path(tmp) / "node_modules" / pkg / n for n in ("LICENSE", "LICENSE.md", "LICENSE.txt")
                        if (Path(tmp) / "node_modules" / pkg / n).exists()), None)
            if lic:
                (JS / "licenses").mkdir(exist_ok=True)
                shutil.copy2(lic, JS / "licenses" / f"{pkg.replace('/', '__')}.LICENSE")
    out.write_text(json.dumps({"files": manifest(lock)}, indent=1) + "\n")
    print(f"vendor-js: copied {sum(len(v) for v in FILES.values())} file(s); wrote {out.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
