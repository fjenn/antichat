#!/usr/bin/env python3
"""String Catalog completeness (M9.T04 step 1-2, AT-102). Run with `python3 -I`.

  l10n-check.py --source en                         English: catalog == copy deck (gen-xcstrings --check), plural
                                                    keys exist, no hard-coded user-visible SwiftUI literal
                                                    (Text/Button/Toggle/Label/… with a "…" title outside the catalog;
                                                    `Text(verbatim:)` is the only way to show user content).
  l10n-check.py --langs de,fr,es,nl,pt --require translated
                                                    every deck key translated from today's English, placeholder sets
                                                    identical, plural categories complete per CLDR.
  (--langs also checks the translated help pages under App/AntiChat/Resources/HelpL10n/<lang>/.)
  --report-only                                     print the numbers, exit 0 (the `make audit` mode: tracks landing
                                                    new keys after M9 show up as untranslated without failing audit;
                                                    the strict run is the AT-102 gate at M9.T10).
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import l10n_common as L  # noqa: E402

LITERAL = re.compile(r'(?<![\w.])(Text|Button|Toggle|Label|Menu|Section|TextField|SecureField|Picker|LabeledContent|'
                     r'navigationTitle|help)\(\s*"([^"\\]*[A-Za-z][^"\\]*)"')
SCOPES = ("Packages/UI/Sources/", "Packages/Design/Sources/", "App/AntiChat/")
SKIP = re.compile(r"(Probe|Bench[A-Za-z+]*|Spike[A-Za-z]*)\.swift$|/Spike/|#Preview")
KEYLIKE = re.compile(r"^[a-z][A-Za-z0-9]*(\.[A-Za-z0-9{}]+)+$")


def source_check() -> list[str]:
    errs: list[str] = []
    r = subprocess.run([sys.executable, "-I", str(L.ROOT / "tools/design/gen-xcstrings.py"), "--check"],
                       capture_output=True, text=True)
    if r.returncode:
        errs.append("catalog stale vs copy deck: " + r.stdout.strip().splitlines()[0] if r.stdout else "catalog stale")
    d = L.deck()
    for k in L.plurals()["keys"]:
        if k not in d:
            errs.append(f"tools/l10n/plurals.json: '{k}' is not a copy-deck key")
    out = subprocess.run(["git", "-C", str(L.ROOT), "ls-files", "*.swift"], capture_output=True, text=True).stdout
    for rel in out.split():
        if not rel.startswith(SCOPES) or SKIP.search(rel):
            continue
        in_preview = False
        for i, line in enumerate((L.ROOT / rel).read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if line.startswith("#Preview"):
                in_preview = True
            if in_preview:
                continue
            code = line.split("//", 1)[0]
            for m in LITERAL.finditer(code):
                s = m.group(2)
                if KEYLIKE.match(s):  # a copy key spelled as a literal: still a catalog lookup gap
                    errs.append(f"{rel}:{i}: '{s}' passed as a literal; use CopyKey(\"{s}\")")
                else:
                    errs.append(f"{rel}:{i}: hard-coded user-visible string \"{s}\" (add a copy-deck key)")
    return errs


HELP = L.ROOT / "App/AntiChat/Resources/Help"
HELP_L10N = L.ROOT / "App/AntiChat/Resources/HelpL10n"
HELP_DOCS = ["guide.md", "uninstall.md"]


def _help_shape(text: str) -> tuple[list[str], int, int]:
    ticks = sorted(re.findall(r"`([^`]+)`", text))
    heads = sum(1 for line in text.splitlines() if line.startswith("#"))
    items = sum(1 for line in text.splitlines() if re.match(r"\s*([-*]|\d+\.)\s", line))
    return ticks, heads, items


def _sha(path: Path) -> str:
    import hashlib
    return hashlib.sha256(path.read_bytes()).hexdigest()[:16]


def help_check(langs: list[str]) -> list[str]:
    """Translated help pages (HelpL10n/<lang>/): present, same backticked tokens / headings / list items as the
    English page, and made from today's English (sources.json holds the English sha256 prefix per page)."""
    errs: list[str] = []
    man = HELP_L10N / "sources.json"
    sources = json.loads(man.read_text(encoding="utf-8")) if man.exists() else {}
    for doc in HELP_DOCS:
        en = (HELP / doc).read_text(encoding="utf-8")
        if sources.get(doc) != _sha(HELP / doc):
            errs.append(f"help {doc}: English changed since translation (update HelpL10n/*/{doc}, then sources.json)")
        for lang in langs:
            f = HELP_L10N / lang / doc
            if not f.exists():
                errs.append(f"help {lang}/{doc}: missing"); continue
            a, b = _help_shape(en), _help_shape(f.read_text(encoding="utf-8"))
            for name, x, y in zip(("backticked tokens", "headings", "list items"), a, b):
                if x != y:
                    errs.append(f"help {lang}/{doc}: {name} differ from English")
    return errs


def lang_check(langs: list[str]) -> tuple[list[str], dict]:
    d, pl = L.deck(), L.plurals()
    errs: list[str] = []
    stats = {}
    for lang in langs:
        tr = L.load(lang)
        missing = [k for k in d if k not in tr]
        stale = [k for k in d if k in tr and tr[k].get("en") != d[k][0]]
        extra = [k for k in tr if k not in d]
        bad = []
        for k, e in tr.items():
            if k in d:
                bad += L.validate_entry(k, d[k][0], {c: v for c, v in e.items() if c != "en"}, lang, pl)
        stats[lang] = {"keys": len(d), "translated": len(d) - len(missing) - len(stale), "missing": len(missing),
                       "needs_review": len(stale), "unknown": len(extra), "invalid": len(bad)}
        errs += [f"{lang}: missing {k}" for k in missing]
        errs += [f"{lang}: needs_review {k} (English changed since translation)" for k in stale]
        errs += [f"{lang}: unknown key {k}" for k in extra]
        errs += [f"{lang}: {b}" for b in bad]
    return errs, stats


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source")
    ap.add_argument("--langs")
    ap.add_argument("--require", default="translated")
    ap.add_argument("--report-only", action="store_true")
    a = ap.parse_args()
    errs: list[str] = []
    stats: dict = {}
    if a.source or not a.langs:
        e = source_check()
        errs += e
        stats["en"] = {"source_problems": len(e)}
    if a.langs:
        langs = [x for x in a.langs.split(",") if x]
        e, s = lang_check(langs)
        h = help_check(langs)
        errs += e + h
        stats.update(s)
        stats["help_problems"] = len(h)
    for x in errs[:200]:
        print(x)
    if len(errs) > 200:
        print(f"… {len(errs) - 200} more")
    print(f"l10n-check: {'FAIL ' + str(len(errs)) if errs else 'ok'} {json.dumps(stats)}")
    return 0 if a.report_only or not errs else 1


if __name__ == "__main__":
    sys.exit(main())
