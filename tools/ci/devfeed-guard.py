#!/usr/bin/env python3
"""make audit + release preflight (RC review P2-8): the committed Sparkle test key and the AntiChatFeedURLOverride
feed default can never be used by a release (Developer ID) build.

Source checks (always):
  1. UpdateFeed.devFeedAllowed is `#if DEBUG || ANTICHAT_DEV_FEED` true `#else` false.
  2. The "AntiChatFeedURLOverride" literal appears in shipping Swift only inside a `#if DEBUG || ANTICHAT_DEV_FEED`
     branch (a release binary does not even contain the key).
  3. UpdateFeed.resolve gives no feed for a test (or missing) key where the dev feed is not allowed, before it looks
     at the override; UpdaterService.start never starts Sparkle without a feed.
  4. ANTICHAT_DEV_FEED is set only by build-release.sh, by the one line that requires dev keys and a non-devid
     signing mode, and appears in no other file (project.yml, Makefile, xcconfigs).
Artefact checks:
  5. --app APP: no executable code in the bundle carries the override key;
     with --release also: Info.plist SUPublicEDKey is not the committed test key (catalog/test-keys/sparkle-test.pub).
     preflight.py runs `--app build/release/AntiChat.app --release`.
  6. Without --app, if build/release/build.json says a devid build exists, check 5 (override key) runs on it.
Stdlib only; exit 1 on any violation. --root points at another tree (self-tests).
"""
from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

UPDATE_STATE = "Packages/Platform/Sources/AntiChatPlatform/Updates/UpdateState.swift"
UPDATER_SERVICE = "Packages/Platform/Sources/AntiChatPlatform/Updates/UpdaterService.swift"
BUILD_RELEASE = "tools/release/build-release.sh"
TEST_PUB = "catalog/test-keys/sparkle-test.pub"
OVERRIDE = "AntiChatFeedURLOverride"
GATE = "#if DEBUG || ANTICHAT_DEV_FEED"
DEV_FEED_LINE = ('[[ "$keys" == dev && "$mode" != devid ]] && '
                 "conditions=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ANTICHAT_DEV_FEED')")
ALLOWED = {UPDATE_STATE, BUILD_RELEASE, "tools/ci/devfeed-guard.py", "tools/ci/tests/test_devfeed_guard.py"}


def code_only(line: str) -> str:
    """The line without a trailing `//` comment (good enough for these sources: no `//` inside the literals)."""
    i = line.find("//")
    return line if i < 0 else line[:i]


def gated_spans(src: str) -> list[tuple[int, int]]:
    return [(m.start(1), m.end(1)) for m in re.finditer(re.escape(GATE) + r"\n(.*?)#(?:else|endif)", src, re.S)]


def source_checks(root: Path) -> list[str]:
    errors: list[str] = []
    st = (root / UPDATE_STATE).read_text(encoding="utf-8")
    if not re.search(r"static var devFeedAllowed: Bool \{\s*" + re.escape(GATE) + r"\s*true\s*#else\s*false\s*#endif",
                     st):
        errors.append(f"{UPDATE_STATE}: devFeedAllowed must be `{GATE}` true `#else` false")
    m = re.search(r"static func resolve\(.*?\n    \}\n", st, re.S)
    body = m.group(0) if m else ""
    refuse = body.find('if dev, !devFeedAllowed { return UpdateFeed(url: "", devKeys: true) }')
    override = body.find("let o = override")
    if refuse < 0 or (override >= 0 and override < refuse):
        errors.append(f"{UPDATE_STATE}: resolve must give no feed for a test key without devFeedAllowed, "
                      "before it reads the override")
    svc = (root / UPDATER_SERVICE).read_text(encoding="utf-8")
    if "guard !feed.isDisabled" not in svc:
        errors.append(f"{UPDATER_SERVICE}: start() must not start Sparkle without a feed (guard !feed.isDisabled)")

    swift = [p for top in ("Packages", "App") if (root / top).is_dir() for p in (root / top).rglob("*.swift")]
    for p in swift:
        rel = p.relative_to(root).as_posix()
        if any(part.endswith("Tests") or part.startswith(".") for part in rel.split("/")) or not p.is_file():
            continue
        src = p.read_text(encoding="utf-8", errors="replace")
        if f'"{OVERRIDE}"' not in src:
            continue
        spans = gated_spans(src)
        pos = 0
        for line in src.splitlines(keepends=True):
            if f'"{OVERRIDE}"' in code_only(line) and not any(a <= pos < b for a, b in spans):
                errors.append(f"{rel}: \"{OVERRIDE}\" outside a `{GATE}` branch")
            pos += len(line)

    br = (root / BUILD_RELEASE).read_text(encoding="utf-8")
    dev_lines = [l.strip() for l in br.splitlines() if "ANTICHAT_DEV_FEED" in code_only_sh(l)]
    if dev_lines != [DEV_FEED_LINE]:
        errors.append(f"{BUILD_RELEASE}: ANTICHAT_DEV_FEED must be added by exactly `{DEV_FEED_LINE}` "
                      f"(found {dev_lines})")
    users = subprocess.run(["git", "-C", str(root), "grep", "-l", "ANTICHAT_DEV_FEED", "--", ".", ":!fixtures", ":!docs"],
                           capture_output=True, text=True).stdout.split()
    for f in users:
        if f not in ALLOWED:
            errors.append(f"{f}: uses ANTICHAT_DEV_FEED (only {sorted(ALLOWED)} may)")
    return errors


def code_only_sh(line: str) -> str:
    s = line.lstrip()
    return "" if s.startswith("#") else line


def app_checks(root: Path, app: Path, release: bool) -> list[str]:
    errors: list[str] = []
    contents = app / "Contents"
    if not contents.is_dir():
        return [f"{app}: not an app bundle"]
    needle = OVERRIDE.encode()
    for sub in ("MacOS", "Frameworks", "XPCServices", "PlugIns", "Helpers"):
        d = contents / sub
        if not d.is_dir():
            continue
        for f in d.rglob("*"):
            if f.is_file() and not f.is_symlink() and needle in f.read_bytes():
                errors.append(f"{f.relative_to(app.parent)}: carries the {OVERRIDE} key (dev feed compiled in)")
    if release:
        info = plistlib.loads((contents / "Info.plist").read_bytes())
        test = (root / TEST_PUB).read_text(encoding="utf-8").splitlines()[0].strip()
        key = info.get("SUPublicEDKey")
        if not key or key == test:
            errors.append(f"{app.name}: SUPublicEDKey is {'missing' if not key else 'the committed Sparkle test key'} "
                          "(a release build needs the production key: tools/release/KEYS.md)")
    return errors


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    ap.add_argument("--app", help="check a built AntiChat.app")
    ap.add_argument("--release", action="store_true", help="with --app: also refuse the test SUPublicEDKey")
    a = ap.parse_args()
    root = Path(a.root)
    errors = source_checks(root)
    if a.app:
        errors += app_checks(root, Path(a.app), a.release)
    else:
        bj = root / "build/release/build.json"
        try:
            devid = bj.exists() and json.loads(bj.read_text()).get("signing_mode") == "devid"
        except ValueError:
            devid = False
        if devid and (root / "build/release/AntiChat.app").is_dir():
            errors += app_checks(root, root / "build/release/AntiChat.app", release=False)
    for e in errors:
        print(f"devfeed-guard: {e}", file=sys.stderr)
    print(f"devfeed-guard: {'FAIL' if errors else 'ok'} ({len(errors)} problem(s))")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
