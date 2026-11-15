#!/usr/bin/env python3
"""Publish preflight (M10 card; ci-release §8): every blocker between the local release artefacts and a public
release, grouped by who clears it. Read-only: publishes nothing, contacts nothing but the local keychain/stapler.
Run with `python3 -I`.  Exit 0 only when nothing blocks.  `--json` prints the machine form.

Groups
  engineering  the pipeline's own state: a devid build exists, it is notarized and stapled (app and DMG), the
               Gatekeeper assessment accepted it, the working tree was clean at build time;
  owner        values only the owner can provide: Config/Endpoints.plist placeholders
               (tools/ci/endpoints-check.py --strict, the release gate kept since M8.T09);
  ceremony     production keys (M10.T04/T10 [human] key ceremony): Sparkle SUPublicEDKey and the pinned catalog
               keys must not be the committed test keys;
  hosting      where publishing would go (M10.T05/T10): public repo / GitHub Releases and the site host. Listed
               as steps, never executed here.
"""
from __future__ import annotations

import argparse
import json
import plistlib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def sh(*cmd: str) -> tuple[int, str]:
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    return r.returncode, (r.stdout + r.stderr).strip()


def engineering(rel: Path) -> list[str]:
    out: list[str] = []
    bj = rel / "build.json"
    if not bj.exists():
        return [f"no release build: run `make build-release SIGNING_MODE=devid` ({bj} missing)"]
    b = json.loads(bj.read_text())
    if b.get("signing_mode") != "devid":
        out.append(f"last build is SIGNING_MODE={b.get('signing_mode')}, not devid")
    if not b.get("notarized"):
        out.append("app not notarized (NOTARIZE=0 or notarization failed)")
    if b.get("dirty_files"):
        out.append(f"built from a dirty tree ({b['dirty_files']} changed files)")
    app = rel / "AntiChat.app"
    if app.exists() and b.get("notarized"):
        rc, txt = sh("xcrun", "stapler", "validate", str(app))
        if rc != 0:
            out.append(f"app ticket not stapled: {txt.splitlines()[-1] if txt else rc}")
    v = rel / "verify/verify.json"
    if v.exists() and not json.loads(v.read_text()).get("app", {}).get("pass"):
        out.append("verify-signing failed on the app (build/release/verify/)")
    version = b.get("version")
    dmgs = sorted(rel.glob(f"AntiChat-Installer-{version}*.dmg"))
    if not dmgs:
        out.append(f"no DMG for {version}: run `make dmg SIGNING_MODE=devid`")
    for d in dmgs:
        if "UNNOTARIZED" in d.name or "DEVKEYS" in d.name:
            continue  # labelled artefacts are reported through the label below
        rc, txt = sh("xcrun", "stapler", "validate", str(d))
        if rc != 0:
            out.append(f"{d.name}: no stapled ticket")
    if b.get("label") and b["label"] != "DEVKEYS":  # DEVKEYS = the ceremony item below
        out.append(f"artefact label {b['label']} (only unlabelled builds are publishable)")
    if app.exists():
        # RC review P2-8: the built app must not trust the committed Sparkle test key or carry the feed override,
        # whatever Config/Keys.release.plist holds (a DEVKEYS build after the ceremony would otherwise pass).
        rc, txt = sh(sys.executable, "-I", "tools/ci/devfeed-guard.py", "--app", str(app), "--release")
        if rc != 0:
            out += [l.removeprefix("devfeed-guard: ") for l in txt.splitlines() if "FAIL" not in l and l.strip()]
        # M9.T05: never ship the perf-harness build (Debug test hooks in an optimized binary).
        rc, txt = sh(sys.executable, "-I", "tools/ci/perfharness-guard.py", "--app", str(app))
        if rc != 0:
            out += [l.removeprefix("perfharness-guard: ") for l in txt.splitlines() if "FAIL" not in l and l.strip()]
    return out


def owner() -> list[str]:
    rc, txt = sh(sys.executable, "-I", "tools/ci/endpoints-check.py", "--strict")
    if rc == 0:
        return []
    return [l.strip() for l in txt.splitlines() if "placeholder" in l or "neither usable" in l] or [txt]


def ceremony() -> list[str]:
    rc, txt = sh(sys.executable, "-I", "tools/release/gen-keys-swift.py", "--release-ready")
    if rc == 0:
        return []
    return [l.replace("gen-keys-swift: release keys not ready: ", "Config/Keys.release.plist: ") +
            " (key ceremony: tools/release/KEYS.md)" for l in txt.splitlines() if l.strip()]


def hosting() -> list[str]:
    h = json.loads((ROOT / "Config/Hosting.json").read_text())
    out = []
    if ".vercel.app" in h["siteURL"]:
        out.append(f"Config/Hosting.json siteURL={h['siteURL']} is the interim host (own domain Q3; then set-hosting.py)")
    if "placeholder" in h["githubRepo"]:
        out.append(f"Config/Hosting.json githubRepo={h['githubRepo']} is a placeholder (public repo, PRD §9)")
    for k in ("securityEmail", "abuseEmail"):
        if h[k].endswith(".invalid"):
            out.append(f"Config/Hosting.json {k}={h[k]} is a placeholder (security.txt / abuse page)")
    # hosting-check.py (M10.T05): the signed catalog must not send runtime downloads to the `make site-dev` host.
    for line in (ROOT / "catalog/runtimes.yaml").read_text().splitlines():
        url = line.strip().removeprefix("url:").strip().strip('"') if line.strip().startswith("url:") else ""
        if url.startswith(("http://localhost", "http://127.0.0.1")):
            out.append(f"catalog/runtimes.yaml url {url} is the dev host (release: a GitHub Release asset or the "
                       "site; tools/site/hosting-check.py fails it without --dev)")
    out.append("not done by the pipeline (by design): GitHub Release upload of the DMG + SHA256SUMS, site/appcast "
               "deploy (`make site-deploy-prod`), appcast.xml publication — owner steps in docs/prd/M10-owner-steps.md")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--release-dir", default=str(ROOT / "build/release"))
    a = ap.parse_args()
    report = {"engineering": engineering(Path(a.release_dir)), "owner": owner(), "ceremony": ceremony(),
              "hosting": hosting()}
    blocking = sum(len(v) for k, v in report.items() if k != "hosting") + len(report["hosting"]) - 1
    if a.json:
        print(json.dumps({"blockers": report, "blocking": blocking}, indent=2))
    else:
        for group, items in report.items():
            print(f"[{group}] {'none' if not items else ''}")
            for i in items:
                print(f"  - {i}")
        print(f"preflight: {'ready to publish' if blocking == 0 else f'{blocking} blocker(s)'}")
    return 0 if blocking == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
