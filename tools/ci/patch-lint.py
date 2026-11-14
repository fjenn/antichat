#!/usr/bin/env python3
"""Patch-marker lint (upstream.md §3.4; M0.T02 step 10). Run with `python3 -I`.

Rules
  1. Every `ANTICHAT-PATCH: UP-xxx` marker has a row in the table of Vendor/UPSTREAM_PATCHES.md, and every
     row has ≥ 1 marker, except rows of kind `access` (satisfied by access-rewrite.txt entries).
  2. Every compiled file that differs from its pristine copy (after the mechanical access rewrite) has
     each changed or inserted line inside a marker block, and each deleted run of lines sits at a block.
  3. Blocks are balanced (`ANTICHAT-PATCH:` … `ANTICHAT-PATCH-END`, no nesting).
  4. Markers outside Vendor/ are errors (App/, Packages/, relay/, site/, catalog/).
  5. Rows listed under "Not applied" must not have markers.
  5b. Patch files of built binaries (Vendor/patches/**.patch): markers in their added lines, rows required.
  6. Sentinels (Vendor/<donor>-sentinels.txt, regex TAB why): stripped or rebranded code must not reappear in a
     compiled (non-test) file outside comments, e.g. when a bump merges a new upstream occurrence cleanly.
"""
from __future__ import annotations

import difflib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from vendor_sync import core  # noqa: E402

OPEN = re.compile(r"ANTICHAT-PATCH: (UP-[A-Z]+-\d{3})\b")
CLOSE = "ANTICHAT-PATCH-END"
ROW = re.compile(r"^\| (UP-[A-Z]+-\d{3}) \| [^|]+ \| [^|]+ \| ([^|]+) \|", re.M)


def table_rows(text: str) -> tuple[dict[str, str], set[str]]:
    applied, not_applied = {}, set()
    section = text.split("## Not applied", 1)
    for m in ROW.finditer(section[0]):
        applied[m.group(1)] = m.group(2).strip()
    if len(section) > 1:
        not_applied = set(re.findall(r"^\| (UP-[A-Z]+-\d{3}) \|", section[1], re.M))
    return applied, not_applied


def blocks(lines: list[str], where: str, errors: list[str]) -> list[tuple[int, int, str]]:
    out, start, up = [], None, None
    for i, l in enumerate(lines):
        m = OPEN.search(l)
        if m:
            if start is not None:
                errors.append(f"{where}:{i + 1}: nested ANTICHAT-PATCH block")
            start, up = i, m.group(1)
        elif CLOSE in l:
            if start is None:
                errors.append(f"{where}:{i + 1}: ANTICHAT-PATCH-END without an opening marker")
            else:
                out.append((start, i, up))
            start = None
    if start is not None:
        errors.append(f"{where}:{start + 1}: unterminated ANTICHAT-PATCH block")
    return out


def main() -> int:
    errors: list[str] = []
    table = (ROOT / "Vendor/UPSTREAM_PATCHES.md")
    applied, not_applied = table_rows(table.read_text()) if table.exists() else ({}, set())
    seen: dict[str, int] = {}
    checked = changed = 0
    for name in core.donors():
        d = core.donor(name)
        sent_file = ROOT / "Vendor" / f"{name}-sentinels.txt"
        sentinels = [(re.compile(l.split("\t")[0]), l.split("\t", 1)[1].strip() if "\t" in l else "")
                     for l in (sent_file.read_text().splitlines() if sent_file.exists() else [])
                     if l.strip() and not l.startswith("#")]
        for p in core.compiled_paths(d, ("vendored",)):
            f = d["compiled"] / p
            if not f.exists() or f.suffix != ".swift":
                continue
            for n, line in enumerate(f.read_text().splitlines(), 1):
                if line.lstrip().startswith("//"):
                    continue
                for rx, why in sentinels:
                    if rx.search(line):
                        errors.append(f"{d['compiled'].name}/{p}:{n}: sentinel {rx.pattern!r} ({why}): {line.strip()[:80]}")
        for p in core.compiled_paths(d):
            f = d["compiled"] / p
            if not f.exists() or f.suffix not in (".swift", ".py", ".m", ".h", ".c"):
                continue
            checked += 1
            where = f"{d['compiled'].name}/{p}"
            local = f.read_text().splitlines()
            bl = blocks(local, where, errors)
            for _, _, up in bl:
                seen[up] = seen.get(up, 0) + 1
                if up not in applied:
                    errors.append(f"{where}: marker {up} has no row in UPSTREAM_PATCHES.md")
                if up in not_applied:
                    errors.append(f"{where}: marker {up} is listed under 'Not applied'")
            base = core.expected_unpatched(d, p).splitlines()
            if base == local:
                continue
            changed += 1
            # Collapse each block to one sentinel; what remains must be pristine text with lines
            # removed only where a block sits (2: changed lines inside blocks, deletions at a block).
            reduced, i = [], 0
            starts = {s: e for s, e, _ in bl}
            while i < len(local):
                if i in starts:
                    reduced.append(None)
                    i = starts[i] + 1
                else:
                    reduced.append(local[i])
                    i += 1
            sm = difflib.SequenceMatcher(a=base, b=reduced, autojunk=False)
            for tag, i1, i2, j1, j2 in sm.get_opcodes():
                if tag == "equal":
                    continue
                extra = [x for x in reduced[j1:j2] if x is not None and x.strip()]
                if extra:
                    errors.append(f"{where}: changed line outside an ANTICHAT-PATCH block: {extra[0].strip()[:80]}")
                elif i2 > i1 and not ({j1 - 1, j1, j2} & {k for k, x in enumerate(reduced) if x is None}):
                    errors.append(f"{where}: upstream line {i1 + 1} deleted without an ANTICHAT-PATCH block")
    # Patches on built upstream binaries (M4.T05: Vendor/patches/<submodule>/*.patch, applied to a copy of the pinned
    # tree by tools/binaries/build.sh): their added lines carry the same balanced markers.
    for f in sorted((ROOT / "Vendor/patches").rglob("*.patch")):
        added = [l[1:] for l in f.read_text().splitlines() if l.startswith("+") and not l.startswith("+++")]
        for _, _, up in blocks(added, str(f.relative_to(ROOT)), errors):
            seen[up] = seen.get(up, 0) + 1
            if up not in applied:
                errors.append(f"{f.relative_to(ROOT)}: marker {up} has no row in UPSTREAM_PATCHES.md")
    for up, kind in applied.items():
        if kind == "access":
            continue
        if up not in seen:
            errors.append(f"UPSTREAM_PATCHES.md row {up} has no marker in any vendored file")
    for top in ("App", "Packages", "relay", "site", "catalog"):
        for f in (ROOT / top).rglob("*"):
            if f.is_file() and f.suffix in (".swift", ".py", ".ts", ".js", ".m", ".h") and OPEN.search(f.read_text(errors="ignore")):
                errors.append(f"{f.relative_to(ROOT)}: ANTICHAT-PATCH marker outside Vendor/")
    for e in errors:
        print(e)
    print(f"patch-lint: {checked} files, {changed} patched, {sum(seen.values())} blocks, "
          f"{len(applied)} rows, {len(errors)} error(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
