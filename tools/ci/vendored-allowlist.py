#!/usr/bin/env python3
"""Vendored-path allow-list check (D-15; upstream.md §1 rule 4; M0.T02 step 9). Run with `python3 -I`.

Fails (exit 1) when
  - a file under Vendor/<donor>@<short>/ (compiled copy) is not a `vendored`/`test` row of
    Vendor/<donor>-allowlist.tsv (meta files ORIGIN, LICENSE, access-rewrite.txt excepted);
  - a file under Vendor/.upstream/<donor>@<short>/ is not an allow-list row (any mode) or LICENSE;
  - any allow-listed or vendored path matches DENY (minus the explicit ALLOW set);
  - Vendor/vendir.yml includePaths differ from the allow-list (run `tools/vendor-sync gen-vendir`).
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VENDOR = ROOT / "Vendor"
DENY = re.compile(r"Orchestrator|/Agents?/|HTTPServer|/Server/|Bonjour|/Relay/|Identity|Aptabase|Sentry|"
                  r"Plugin|/VM/|Sandbox/VM|Channels|ComputerUse|AppleScript|BrowserUse|Billing|ModelsProxy")
# Explicit exceptions to DENY, each with its reason (A-M0-06).
ALLOW = {
    # P-files-tools-14 (M0.md T02 step 3).
    "Packages/OsaurusCore/Services/Sandbox/Seatbelt/SeatbeltSandbox.swift",
    # Foundation-only protocol + 3 value types the document adapters conform to (105 lines);
    # it lives under Services/Plugin/ but contains no plugin-host code.
    "Packages/OsaurusCore/Services/Plugin/FormatAdapter.swift",
    # M7.T12 (P-files-tools-16): the Agent Skills `Skill` value type + SKILL.md parse/export. It lives under
    # Models/Agent/ but holds no agent or orchestrator code (no imports beyond Foundation; Yams via UP-OS-041).
    "Packages/OsaurusCore/Models/Agent/Skill.swift",
}
META = {"ORIGIN", "LICENSE", "access-rewrite.txt"}


def main() -> int:
    errors: list[str] = []
    donors = json.loads((VENDOR / "donors.json").read_text())
    vendir = (VENDOR / "vendir.yml").read_text() if (VENDOR / "vendir.yml").exists() else ""
    n_files = 0
    for name, d in donors.items():
        short = d["ref"][:7]
        rows = []
        for line in (VENDOR / f"{name}-allowlist.tsv").read_text().splitlines():
            if line.strip() and not line.startswith("#"):
                mode, path = line.split("\t")[:2]
                rows.append((mode, path))
        allowed_all = {p for _, p in rows}
        allowed_compiled = {p for m, p in rows if m in ("vendored", "test")}
        for _, p in rows:
            if DENY.search("/" + p) and p not in ALLOW:
                errors.append(f"DENY path in allow-list: {p}")
        compiled = VENDOR / f"{name}@{short}"
        for f in sorted(compiled.rglob("*")):
            if not f.is_file():
                continue
            rel = str(f.relative_to(compiled))
            n_files += 1
            if rel in META:
                continue
            if rel not in allowed_compiled:
                errors.append(f"not allow-listed (compiled copy): {compiled.name}/{rel}")
            if DENY.search("/" + rel) and rel not in ALLOW:
                errors.append(f"DENY path vendored: {compiled.name}/{rel}")
        pristine = VENDOR / ".upstream" / f"{name}@{short}"
        for f in sorted(pristine.rglob("*")):
            if f.is_file():
                rel = str(f.relative_to(pristine))
                if rel not in allowed_all and rel not in set(d.get("extra_include", [])):
                    errors.append(f"not allow-listed (pristine): {pristine.name}/{rel}")
                if DENY.search("/" + rel) and rel not in ALLOW:
                    errors.append(f"DENY path in pristine copy: {pristine.name}/{rel}")
        section = vendir.split(f"- path: Vendor/.upstream/{name}@{short}\n", 1)[-1].split("\n- path: ", 1)[0] \
            if f"- path: Vendor/.upstream/{name}@{short}\n" in vendir else ""
        listed = set(re.findall(r"^    - (\S+)$", section, re.M))
        want = allowed_all | set(d.get("extra_include", [])) | set(d.get("exclude", []))
        if listed != want:
            for p in sorted(listed ^ want):
                errors.append(f"vendir.yml out of sync with allow-list: {p}")
        for m, p in rows:
            if m in ("vendored", "test") and not (compiled / p).exists():
                errors.append(f"allow-listed but missing from compiled copy: {p}")
    # D-07 (M6.T12): charts are Vega in RenderHost; Osaurus' NativeChartView is never vendored.
    vj = ROOT / "Vendor" / "VENDORED.json"
    if vj.exists() and "NativeChartView" in vj.read_text():
        errors.append("D-07: NativeChartView must not be vendored (Vendor/VENDORED.json)")
    for e in errors:
        print(e)
    print(f"vendored-allowlist: {n_files} compiled-copy files checked, {len(errors)} error(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
