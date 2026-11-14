#!/usr/bin/env python3
"""Translation work tool (M9.T04, tools/l10n/translate-pass.md). Run with `python3 -I`.

  todo <lang> [--section N] [--all]   JSON list of keys to translate (missing or stale): key, en, section, row
                                      (the copy-deck row, for context), plural categories when the key is plural.
                                      --all lists every key (for a reviewer).
  set <lang> <batch.json>             merge a batch {key: "text"} / {key: {"one": …, "other": …}} into
                                      translations/<lang>.json, stamping today's English; rejects the whole batch
                                      on any placeholder / plural / unknown-key problem.
  dump <lang> [--section N]           JSON list of key, en, current translation (for review).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import l10n_common as L  # noqa: E402


def _rows(lang: str, section: str | None, every: bool):
    d, secs, rows, pl = L.deck(), L.deck_sections(), L.deck_rows(), L.plurals()
    have = L.load(lang)
    out = []
    for k, (en, line) in sorted(d.items(), key=lambda kv: kv[1][1]):
        sec = secs.get(line, "")
        if section and not sec.startswith(section + "."):
            continue
        cur = have.get(k)
        if not every and cur and cur.get("en") == en:
            continue
        item = {"key": k, "en": en, "section": sec, "row": rows[line]}
        if k in pl["keys"]:
            item["plural"] = pl["categories"][lang]
            item["en_one"] = pl["keys"][k]["en"]["one"]
        if cur:
            item["current"] = {c: v for c, v in cur.items() if c != "en"}
        out.append(item)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("todo"); t.add_argument("lang"); t.add_argument("--section"); t.add_argument("--all", action="store_true")
    s = sub.add_parser("set"); s.add_argument("lang"); s.add_argument("batch")
    u = sub.add_parser("dump"); u.add_argument("lang"); u.add_argument("--section")
    a = ap.parse_args()
    if a.lang not in L.LANGS:
        print(f"unknown language {a.lang}; one of {L.LANGS}", file=sys.stderr)
        return 2
    if a.cmd in ("todo", "dump"):
        print(json.dumps(_rows(a.lang, a.section, a.cmd == "dump" or a.all), ensure_ascii=False, indent=1))
        return 0
    d, pl = L.deck(), L.plurals()
    batch = json.loads(Path(a.batch).read_text(encoding="utf-8"))
    have = L.load(a.lang)
    errs = []
    for k, v in batch.items():
        if k not in d:
            errs.append(f"{k}: not a copy-deck key")
            continue
        entry = {"value": v} if isinstance(v, str) else dict(v)
        entry.pop("en", None)
        errs += L.validate_entry(k, d[k][0], entry, a.lang, pl)
        have[k] = {"en": d[k][0], **entry}
    if errs:
        print("\n".join(errs), file=sys.stderr)
        print(f"rejected: {len(errs)} problem(s); nothing written", file=sys.stderr)
        return 1
    L.save(a.lang, have)
    left = len(_rows(a.lang, None, False))
    print(f"{a.lang}: merged {len(batch)}; {left} key(s) still to translate")
    return 0


if __name__ == "__main__":
    sys.exit(main())
