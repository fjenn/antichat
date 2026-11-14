"""Shared helpers for the localisation tools (M9.T04). Stdlib only; imported by tools/l10n/*.py and
tools/design/gen-xcstrings.py.

Sources of truth:
  * English: docs/research/10-architecture/design-system/copy-deck.md (parsed by gen-xcstrings.parse);
  * translations: docs/research/10-architecture/design-system/translations/<lang>.json, one file per language:
      {"language": "de", "strings": {"<key>": {"en": "<English it was translated from>", "value": "<text>"}}}
    a plural key (tools/l10n/plurals.json) carries one entry per CLDR category instead of "value":
      {"en": "...", "one": "...", "other": "..."}   (fr/es/pt also "many")
  * plural keys and their English singular: tools/l10n/plurals.json.
A translation whose "en" differs from today's deck string is stale (state needs_review in the catalog).
"""
from __future__ import annotations

import importlib.util
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TRANSLATIONS = ROOT / "docs/research/10-architecture/design-system/translations"
PLURALS = ROOT / "tools/l10n/plurals.json"
GLOSSARY = ROOT / "tools/l10n/glossary.csv"
LANGS = ["de", "fr", "es", "nl", "pt"]
PLACEHOLDER = re.compile(r"\{([A-Za-z0-9_]+)\}")


def _gen():
    spec = importlib.util.spec_from_file_location("gen_xcstrings", ROOT / "tools/design/gen-xcstrings.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def deck() -> dict[str, tuple[str, int]]:
    """key → (English, copy-deck line)."""
    g = _gen()
    return g.parse(g.DECK.read_text(encoding="utf-8"))


def deck_sections() -> dict[int, str]:
    """copy-deck line → the `## n. Title` heading above it."""
    g = _gen()
    out, cur = {}, ""
    for i, line in enumerate(g.DECK.read_text(encoding="utf-8").splitlines(), 1):
        if line.startswith("## "):
            cur = line[3:].strip()
        out[i] = cur
    return out


def deck_rows() -> dict[int, str]:
    g = _gen()
    return dict(enumerate(g.DECK.read_text(encoding="utf-8").splitlines(), 1))


def plurals() -> dict:
    return json.loads(PLURALS.read_text(encoding="utf-8"))


def load(lang: str) -> dict[str, dict]:
    p = TRANSLATIONS / f"{lang}.json"
    if not p.exists():
        return {}
    return json.loads(p.read_text(encoding="utf-8")).get("strings", {})


def save(lang: str, strings: dict[str, dict]) -> None:
    TRANSLATIONS.mkdir(parents=True, exist_ok=True)
    doc = {"language": lang, "strings": {k: strings[k] for k in sorted(strings)}}
    (TRANSLATIONS / f"{lang}.json").write_text(
        json.dumps(doc, indent=1, ensure_ascii=False, sort_keys=False) + "\n", encoding="utf-8")


def placeholders(s: str) -> set[str]:
    return set(PLACEHOLDER.findall(s))


def validate_entry(key: str, en: str, entry: dict, lang: str, pl: dict) -> list[str]:
    """Problems with one translation entry (empty list = fine)."""
    errs: list[str] = []
    want = placeholders(en)
    pk = pl["keys"].get(key)
    if pk:
        cats = pl["categories"][lang]
        missing = [c for c in cats if not entry.get(c)]
        extra = [c for c in entry if c not in cats + ["en", "value"]]
        if missing:
            errs.append(f"{key}: plural forms missing {missing}")
        if extra:
            errs.append(f"{key}: unknown plural forms {extra}")
        for c in cats:
            v = entry.get(c) or ""
            got = placeholders(v)
            # 'one' may spell the number out ("Only the last turn…"); every other form keeps every placeholder.
            if c == "other" and got != want:
                errs.append(f"{key}[{c}]: placeholders {sorted(got)} != English {sorted(want)}")
            elif c != "other" and not got <= want:
                errs.append(f"{key}[{c}]: unknown placeholders {sorted(got - want)}")
            if "%" in v:
                errs.append(f"{key}[{c}]: '%' is not allowed in a plural form (it is a format string)")
    else:
        v = entry.get("value")
        if not isinstance(v, str) or not v.strip():
            errs.append(f"{key}: empty translation")
        elif placeholders(v) != want:
            errs.append(f"{key}: placeholders {sorted(placeholders(v))} != English {sorted(want)}")
    return errs
