#!/usr/bin/env python3
"""AT-276 check 1 (M6.T20, R-276 AC1): did an in-place Office edit make the requested change AND keep every style
of what it did not touch?

  tools/.venv/bin/python3 -I tools/at/office-style-diff.py --orig fixtures/docs/office/edit-inplace \
      --edited build/at/AT-276/<date>/out --spec fixtures/docs/office/edit-inplace/edit-inplace.jsonl \
      --out build/at/AT-276/<date>/style.json

`--edited` holds one folder per instruction id: `<edited>/<id>/<file>` (the edited copy, same name as the original).
Per instruction the result is {change, invariants, pass, problems[]}; the summary has `passed` / `total` and
`gate` = passed >= 8 of 9 (AT-276 check 1). A missing edited file is a fail, never a skip.

Invariants (M6.T20 step 3):
  XLSX  every cell of the untouched range (minus `except`): value, font (name, size, bold, italic, colour), fill,
        number format, bottom border, horizontal alignment; column widths A-D; freeze panes; sheet names; the Notes
        sheet's merged range and its A1 font.
  DOCX  every original paragraph (minus `except` indices) still present, in order, same text and style name; section
        margins and header text; the custom "Callout" style (italic, size, colour); Normal's font name and size.
  PPTX  slide size; master/layout names; every original slide keeps its layout, title (minus `except_titles`) and
        body text (minus `except_bodies`).
Stdlib + openpyxl / python-docx / python-pptx (tools/pyproject.toml pins).
"""
from __future__ import annotations

import argparse
import json
import os
import sys

from openpyxl.utils import column_index_from_string, range_boundaries


def _color(c):
    if c is None:
        return None
    return getattr(c, "rgb", None) if getattr(c, "type", None) == "rgb" else (getattr(c, "type", None), getattr(c, "theme", None))


def _cell_style(c):
    f = c.font
    return {
        "value": c.value if not hasattr(c.value, "isoformat") else c.value.isoformat(),
        "font": (f.name, float(f.sz or 0), bool(f.b), bool(f.i), _color(f.color)),
        "fill": (c.fill.fill_type, _color(c.fill.fgColor)),
        "number_format": c.number_format,
        "border_bottom": c.border.bottom.style if c.border and c.border.bottom else None,
        "align": c.alignment.horizontal if c.alignment else None,
    }


def xlsx_invariants(orig_path, edited_path, spec):
    import openpyxl

    problems = []
    o, e = openpyxl.load_workbook(orig_path), openpyxl.load_workbook(edited_path)
    for name in o.sheetnames:
        if name not in e.sheetnames:
            problems.append(f"sheet {name} missing")
    if problems:
        return problems
    u = spec["untouched"]
    os_, es = o[u["sheet"]], e[u["sheet"]]
    skip = set(u.get("except", []))
    min_col, min_row, max_col, max_row = range_boundaries(u["range"])
    for row in range(min_row, max_row + 1):
        for col in range(min_col, max_col + 1):
            ref = f"{os_.cell(row=row, column=col).column_letter}{row}"
            if ref in skip:
                # the changed cell must keep its style even though its value changed
                a, b = _cell_style(os_[ref]), _cell_style(es[ref])
                a.pop("value"), b.pop("value")
                if a != b:
                    problems.append(f"{ref} style changed: {a} -> {b}")
                continue
            a, b = _cell_style(os_[ref]), _cell_style(es[ref])
            if a != b:
                diff = {k: (a[k], b[k]) for k in a if a[k] != b[k]}
                problems.append(f"{ref}: {diff}")
    for col in "ABCD":
        wa, wb = os_.column_dimensions[col].width, es.column_dimensions[col].width
        if round(wa or 0, 2) != round(wb or 0, 2):
            problems.append(f"column {col} width {wa} -> {wb}")
    if os_.freeze_panes != es.freeze_panes:
        problems.append(f"freeze panes {os_.freeze_panes} -> {es.freeze_panes}")
    if "Notes" in o.sheetnames:
        on, en = o["Notes"], e["Notes"]
        if sorted(map(str, on.merged_cells.ranges)) != sorted(map(str, en.merged_cells.ranges)):
            problems.append("Notes merged cells changed")
        if _cell_style(on["A1"]) != _cell_style(en["A1"]):
            problems.append("Notes!A1 changed")
    return problems


