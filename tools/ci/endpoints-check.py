#!/usr/bin/env python3
"""Endpoints placeholder audit (M8.T09 fix; lead decision 2026-11-05). Run with `python3 -I`.

Config/Endpoints.plist keeps placeholder values until M10 (the owner provides the public repo and the support inbox).
A placeholder must never reach the user as a broken mailto: / issue URL in a release build. This check fails when
  1. a hand-off value (IssuesURL, SupportEmail) is neither usable (https + dotted host / a dotted-domain address)
     nor a recognised placeholder (one of ReportEndpoints.placeholderMarkers) — a half-filled value would pass the
     release guard;
  2. the marker list here and `ReportEndpoints.placeholderMarkers` in ReportProblemComposer.swift differ;
  3. the release guard is gone: `load(plist:allowPlaceholders:)` must default to the DEBUG flag and check
     `isUsableIssuesURL` + `isUsableEmail`, and the sheets must offer Copy when the endpoints are nil.
`--strict` (M10 release gate) also fails while any hand-off value is still a placeholder, or while RelayURL (the
Composio relay, RC review P1-2) is not an https URL on a public dotted host (the dev value is http://127.0.0.1:3000).
An empty RelayURL fails --strict too (release 2 deployed the relay; release builds would hide the Composio connectors).
"""
from __future__ import annotations

import argparse
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLIST = "Config/Endpoints.plist"
SWIFT = "Packages/Platform/Sources/AntiChatPlatform/Diagnostics/ReportProblemComposer.swift"
SHEET = "Packages/UI/Sources/AntiChatUI/Diagnostics/ReportProblemSheet.swift"
CRASH = "Packages/UI/Sources/AntiChatUI/Diagnostics/CrashPromptSheet.swift"
MARKERS = ["placeholder", ".invalid", "example.", "localhost", "todo", "changeme"]


def placeholder(v: str) -> bool:
    return not v or any(m in v.lower() for m in MARKERS)


def usable_url(v: str) -> bool:
    m = re.match(r"^https://([^/\s]+)(/\S*)?$", v)
    return bool(m and "." in m.group(1)) and not placeholder(v)


def usable_mail(v: str) -> bool:
    return bool(re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", v)) and not placeholder(v)


def relay_ok(v: str) -> bool:
    m = re.match(r"^https://([^/\s:]+)(:\d+)?(/\S*)?$", v)
    host = m.group(1).lower() if m else ""
    loopback = host in ("localhost", "0.0.0.0") or host.startswith("127.") or host.startswith("[")
    return bool(m and "." in host) and not loopback and not placeholder(v)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(ROOT))
    ap.add_argument("--strict", action="store_true")
    a = ap.parse_args()
    root = Path(a.root)
    errs: list[str] = []
    d = plistlib.loads((root / PLIST).read_bytes())
    for key, ok in (("IssuesURL", usable_url), ("SupportEmail", usable_mail)):
        v = d.get(key, "")
        if not ok(v) and not placeholder(v):
            errs.append(f"{PLIST}: {key}={v!r} is neither usable nor a recognised placeholder")
        if a.strict and placeholder(v):
            errs.append(f"{PLIST}: {key}={v!r} is still a placeholder (--strict: M10 release gate)")
    relay = d.get("RelayURL", "")
    if a.strict and not relay_ok(relay):
        errs.append(f"{PLIST}: RelayURL={relay!r} is not a deployed https relay (--strict: M10 release gate, RC review P1-2)")
    src = (root / SWIFT).read_text()
    m = re.search(r"placeholderMarkers\s*=\s*\[([^\]]*)\]", src)
    swift_markers = re.findall(r'"([^"]*)"', m.group(1)) if m else []
    if swift_markers != MARKERS:
        errs.append(f"{SWIFT}: placeholderMarkers {swift_markers} != endpoints-check.py {MARKERS}")
    for needle in ("allowPlaceholders: Bool = AppDatabaseFlags.isDebugBuild", "isUsableIssuesURL(issues)", "isUsableEmail(mail)"):
        if needle not in src:
            errs.append(f"{SWIFT}: release guard missing ({needle})")
    if "report.copy" not in (root / SHEET).read_text():
        errs.append(f"{SHEET}: no Copy fallback when the endpoints are not configured")
    if "controller.endpoints == nil" not in (root / CRASH).read_text():
        errs.append(f"{CRASH}: Send must be disabled when the endpoints are not configured")
    for e in errs:
        print(e, file=sys.stderr)
    if not errs:
        state = "placeholders (release build hides the hand-offs)" if any(placeholder(d.get(k, "")) for k in ("IssuesURL", "SupportEmail")) else "configured"
        print(f"endpoints-check: ok — {state}")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
