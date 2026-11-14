#!/usr/bin/env python3
"""Spreadsheet fixtures for M6 (M6.T07; M6.T20 adds the styled edit-in-place set to this script):
  --xls        fixtures/docs/office/legacy.xls      BIFF8 (xlwt 1.3.0), 2 sheets, 500 data rows in all:
               Orders (450 rows: order_id int, order_date date, customer text, amount number, shipped bool,
               packed_at date-time) and Staff (50 rows: name text, start_date date, salary number)
  --budget20k  fixtures/docs/office/budget-20k.xlsx  openpyxl, 3 sheets, 20,036 data rows in all: Transactions
               (20,000 rows: txn_id int, date date, category, region, amount number, qty int, reimbursed bool),
               Monthly (24 rows: month date, planned, actual), Categories (12 rows: category, budget, owner)
  --edit-inplace  fixtures/docs/office/edit-inplace/{sales.xlsx, memo.docx, pitch.pptx} + edit-inplace.jsonl (M6.T20,
               AT-276): styled originals (XLSX header font/fill, number formats, column widths, freeze panes, a
               merged notes sheet; DOCX Title/Heading/Normal + a custom "Callout" style, custom margins and a header;
               PPTX three layouts) and 9 edit instructions (3 per file) with the change check and the untouched
               ranges that tools/at/office-style-diff.py compares.
`budget.xlsx` (make-office.py) keeps its small 2-sheet shape: M4.T10/M6.T01 tests pin it.
All values are invented from a fixed seed and released CC0. Reruns are byte-identical.

Usage: tools/.venv/bin/python3 -I tools/fixtures/make-styled-office.py --out fixtures --xls --budget20k --edit-inplace
"""
from __future__ import annotations

import argparse
import datetime as dt
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
from importlib import import_module  # noqa: E402

office_mod = import_module("make-office")
SEED = 20261107
WORDS = office_mod.WORDS
CATEGORIES = ["Rent", "Food", "Travel", "Tools", "Software", "Utilities", "Insurance", "Training", "Marketing",
              "Repairs", "Shipping", "Office"]
REGIONS = ["North", "South", "East", "West"]


def name(rng: random.Random) -> str:
    return f"{rng.choice(WORDS).capitalize()} {rng.choice(WORDS).capitalize()}"


def make_xls(path: str, rng: random.Random) -> None:
    import xlwt

    wb = xlwt.Workbook(encoding="utf-8")
    date_fmt = xlwt.easyxf(num_format_str="YYYY-MM-DD")
    dt_fmt = xlwt.easyxf(num_format_str="YYYY-MM-DD HH:MM:SS")
    money = xlwt.easyxf(num_format_str="#,##0.00")
    orders = wb.add_sheet("Orders")
    for c, h in enumerate(["order_id", "order_date", "customer", "amount", "shipped", "packed_at"]):
        orders.write(0, c, h)
    start = dt.date(2025, 1, 1)
    for r in range(1, 451):
        d = start + dt.timedelta(days=rng.randint(0, 600))
        orders.write(r, 0, 1000 + r)
        orders.write(r, 1, d, date_fmt)
        orders.write(r, 2, name(rng))
        orders.write(r, 3, round(rng.uniform(5, 2500), 2), money)
        orders.write(r, 4, rng.random() < 0.7)
        orders.write(r, 5, dt.datetime(d.year, d.month, d.day, rng.randint(7, 19), rng.randint(0, 59), 0), dt_fmt)
    staff = wb.add_sheet("Staff")
    for c, h in enumerate(["name", "start_date", "salary"]):
        staff.write(0, c, h)
    for r in range(1, 51):
        staff.write(r, 0, name(rng))
        staff.write(r, 1, dt.date(2015, 1, 1) + dt.timedelta(days=rng.randint(0, 3800)), date_fmt)
        staff.write(r, 2, rng.randint(38, 140) * 1000)
    wb.save(path)


