#!/usr/bin/env python3
"""Settings keys vs settings-map (docs/prd/M1.md M1.T22 step 7; R-100 AC2). Run with `python3 -I` (stdlib only).

Every key in Packages/UI/Sources/AntiChatUI/Settings/Keys.swift carries one annotation line

    // settings-map: §<n> "<Setting column>" = "<Default column>" ↔ <Swift default literal>

directly above its `static let <name> = Key<T>("<name>", default: <literal>, …)`. The check fails when
  * a key has no annotation, or its `Key("…")` name differs from the property name;
  * the annotated Swift default differs from the `default:` literal;
  * docs/research/02-target/settings-map.md has no row "<Setting>" in section §<n>, or that row's Default
    column is not exactly "<Default column>";
and, the other way round, when a P0 row of the M1 scope below (the rows M1 delivers) has no key.

  --root <dir>   repository root (tests)
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

KEYS = "Packages/UI/Sources/AntiChatUI/Settings/Keys.swift"
MAP = "docs/research/02-target/settings-map.md"

# Rows of settings-map that M1 delivers as keys (M1.T22 steps 3-5). Later tasks add theirs here with their keys.
M1_SCOPE = {
    1: ["Send with", "Plain-text composer", "Show context usage", "Launch at login", "Menu bar item"],
    2: ["Color mode", "Accent color", "Chat font", "Text size", "Reading width", "Reduce motion",
        "Reduce transparency", "Increase contrast"],
    3: ["→ Show model info (key `showModelInfo`; A-M1-T25c)",
        "→ Keep models loaded after last use (keep-alive)", "→ Allow loads above the memory budget"],  # M2.T07
    5: ["Microphone", "Spoken language", "Voice", "Speed", "Conversation mode"],  # M3.T08
    6: ["About you", "How should AntiChat respond", "Style preset",
        "Characteristics (warmth, enthusiasm, headers/lists, emoji)"],
    7: ["→ Suggest web search when helpful (if off)",  # M7.T05
        "Create image / Create video / Create files / Memory", "Tool access"],  # M7.T14
    9: ["Auto-archive inactive chats"],
    11: ["Update models automatically"],  # M2.T11
}

ANNOT = re.compile(r'^\s*//\s*settings-map:\s*§(\d+)\s+"([^"]+)"\s*=\s*"([^"]*)"\s*↔\s*(.+?)\s*$')
KEY = re.compile(r'^\s*static let (\w+)\s*=\s*Key<[^>]+>\("([^"]+)",\s*default:\s*(.+?),\s*suite:')


def parse_map(text: str) -> dict[int, dict[str, str]]:
    """{section number: {Setting: Default}} from the `### n. Title` tables."""
    out: dict[int, dict[str, str]] = {}
    section = None
    for line in text.splitlines():
        m = re.match(r"^###\s+(\d+)\.\s", line)
        if m:
            section = int(m.group(1))
            out.setdefault(section, {})
            continue
        if line.startswith("## "):
            section = None
            continue
        if section is None or not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 2 or cells[0] in ("Setting", "") or set(cells[0]) <= set("-: "):
            continue
        name = cells[0].replace("**", "").strip()
        out[section][name] = cells[1].strip()
    return out


def parse_keys(text: str) -> tuple[list[dict], list[str]]:
    keys: list[dict] = []
    errors: list[str] = []
    pending = None
    for i, line in enumerate(text.splitlines(), 1):
        a = ANNOT.match(line)
        if a:
            pending = {"section": int(a.group(1)), "setting": a.group(2), "default": a.group(3),
                       "swift": a.group(4), "line": i}
            continue
        k = KEY.match(line)
        if k:
            prop, name, literal = k.group(1), k.group(2), k.group(3).strip()
            if prop != name:
                errors.append(f"{KEYS}:{i}: property {prop} stores key {name!r}")
            if pending is None:
                errors.append(f"{KEYS}:{i}: key {name} has no `// settings-map:` annotation")
            else:
                if pending["swift"] != literal:
                    errors.append(f"{KEYS}:{i}: {name} default {literal} but annotation says {pending['swift']}")
                keys.append({"name": name, **pending})
            pending = None
            continue
        if line.strip() and not line.strip().startswith("//"):
            pending = None if not line.strip().startswith("///") else pending
    return keys, errors


def check(root: Path) -> tuple[list[str], int]:
    """(errors, number of annotated keys)."""
    smap = parse_map((root / MAP).read_text(encoding="utf-8"))
    keys, errors = parse_keys((root / KEYS).read_text(encoding="utf-8"))
    for k in keys:
        rows = smap.get(k["section"])
        if rows is None:
            errors.append(f"{k['name']}: settings-map has no section §{k['section']}")
            continue
        if k["setting"] not in rows:
            errors.append(f"{k['name']}: settings-map §{k['section']} has no row {k['setting']!r}")
            continue
        if rows[k["setting"]] != k["default"]:
            errors.append(f"{k['name']}: settings-map §{k['section']} {k['setting']!r} default is "
                          f"{rows[k['setting']]!r}, Keys.swift says {k['default']!r}")
    covered = {(k["section"], k["setting"]) for k in keys}
    for section, settings in M1_SCOPE.items():
        for s in settings:
            if s not in smap.get(section, {}):
                errors.append(f"M1 scope row §{section} {s!r} is not in settings-map")
            elif (section, s) not in covered:
                errors.append(f"settings-map §{section} {s!r} (M1, P0) has no key in Keys.swift")
    return errors, len(keys)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    args = ap.parse_args()
    errors, n = check(Path(args.root))
    for e in errors:
        print(f"error: {e}")
    print(f"settings-map-check: {n} keys, {sum(len(v) for v in M1_SCOPE.values())} M1 rows, {len(errors)} error(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
