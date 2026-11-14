#!/usr/bin/env python3
"""Release-pipeline lint (M10.T01 AT-305 check 3; ci-release §3/§4; M10 card contracts 1 and 3). `python3 -I`.

Fails (one line per problem) when, under tools/release/ (or `--root DIR` for self-tests):
  1. a non-comment `codesign` line signs with `--deep` (verification lines carry `--verify`/`-v` and are allowed;
     D-06: nested code is signed one by one, inside out);
  2. an entitlements plist grants `com.apple.security.cs.allow-jit`, or grants
     `com.apple.security.cs.disable-library-validation` outside `adhoc-extra.plist` (ad-hoc builds only,
     A-M0-T12a) and `video-runtime.plist` (the downloadable Python runtime, ci-release §3 matrix);
  3. a script passes notary credentials other than `--keychain-profile` (`--apple-id`, `--password`, `--team-id`
     on a notarytool line, `--key`/`--key-id`/`--issuer`) — secrets live only in the keychain profile;
  4. a certificate / private-key file (.p12, .p8, .cer, .pem, .mobileprovision) is tracked anywhere in the repo
     (test keys live only under fixtures/ and catalog/test-keys/).
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

LV_ALLOWED = {"adhoc-extra.plist", "video-runtime.plist"}
SECRET_EXT = (".p12", ".p8", ".cer", ".pem", ".mobileprovision")
SECRET_DIRS_OK = ("fixtures/", "catalog/test-keys/")
NOTARY_BAD = re.compile(r"notarytool\b.*(--apple-id|--password|--team-id|--key\b|--key-id|--issuer)")


def files(root: Path) -> list[str]:
    try:
        out = subprocess.run(["git", "-C", str(root), "ls-files", "-co", "--exclude-standard"],
                             capture_output=True, text=True, check=True).stdout
        return [l for l in out.splitlines() if l]
    except (subprocess.CalledProcessError, FileNotFoundError):
        return [str(p.relative_to(root)) for p in root.rglob("*") if p.is_file()]


def check(root: Path) -> list[str]:
    bad: list[str] = []
    rel_dir = root / "tools/release"
    for p in sorted(rel_dir.rglob("*")):
        if not p.is_file() or p.suffix in {".plist", ".md", ".png", ".tiff", ".icns"} or ".venv" in p.parts:
            continue
        rel = p.relative_to(root)
        for n, line in enumerate(p.read_text(errors="replace").splitlines(), 1):
            code = line.split("#", 1)[0] if p.suffix in {".sh", ".py", ""} else line
            if "codesign" in code and "--deep" in code and not re.search(r"--verify|\s-v\b|verify", code):
                bad.append(f"{rel}:{n}: codesign signs with --deep (sign nested code inside out)")
            if NOTARY_BAD.search(code):
                bad.append(f"{rel}:{n}: notarytool credentials outside --keychain-profile")
    for p in sorted((rel_dir / "entitlements").glob("*.plist")):
        try:
            # plutil, not plistlib: the M0 plists carry "--" inside XML comments, which expat rejects.
            d = json.loads(subprocess.run(["plutil", "-convert", "json", "-o", "-", str(p)],
                                          capture_output=True, text=True, check=True).stdout)
        except (subprocess.CalledProcessError, ValueError) as e:
            bad.append(f"{p.relative_to(root)}: unreadable plist ({e})")
            continue
        if d.get("com.apple.security.cs.allow-jit"):
            bad.append(f"{p.relative_to(root)}: grants allow-jit (forbidden everywhere)")
        if d.get("com.apple.security.cs.disable-library-validation") and p.name not in LV_ALLOWED:
            bad.append(f"{p.relative_to(root)}: grants disable-library-validation (adhoc-extra / video-runtime only)")
    for f in files(root):
        if f.lower().endswith(SECRET_EXT) and not f.startswith(SECRET_DIRS_OK):
            bad.append(f"{f}: certificate/key file in the repo (secrets stay in the keychain)")
    return bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    bad = check(Path(ap.parse_args().root))
    for b in bad:
        print(b)
    print(f"release-lint: {'ok' if not bad else f'{len(bad)} problem(s)'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