def make_budget20k(path: str, rng: random.Random) -> None:
    import openpyxl

    wb = openpyxl.Workbook()
    wb.properties.created = office_mod.FIXED
    wb.properties.modified = office_mod.FIXED
    wb.properties.creator = "AntiChat fixtures"
    tx = wb.active
    tx.title = "Transactions"
    tx.append(["txn_id", "date", "category", "region", "amount", "qty", "reimbursed"])
    start = dt.date(2025, 1, 1)
    for i in range(1, 20001):
        tx.append([i, start + dt.timedelta(days=rng.randint(0, 729)), rng.choice(CATEGORIES), rng.choice(REGIONS),
                   round(rng.uniform(1, 5000), 2), rng.randint(1, 40), rng.random() < 0.25])
    for row in tx.iter_rows(min_row=2, min_col=2, max_col=2):
        row[0].number_format = "yyyy-mm-dd"
    monthly = wb.create_sheet("Monthly")
    monthly.append(["month", "planned", "actual"])
    for m in range(24):
        monthly.append([dt.date(2025 + m // 12, m % 12 + 1, 1), rng.randint(40, 90) * 1000, rng.randint(35, 95) * 1000])
        monthly.cell(row=m + 2, column=1).number_format = "mmm yyyy"
    cats = wb.create_sheet("Categories")
    cats.append(["category", "budget", "owner"])
    for c in CATEGORIES:
        cats.append([c, rng.randint(5, 120) * 1000, name(rng)])
    wb.save(path)
    office_mod.normalise_zip(path)


EDIT_INSTRUCTIONS = [
    # sales.xlsx (Sheet "Sales": A order_id, B date, C region, D amount; rows 2-13; "Notes" sheet merged A1:D3)
    {"id": "ei-1", "file": "sales.xlsx", "instruction": "Add a Total row under the last order with the sum of the Amount column.",
     "check": {"type": "xlsx_total_row", "sheet": "Sales", "label_col": "A", "value_col": "D", "after_row": 13,
               "sum_range": "D2:D13"},
     "untouched": {"sheet": "Sales", "range": "A1:D13"}},
    {"id": "ei-2", "file": "sales.xlsx", "instruction": "Change the region of order 1005 to West.",
     "check": {"type": "xlsx_cell", "sheet": "Sales", "cell": "C6", "equals": "West"},
     "untouched": {"sheet": "Sales", "range": "A1:D13", "except": ["C6"]}},
    {"id": "ei-3", "file": "sales.xlsx", "instruction": "Add a column E called Tax with 10% of each order's Amount.",
     "check": {"type": "xlsx_new_column", "sheet": "Sales", "col": "E", "header": "Tax", "rows": [2, 13],
               "of_col": "D", "factor": 0.1},
     "untouched": {"sheet": "Sales", "range": "A1:D13"}},
    # memo.docx (Title "Draft memo: harbour project", Heading 1 x2, Normal paragraphs, one "Callout")
    {"id": "ei-4", "file": "memo.docx", "instruction": "Add a final paragraph that says: Approved by the board on 3 March.",
     "check": {"type": "docx_paragraph", "contains": "Approved by the board on 3 March", "position": "last"},
     "untouched": {"paragraphs": "all_original"}},
    {"id": "ei-5", "file": "memo.docx", "instruction": "In the title, replace the word Draft with Final.",
     "check": {"type": "docx_title", "equals": "Final memo: harbour project"},
     "untouched": {"paragraphs": "all_original", "except": [0]}},
    {"id": "ei-6", "file": "memo.docx", "instruction": "Add a heading Next steps at the end with two bullet points: Book the venue, Send the invites.",
     "check": {"type": "docx_heading", "text": "Next steps", "followed_by": ["Book the venue", "Send the invites"]},
     "untouched": {"paragraphs": "all_original"}},
    # pitch.pptx (slide 1 Title Slide, slide 2 Title and Content "Market", slide 3 Title and Content "Plan")
    {"id": "ei-7", "file": "pitch.pptx", "instruction": "Change the title of slide 2 to Market size.",
     "check": {"type": "pptx_title", "slide": 2, "equals": "Market size"},
     "untouched": {"slides": "all_original", "except_titles": [2]}},
    {"id": "ei-8", "file": "pitch.pptx", "instruction": "Add a slide at the end titled Questions?",
     "check": {"type": "pptx_new_slide", "count": 4, "title": "Questions?"},
     "untouched": {"slides": "all_original"}},
    {"id": "ei-9", "file": "pitch.pptx", "instruction": "Add the bullet Launch in Q3 to slide 3.",
     "check": {"type": "pptx_text", "slide": 3, "contains": "Launch in Q3"},
     "untouched": {"slides": "all_original", "except_bodies": [3]}},
]


def make_edit_inplace(folder: str, rng: random.Random) -> None:
    """M6.T20 originals: every style a lossy edit (re-creating the workbook/document) would drop."""
    import json

    import docx
    import openpyxl
    from docx.enum.style import WD_STYLE_TYPE
    from docx.shared import Inches, Pt, RGBColor
    from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
    from pptx import Presentation

    os.makedirs(folder, exist_ok=True)
    # XLSX
    wb = openpyxl.Workbook()
    wb.properties.created = office_mod.FIXED
    wb.properties.modified = office_mod.FIXED
    wb.properties.creator = "AntiChat fixtures"
    ws = wb.active
    ws.title = "Sales"
    ws.append(["order_id", "date", "region", "amount"])
    head_font = Font(name="Avenir Next", bold=True, color="FFFFFF", size=12)
    head_fill = PatternFill("solid", fgColor="1F3A5F")
    thin = Side(style="thin", color="9AA5B1")
    for c in ws[1]:
        c.font, c.fill = head_font, head_fill
        c.alignment = Alignment(horizontal="center")
        c.border = Border(bottom=thin)
    for i in range(12):
        ws.append([1001 + i, dt.date(2026, 1, 5) + dt.timedelta(days=7 * i), rng.choice(REGIONS),
                   round(rng.uniform(120, 4800), 2)])
        r = i + 2
        ws.cell(row=r, column=2).number_format = "dd mmm yyyy"
        ws.cell(row=r, column=4).number_format = "#,##0.00 [$EUR]"
        ws.cell(row=r, column=3).font = Font(name="Avenir Next", italic=True, color="334E68")
        if r % 2 == 0:
            for col in range(1, 5):
                ws.cell(row=r, column=col).fill = PatternFill("solid", fgColor="F0F4F8")
    for col, width in zip("ABCD", (12, 16, 14, 16)):
        ws.column_dimensions[col].width = width
    ws.freeze_panes = "A2"
    notes = wb.create_sheet("Notes")
    notes["A1"] = "Figures are invented for the AntiChat edit-in-place test."
    notes["A1"].font = Font(italic=True, color="7B8794")
    notes.merge_cells("A1:D3")
    xlsx = os.path.join(folder, "sales.xlsx")
    wb.save(xlsx)
    office_mod.normalise_zip(xlsx)
    # DOCX
    d = docx.Document()
    d.core_properties.created = office_mod.FIXED
    d.core_properties.modified = office_mod.FIXED
    d.core_properties.author = "AntiChat fixtures"
    d.core_properties.title = "Draft memo"
    sec = d.sections[0]
    sec.left_margin = sec.right_margin = Inches(1.25)
    sec.top_margin = Inches(0.9)
    sec.header.paragraphs[0].text = "Harbour project · internal"
    callout = d.styles.add_style("Callout", WD_STYLE_TYPE.PARAGRAPH)
    callout.base_style = d.styles["Normal"]
    callout.font.italic = True
    callout.font.size = Pt(12)
    callout.font.color.rgb = RGBColor(0x1F, 0x3A, 0x5F)
    d.styles["Normal"].font.name = "Georgia"
    d.styles["Normal"].font.size = Pt(11)
    d.add_paragraph("Draft memo: harbour project", style="Title")
    d.add_paragraph("Background", style="Heading 1")
    d.add_paragraph(office_mod.paragraph(rng))
    d.add_paragraph(office_mod.paragraph(rng))
    d.add_paragraph("Keep the lantern route open during the works.", style="Callout")
    d.add_paragraph("Budget", style="Heading 1")
    d.add_paragraph(office_mod.paragraph(rng))
    memo = os.path.join(folder, "memo.docx")
    d.save(memo)
    office_mod.normalise_zip(memo)
    # PPTX
    p = Presentation()
    p.core_properties.created = office_mod.FIXED
    p.core_properties.modified = office_mod.FIXED
    p.core_properties.author = "AntiChat fixtures"
    p.core_properties.title = "Pitch"
    s1 = p.slides.add_slide(p.slide_layouts[0])
    s1.shapes.title.text = "Harbour ferries"
    s1.placeholders[1].text = "A pitch for the canal line"
    for title, bullets in (("Market", ["Commuters", "Tourists", "Freight"]), ("Plan", ["Two vessels", "Hourly service"])):
        s = p.slides.add_slide(p.slide_layouts[1])
        s.shapes.title.text = title
        body = s.placeholders[1].text_frame
        body.text = bullets[0]
        for b in bullets[1:]:
            body.add_paragraph().text = b
    pitch = os.path.join(folder, "pitch.pptx")
    p.save(pitch)
    office_mod.normalise_zip(pitch)
    with open(os.path.join(folder, "edit-inplace.jsonl"), "w") as f:
        for row in EDIT_INSTRUCTIONS:
            f.write(json.dumps(row, sort_keys=True) + "\n")


HOLDOUT_INSTRUCTIONS = [
    # held-out set (M6.T20 harness fixes are checked on these too; never tuned on): inventory.xlsx "Stock" rows 2-8
    {"id": "ho-1", "file": "inventory.xlsx", "instruction": "Set the quantity of Lantern to 0.",
     "check": {"type": "xlsx_cells", "sheet": "Stock", "cells": {"B4": 0}},
     "untouched": {"sheet": "Stock", "range": "A1:C8", "except": ["B4"]}},
    {"id": "ho-2", "file": "inventory.xlsx", "instruction": "Add a row at the end for item Compass with quantity 12 and price 8.50.",
     "check": {"type": "xlsx_cells", "sheet": "Stock", "cells": {"A9": "Compass", "B9": 12, "C9": 8.5}},
     "untouched": {"sheet": "Stock", "range": "A1:C8"}},
    {"id": "ho-3", "file": "letter.docx", "instruction": "Add a closing paragraph at the end: Kind regards, Ana.",
     "check": {"type": "docx_paragraph", "contains": "Kind regards, Ana", "position": "last"},
     "untouched": {"paragraphs": "all_original"}},
    {"id": "ho-4", "file": "letter.docx", "instruction": "Rename the heading Details to Schedule.",
     "check": {"type": "docx_has_paragraph", "text": "Schedule", "style_prefix": "Heading"},
     "untouched": {"paragraphs": "all_original", "except": [1]}},
    {"id": "ho-5", "file": "roadmap.pptx", "instruction": "Change the title of slide 3 to Next quarter.",
     "check": {"type": "pptx_title", "slide": 3, "equals": "Next quarter"},
     "untouched": {"slides": "all_original", "except_titles": [3]}},
]


HOLDOUT2_INSTRUCTIONS = [
    # second held-out set (written after the first one's traces informed op aliases; never looked at before a run)
    {"id": "h2-1", "file": "sales.xlsx", "instruction": "Change the amount of order 1003 to 500.",
     "check": {"type": "xlsx_cells", "sheet": "Sales", "cells": {"D4": 500}},
     "untouched": {"sheet": "Sales", "range": "A1:D13", "except": ["D4"]}},
    {"id": "h2-2", "file": "inventory.xlsx", "instruction": "Rename the column price to unit price.",
     "check": {"type": "xlsx_cells", "sheet": "Stock", "cells": {"C1": "unit price"}},
     "untouched": {"sheet": "Stock", "range": "A1:C8", "except": ["C1"]}},
    {"id": "h2-3", "file": "memo.docx", "instruction": "Add a heading Risks at the end of the memo.",
     "check": {"type": "docx_has_paragraph", "text": "Risks", "style_prefix": "Heading"},
     "untouched": {"paragraphs": "all_original"}},
    {"id": "h2-4", "file": "roadmap.pptx", "instruction": "Add the bullet Budget review to slide 2.",
     "check": {"type": "pptx_text", "slide": 2, "contains": "Budget review"},
     "untouched": {"slides": "all_original", "except_bodies": [2]}},
    {"id": "h2-5", "file": "pitch.pptx", "instruction": "Change the subtitle on slide 1 to: A canal line pitch.",
     "check": {"type": "pptx_text", "slide": 1, "contains": "A canal line pitch"},
     "untouched": {"slides": "all_original", "except_bodies": [1]}},
]


HOLDOUT3_INSTRUCTIONS = [
    # third held-out set: written before attempt 7 and not looked at before that run
    {"id": "h3-1", "file": "inventory.xlsx", "instruction": "Set the price of Kiln to 19.99.",
     "check": {"type": "xlsx_cells", "sheet": "Stock", "cells": {"C3": 19.99}},
     "untouched": {"sheet": "Stock", "range": "A1:C8", "except": ["C3"]}},
    {"id": "h3-2", "file": "sales.xlsx", "instruction": "Add a row for order 1013 in region North with amount 750.",
     "check": {"type": "xlsx_cells", "sheet": "Sales", "cells": {"A14": 1013, "C14": "North", "D14": 750}},
     "untouched": {"sheet": "Sales", "range": "A1:D13"}},
    {"id": "h3-3", "file": "letter.docx", "instruction": "Add a paragraph at the end: See you on Friday.",
     "check": {"type": "docx_paragraph", "contains": "See you on Friday", "position": "last"},
     "untouched": {"paragraphs": "all_original"}},
    {"id": "h3-4", "file": "pitch.pptx", "instruction": "Add a slide titled Team with the bullets Ana and Ben.",
     "check": {"type": "pptx_new_slide", "count": 4, "title": "Team"},
     "untouched": {"slides": "all_original"}},
    {"id": "h3-5", "file": "memo.docx", "instruction": "In the title, replace the word harbour with port.",
     "check": {"type": "docx_title", "equals": "Draft memo: port project"},
     "untouched": {"paragraphs": "all_original", "except": [0]}},
]


HOLDOUT4_INSTRUCTIONS = [
    # fourth held-out set: written before the repeated final runs; no harness change is based on it
    {"id": "h4-1", "file": "inventory.xlsx", "instruction": "Change the quantity of Mortar to 25.",
     "check": {"type": "xlsx_cells", "sheet": "Stock", "cells": {"B7": 25}},
     "untouched": {"sheet": "Stock", "range": "A1:C8", "except": ["B7"]}},
    {"id": "h4-2", "file": "sales.xlsx", "instruction": "Set the region of order 1010 to South.",
     "check": {"type": "xlsx_cells", "sheet": "Sales", "cells": {"C11": "South"}},
     "untouched": {"sheet": "Sales", "range": "A1:D13", "except": ["C11"]}},
    {"id": "h4-3", "file": "memo.docx", "instruction": "Add a final paragraph: Questions go to the harbour office.",
     "check": {"type": "docx_paragraph", "contains": "Questions go to the harbour office", "position": "last"},
     "untouched": {"paragraphs": "all_original"}},
    {"id": "h4-4", "file": "roadmap.pptx", "instruction": "Change the title of slide 2 to Completed.",
     "check": {"type": "pptx_title", "slide": 2, "equals": "Completed"},
     "untouched": {"slides": "all_original", "except_titles": [2]}},
    {"id": "h4-5", "file": "letter.docx", "instruction": "Add a heading Venue at the end with the bullets Main hall and Garden.",
     "check": {"type": "docx_heading", "text": "Venue", "followed_by": ["Main hall", "Garden"]},
     "untouched": {"paragraphs": "all_original"}},
]


def make_holdout2(folder: str, sources: list, rows: list = None, name: str = "holdout2") -> None:
    import json
    import shutil

    os.makedirs(folder, exist_ok=True)
    for src in sources:
        shutil.copyfile(src, os.path.join(folder, os.path.basename(src)))
    with open(os.path.join(folder, f"{name}.jsonl"), "w") as f:
        for row in (rows or HOLDOUT2_INSTRUCTIONS):
            f.write(json.dumps(row, sort_keys=True) + "\n")


def make_holdout(folder: str, rng: random.Random) -> None:
    """Held-out originals in the same spirit as make_edit_inplace, different content and styles."""
    import json

    import docx
    import openpyxl
    from docx.enum.style import WD_STYLE_TYPE
    from docx.shared import Inches, Pt
    from openpyxl.styles import Font, PatternFill
    from pptx import Presentation

    os.makedirs(folder, exist_ok=True)
    wb = openpyxl.Workbook()
    wb.properties.created = office_mod.FIXED
    wb.properties.modified = office_mod.FIXED
    wb.properties.creator = "AntiChat fixtures"
    ws = wb.active
    ws.title = "Stock"
    ws.append(["item", "quantity", "price"])
    for c in ws[1]:
        c.font = Font(name="Georgia", bold=True, color="FFFFFF")
        c.fill = PatternFill("solid", fgColor="5B3A29")
    for i, item in enumerate(["Ledger", "Kiln", "Lantern", "Bellows", "Trellis", "Mortar", "Almanac"]):
        ws.append([item, rng.randint(1, 60), round(rng.uniform(2, 90), 2)])
        ws.cell(row=i + 2, column=3).number_format = "$#,##0.00"
        ws.cell(row=i + 2, column=1).font = Font(name="Georgia", italic=True)
    ws.column_dimensions["A"].width = 18
    ws.column_dimensions["C"].width = 12
    ws.freeze_panes = "B2"
    x = os.path.join(folder, "inventory.xlsx")
    wb.save(x)
    office_mod.normalise_zip(x)
    d = docx.Document()
    d.core_properties.created = office_mod.FIXED
    d.core_properties.modified = office_mod.FIXED
    d.core_properties.author = "AntiChat fixtures"
    d.sections[0].left_margin = Inches(1.5)
    q = d.styles.add_style("Aside", WD_STYLE_TYPE.PARAGRAPH)
    q.font.size = Pt(10)
    q.font.italic = True
    d.add_paragraph("Dear guild members,", style="Normal")
    d.add_paragraph("Details", style="Heading 2")
    d.add_paragraph(office_mod.paragraph(rng))
    d.add_paragraph("Bring your own lantern.", style="Aside")
    d.add_paragraph(office_mod.paragraph(rng))
    y = os.path.join(folder, "letter.docx")
    d.save(y)
    office_mod.normalise_zip(y)
    p = Presentation()
    p.core_properties.created = office_mod.FIXED
    p.core_properties.modified = office_mod.FIXED
    p.core_properties.author = "AntiChat fixtures"
    s1 = p.slides.add_slide(p.slide_layouts[0])
    s1.shapes.title.text = "Canal roadmap"
    s1.placeholders[1].text = "Spring review"
    for title, bullets in (("Done", ["Dredging", "Signage"]), ("Now", ["Ferry trial", "Ticketing"])):
        s = p.slides.add_slide(p.slide_layouts[1])
        s.shapes.title.text = title
        tf = s.placeholders[1].text_frame
        tf.text = bullets[0]
        for b in bullets[1:]:
            tf.add_paragraph().text = b
    z = os.path.join(folder, "roadmap.pptx")
    p.save(z)
    office_mod.normalise_zip(z)
    with open(os.path.join(folder, "holdout.jsonl"), "w") as f:
        for row in HOLDOUT_INSTRUCTIONS:
            f.write(json.dumps(row, sort_keys=True) + "\n")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="fixtures")
    ap.add_argument("--xls", action="store_true")
    ap.add_argument("--budget20k", action="store_true")
    ap.add_argument("--edit-inplace", action="store_true")
    args = ap.parse_args()
    office = os.path.join(args.out, "docs", "office")
    os.makedirs(office, exist_ok=True)
    if args.xls:
        make_xls(os.path.join(office, "legacy.xls"), random.Random(SEED))
    if args.budget20k:
        make_budget20k(os.path.join(office, "budget-20k.xlsx"), random.Random(SEED + 1))
    if args.edit_inplace:
        make_edit_inplace(os.path.join(office, "edit-inplace"), random.Random(SEED + 20))
        make_holdout(os.path.join(office, "edit-inplace", "holdout"), random.Random(SEED + 21))
        ei = os.path.join(office, "edit-inplace")
        make_holdout2(os.path.join(ei, "holdout2"), [os.path.join(ei, "sales.xlsx"), os.path.join(ei, "memo.docx"),
                      os.path.join(ei, "pitch.pptx"), os.path.join(ei, "holdout", "inventory.xlsx"),
                      os.path.join(ei, "holdout", "roadmap.pptx")])
        make_holdout2(os.path.join(ei, "holdout3"), [os.path.join(ei, "sales.xlsx"), os.path.join(ei, "memo.docx"),
                      os.path.join(ei, "pitch.pptx"), os.path.join(ei, "holdout", "inventory.xlsx"),
                      os.path.join(ei, "holdout", "letter.docx")], HOLDOUT3_INSTRUCTIONS, "holdout3")
        make_holdout2(os.path.join(ei, "holdout4"), [os.path.join(ei, "sales.xlsx"), os.path.join(ei, "memo.docx"),
                      os.path.join(ei, "holdout", "inventory.xlsx"), os.path.join(ei, "holdout", "roadmap.pptx"),
                      os.path.join(ei, "holdout", "letter.docx")], HOLDOUT4_INSTRUCTIONS, "holdout4")


if __name__ == "__main__":
    main()
