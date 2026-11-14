#!/usr/bin/env python3
"""AT-273 check 5 (second half) / AT-275: re-open every produced DOCX / XLSX / PPTX with python-docx / openpyxl /
python-pptx from tools/uv.lock (schema-level check, blueprint C R-NEW-FILES-4 AC5) and every PDF with pypdf.

  tools/.venv/bin/python3 -I tools/at/fileout-reopen.py <dir> [--out <json>]
Exit 1 if any file fails to open.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys


def check(p: pathlib.Path) -> tuple[bool, str]:
    ext = p.suffix.lower()
    try:
        if ext == ".docx":
            import docx
            d = docx.Document(str(p))
            return True, f"{len(d.paragraphs)} paragraphs, {len(d.tables)} tables"
        if ext == ".xlsx":
            import openpyxl
            wb = openpyxl.load_workbook(str(p))
            return True, ", ".join(f"{ws.title}:{ws.max_row}x{ws.max_column}" for ws in wb.worksheets)
        if ext == ".pptx":
            import pptx
            pr = pptx.Presentation(str(p))
            return True, f"{len(pr.slides)} slides"
        if ext == ".pdf":
            import pypdf
            r = pypdf.PdfReader(str(p))
            return True, f"{len(r.pages)} pages"
    except Exception as e:  # noqa: BLE001 — any failure is the finding
        return False, f"{type(e).__name__}: {e}"
    return True, "skipped"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--out")
    a = ap.parse_args()
    rows = []
    for p in sorted(pathlib.Path(a.dir).iterdir()):
        if p.suffix.lower() in (".docx", ".xlsx", ".pptx", ".pdf"):
            ok, detail = check(p)
            rows.append({"file": p.name, "ok": ok, "detail": detail})
    bad = [r for r in rows if not r["ok"]]
    out = {"files": len(rows), "ok": len(rows) - len(bad), "failed": bad, "rows": rows}
    if a.out:
        pathlib.Path(a.out).write_text(json.dumps(out, indent=1) + "\n")
    print(f"reopen: {out['ok']}/{out['files']} ok" + (f"; failed: {[b['file'] for b in bad]}" if bad else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