def _num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def xlsx_check(orig_path, edited_path, chk):
    import openpyxl

    e = openpyxl.load_workbook(edited_path)
    ws = e[chk["sheet"]]
    t = chk["type"]
    if t == "xlsx_cells":
        bad = []
        for ref, want in chk["cells"].items():
            v = ws[ref].value
            ok = (_num(v) is not None and abs(_num(v) - want) < 0.01) if isinstance(want, (int, float)) else str(v).strip() == want
            if not ok:
                bad.append(f"{ref} = {v!r}, want {want!r}")
        return bad
    if t == "xlsx_cell":
        v = ws[chk["cell"]].value
        return [] if str(v).strip() == chk["equals"] else [f"{chk['cell']} = {v!r}, want {chk['equals']!r}"]
    if t == "xlsx_total_row":
        o = openpyxl.load_workbook(orig_path)[chk["sheet"]]
        lo, hi = chk["sum_range"][1:].split(":")
        col = chk["value_col"]
        want = sum(_num(o[f"{col}{r}"].value) or 0 for r in range(int(lo), int(hi[1:]) + 1))
        for r in range(chk["after_row"] + 1, chk["after_row"] + 4):
            label = ws[f"{chk['label_col']}{r}"].value
            if label is not None and "total" in str(label).lower():
                v = ws[f"{col}{r}"].value
                if isinstance(v, str) and v.upper().replace(" ", "").startswith(f"=SUM({col}2:{col}{chk['after_row']})"):
                    return []
                if _num(v) is not None and abs(_num(v) - want) < 0.01:
                    return []
                return [f"total row {r}: {v!r}, want {want:.2f} or =SUM({col}2:{col}{chk['after_row']})"]
        return ["no Total row under the data"]
    if t == "xlsx_new_column":
        col, src = chk["col"], chk["of_col"]
        problems = []
        if str(ws[f"{col}1"].value).strip().lower() != chk["header"].lower():
            problems.append(f"{col}1 = {ws[f'{col}1'].value!r}")
        o = openpyxl.load_workbook(orig_path)[chk["sheet"]]
        for r in range(chk["rows"][0], chk["rows"][1] + 1):
            v = ws[f"{col}{r}"].value
            base = _num(o[f"{src}{r}"].value) or 0
            if isinstance(v, str) and v.startswith("=") and src in v.upper():
                continue
            if _num(v) is None or abs(_num(v) - base * chk["factor"]) > 0.01:
                problems.append(f"{col}{r} = {v!r}, want {base * chk['factor']:.2f}")
        return problems
    return [f"unknown check {t}"]


def _paras(d):
    return [(p.text, p.style.name if p.style is not None else None) for p in d.paragraphs]


def docx_invariants(orig_path, edited_path, spec):
    import docx

    problems = []
    o, e = docx.Document(orig_path), docx.Document(edited_path)
    skip = set(spec["untouched"].get("except", []))
    want = [p for i, p in enumerate(_paras(o)) if i not in skip]
    have = _paras(e)
    j = 0
    for text, style in want:
        while j < len(have) and have[j] != (text, style):
            j += 1
        if j == len(have):
            problems.append(f"original paragraph lost or restyled: {text[:40]!r} ({style})")
            j = 0
        else:
            j += 1
    if skip:  # the changed paragraphs keep their style
        for i in skip:
            os_, es_ = o.paragraphs[i].style.name, e.paragraphs[i].style.name if i < len(e.paragraphs) else None
            if os_ != es_:
                problems.append(f"paragraph {i} style {os_} -> {es_}")
    so, se = o.sections[0], e.sections[0]
    for attr in ("left_margin", "right_margin", "top_margin", "bottom_margin", "page_width", "page_height"):
        if getattr(so, attr) != getattr(se, attr):
            problems.append(f"section {attr} changed")
    if so.header.paragraphs[0].text != se.header.paragraphs[0].text:
        problems.append("header text changed")
    names = {st.name for st in e.styles}
    for oc in o.styles:  # every style of the original (built-in and custom, e.g. "Callout") survives unchanged
        if oc.name not in names:
            problems.append(f"style {oc.name} missing")
            continue
        if oc.type == 1:  # paragraph styles: font face/size/italic/bold/colour
            c = e.styles[oc.name]
            fa = (oc.font.name, oc.font.size, oc.font.italic, oc.font.bold, oc.font.color.rgb if oc.font.color and oc.font.color.type else None)
            fb = (c.font.name, c.font.size, c.font.italic, c.font.bold, c.font.color.rgb if c.font.color and c.font.color.type else None)
            if fa != fb:
                problems.append(f"style {oc.name} changed")
    n_o, n_e = o.styles["Normal"].font, e.styles["Normal"].font
    if (n_o.name, n_o.size) != (n_e.name, n_e.size):
        problems.append(f"Normal font {n_o.name}/{n_o.size} -> {n_e.name}/{n_e.size}")
    return problems


def docx_check(orig_path, edited_path, chk):
    import docx

    e = docx.Document(edited_path)
    paras = [p for p in e.paragraphs if p.text.strip()]
    t = chk["type"]
    if t == "docx_paragraph":
        last = paras[-1].text if paras else ""
        return [] if chk["contains"].lower() in last.lower() else [f"last paragraph is {last[:60]!r}"]
    if t == "docx_title":
        titles = [p.text for p in e.paragraphs if p.style is not None and p.style.name == "Title"]
        return [] if titles and titles[0].strip() == chk["equals"] else [f"title is {titles[:1]!r}"]
    if t == "docx_has_paragraph":
        for q in paras:
            if q.text.strip() == chk["text"] and q.style is not None and q.style.name.startswith(chk.get("style_prefix", "")):
                return []
        return [f"no {chk.get('style_prefix', '')} paragraph {chk['text']!r}"]
    if t == "docx_heading":
        for i, p in enumerate(paras):
            if p.text.strip().lower() == chk["text"].lower() and p.style is not None and p.style.name.startswith("Heading"):
                rest = [q.text.strip().lower().rstrip(".") for q in paras[i + 1:i + 1 + len(chk["followed_by"])]]
                if rest == [x.lower() for x in chk["followed_by"]]:
                    return []
                return [f"after the heading: {rest}"]
        return [f"no heading {chk['text']!r}"]
    return [f"unknown check {t}"]


