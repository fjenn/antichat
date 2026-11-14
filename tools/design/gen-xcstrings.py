#!/usr/bin/env python3
"""Copy pipeline generator (docs/prd/M1.md M1.T03 step 5). Run with `python3 -I` (stdlib only).

Source of truth: docs/research/10-architecture/design-system/copy-deck.md. Every table row whose first column
holds backticked keys and whose table has a `String` column becomes one catalog entry per key:
  * `a.b` / `.c` / `a.d` key shorthand expands like tools/ci/copy-sync.py (same key set, checked there);
  * a multi-key row splits its string on " / " into one part per key; a row whose string has no " / " gives
    every key the same string (`relay.overCapacity` / `relay.disabled`); any other count mismatch fails.
Writes, deterministically (sorted keys, source language en, extractionState manual):
  App/AntiChat/Localizable.xcstrings
  Packages/Design/Sources/AntiChatDesign/Copy/CopyDeck.swift   (English fallback table for `CopyKey`)
Placeholders stay in the deck's `{name}` form; `CopyKey.string(_:)` substitutes them.
M9.T04: translations (docs/research/10-architecture/design-system/translations/<lang>.json, tools/l10n/l10n_common.py)
are merged per key: state `translated` when the entry was made from today's English, `needs_review` when the English
changed since. Plural keys (tools/l10n/plurals.json) become plural variations in every language with the count
placeholder written as `%lld` (CopyKey formats them); CopyDeck.swift also gets the plural arg + English singular.

  --check   exit 1 if a generated file differs from the tree.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DECK = ROOT / "docs/research/10-architecture/design-system/copy-deck.md"
XCSTRINGS = ROOT / "App/AntiChat/Localizable.xcstrings"
SWIFT = ROOT / "Packages/Design/Sources/AntiChatDesign/Copy/CopyDeck.swift"
KEY = r"[a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9{}]+)+"


class GenError(Exception):
    pass


def cells(line: str) -> list[str]:
    return [c.strip() for c in line.strip().strip("|").split("|")]


def row_keys(cell: str) -> list[str]:
    out: list[str] = []
    for tok in re.findall(r"`([^`]+)`", cell):
        if tok.startswith(".") and out:
            out.append(out[-1].rsplit(".", 1)[0] + tok)
        elif re.fullmatch(KEY, tok):
            out.append(tok)
    return out


def clean(s: str) -> str:
    s = s.strip()
    if "`" in s or "**" in s:
        raise GenError(f"markdown in copy string {s!r}")
    return s


def parse(text: str) -> dict[str, tuple[str, int]]:
    out: dict[str, tuple[str, int]] = {}
    col = None
    for i, line in enumerate(text.splitlines(), 1):
        if not line.startswith("|"):
            col = None if not line.strip() else col
            continue
        c = cells(line)
        if all(re.fullmatch(r":?-{3,}:?", x) for x in c):
            continue
        if col is None:  # header row of a new table
            col = c.index("String") if "String" in c else -1
            continue
        if col < 0:
            continue
        keys = row_keys(c[0])
        if not keys:
            continue
        value = c[col]
        parts = [p.strip() for p in value.split(" / ")] if len(keys) > 1 else [value]
        if len(keys) > 1 and len(parts) == 1:
            parts = parts * len(keys)
        if len(parts) != len(keys):
            raise GenError(f"{DECK.name}:{i}: {len(keys)} keys but {len(parts)} strings in {value!r}")
        for k, v in zip(keys, parts):
            if k in out:
                raise GenError(f"{DECK.name}:{i}: duplicate key {k} (first at line {out[k][1]})")
            out[k] = (clean(v), i)
    return out


def _l10n():
    sys.path.insert(0, str(ROOT / "tools/l10n"))
    import l10n_common  # noqa: E402
    return l10n_common


def _unit(state: str, value: str) -> dict:
    return {"stringUnit": {"state": state, "value": value}}


def _plural(arg: str, forms: dict[str, str], state: str) -> dict:
    return {"variations": {"plural": {c: _unit(state, v.replace("{" + arg + "}", "%lld")) for c, v in forms.items()}}}


def xcstrings(entries: dict[str, tuple[str, int]]) -> str:
    L = _l10n()
    pl = L.plurals()
    langs = {lang: L.load(lang) for lang in L.LANGS}
    strings = {}
    for k in sorted(entries):
        en = entries[k][0]
        pk = pl["keys"].get(k)
        locs = {"en": _plural(pk["arg"], {"one": pk["en"]["one"], "other": en}, "translated") if pk
                else _unit("translated", en)}
        for lang, tr in langs.items():
            t = tr.get(k)
            if not t:
                continue
            state = "translated" if t.get("en") == en else "needs_review"
            if pk:
                forms = {c: t[c] for c in pl["categories"][lang] if t.get(c)}
                if forms:
                    locs[lang] = _plural(pk["arg"], forms, state)
            elif t.get("value"):
                locs[lang] = _unit(state, t["value"])
        strings[k] = {"extractionState": "manual", "localizations": locs}
    doc = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    return json.dumps(doc, indent=2, ensure_ascii=False, sort_keys=True) + "\n"


def swift(entries: dict[str, tuple[str, int]]) -> str:
    def lit(s: str) -> str:
        return s.replace("\\", "\\\\").replace('"', '\\"')
    lines = ["// GENERATED by tools/design/gen-xcstrings.py from docs/research/10-architecture/design-system/copy-deck.md.",
             "// Do not edit: change copy-deck.md and run `make design-gen`.", "",
             "/// English source strings (copy-deck.md). `CopyKey.string` looks the key up in the app's",
             "/// Localizable.xcstrings first (translations, P1) and falls back to this table (package tests, previews).",
             "enum CopyDeck {",
             f"    static let count = {len(entries)}", "",
             "    static let english: [String: String] = ["]
    for k in sorted(entries):
        lines.append(f'        "{k}": "{lit(entries[k][0])}",')
    lines += ["    ]", ""]
    pl = _l10n().plurals()["keys"]
    lines += ["    /// Count strings (tools/l10n/plurals.json): key → (placeholder carrying the number, English singular).",
              "    static let plurals: [String: (arg: String, one: String)] = ["]
    for k in sorted(pl):
        if k in entries:
            lines.append(f'        "{k}": ("{pl[k]["arg"]}", "{lit(pl[k]["en"]["one"])}"),')
    lines += ["    ]", "}"]
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    try:
        entries = parse(DECK.read_text(encoding="utf-8"))
    except GenError as e:
        print(f"gen-xcstrings: {e}", file=sys.stderr)
        return 1
    files = {XCSTRINGS: xcstrings(entries), SWIFT: swift(entries)}
    if a.check:
        diff = [p for p, c in files.items() if not p.exists() or p.read_text(encoding="utf-8") != c]
        for p in diff:
            print(f"gen-xcstrings: stale {p.relative_to(ROOT)}")
        print(f"gen-xcstrings --check: {'FAIL' if diff else 'ok'} ({len(entries)} keys)")
        return 1 if diff else 0
    for p, c in files.items():
        p.parent.mkdir(parents=True, exist_ok=True)
        if not p.exists() or p.read_text(encoding="utf-8") != c:
            p.write_text(c, encoding="utf-8")
    print(f"gen-xcstrings: ok ({len(entries)} keys)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