def _slide(s):
    title = s.shapes.title.text if s.shapes.title is not None else None
    body = [sh.text_frame.text for sh in s.placeholders if sh.has_text_frame and sh != s.shapes.title]
    return s.slide_layout.name, title, body


def pptx_invariants(orig_path, edited_path, spec):
    from pptx import Presentation

    problems = []
    o, e = Presentation(orig_path), Presentation(edited_path)
    if (o.slide_width, o.slide_height) != (e.slide_width, e.slide_height):
        problems.append("slide size changed")
    lo = [m.name for m in o.slide_layouts]
    le = [m.name for m in e.slide_layouts]
    if lo != le:
        problems.append(f"layouts {lo} -> {le}")
    u = spec["untouched"]
    et, eb = set(u.get("except_titles", [])), set(u.get("except_bodies", []))
    es = list(e.slides)
    for i, s in enumerate(o.slides, start=1):
        if i > len(es):
            problems.append(f"slide {i} missing")
            continue
        (la, ta, ba), (lb, tb, bb) = _slide(s), _slide(es[i - 1])
        if la != lb:
            problems.append(f"slide {i} layout {la} -> {lb}")
        if i not in et and ta != tb:
            problems.append(f"slide {i} title {ta!r} -> {tb!r}")
        if i not in eb and ba != bb:
            problems.append(f"slide {i} body changed")
        if i in eb and not all(line in "\n".join(bb) for line in "\n".join(ba).split("\n")):
            problems.append(f"slide {i} lost original bullets")
    return problems


def pptx_check(orig_path, edited_path, chk):
    from pptx import Presentation

    e = Presentation(edited_path)
    slides = list(e.slides)
    t = chk["type"]
    if t == "pptx_title":
        s = slides[chk["slide"] - 1]
        got = s.shapes.title.text if s.shapes.title is not None else None
        return [] if (got or "").strip() == chk["equals"] else [f"slide {chk['slide']} title {got!r}"]
    if t == "pptx_new_slide":
        if len(slides) != chk["count"]:
            return [f"{len(slides)} slides, want {chk['count']}"]
        s = slides[-1]
        got = s.shapes.title.text if s.shapes.title is not None else " ".join(sh.text_frame.text for sh in s.shapes if sh.has_text_frame)
        return [] if chk["title"].lower() in (got or "").lower() else [f"last slide title {got!r}"]
    if t == "pptx_text":
        s = slides[chk["slide"] - 1]
        text = "\n".join(sh.text_frame.text for sh in s.shapes if sh.has_text_frame)
        return [] if chk["contains"].lower() in text.lower() else [f"slide {chk['slide']} text {text[:80]!r}"]
    return [f"unknown check {t}"]


KINDS = {"xlsx": (xlsx_check, xlsx_invariants), "docx": (docx_check, docx_invariants), "pptx": (pptx_check, pptx_invariants)}


def evaluate(orig_dir, edited_dir, spec_rows):
    rows = []
    for spec in spec_rows:
        orig = os.path.join(orig_dir, spec["file"])
        edited = os.path.join(edited_dir, spec["id"], spec["file"])
        row = {"id": spec["id"], "file": spec["file"], "instruction": spec["instruction"]}
        if not os.path.exists(edited):
            row.update(change=False, invariants=False, pass_=False, problems=["no edited file"])
        else:
            check, inv = KINDS[spec["file"].rsplit(".", 1)[1]]
            try:
                c = check(orig, edited, spec["check"])
                i = inv(orig, edited, spec)
            except Exception as ex:  # an unreadable file is a fail with the reason
                c, i = [f"unreadable: {ex}"], ["unreadable"]
            row.update(change=not c, invariants=not i, pass_=not c and not i, problems=c + i)
        row["pass"] = row.pop("pass_")
        rows.append(row)
    passed = sum(r["pass"] for r in rows)
    # AT-276 gate: >= 8/9 on the 9-instruction set; any other set (held-out) reports the same ratio (>= 8/9 of its runs).
    return {"passed": passed, "total": len(rows), "gate": bool(rows) and passed * 9 >= 8 * len(rows), "rows": rows}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orig", required=True)
    ap.add_argument("--edited", required=True)
    ap.add_argument("--spec", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    with open(a.spec) as f:
        spec_rows = [json.loads(line) for line in f if line.strip()]
    result = evaluate(a.orig, a.edited, spec_rows)
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w") as f:
        json.dump(result, f, indent=2, sort_keys=True)
    print(f"office-style-diff: {result['passed']}/{result['total']} (gate {'PASS' if result['gate'] else 'FAIL'})")
    return 0 if result["gate"] else 1


if __name__ == "__main__":
    sys.exit(main())
