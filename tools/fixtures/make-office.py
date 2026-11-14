#!/usr/bin/env python3
"""Synthetic document fixtures for file cards, previews and intake (M4.T10 inputs; M6.T01 reuses them):
  fixtures/docs/pdf/text-10p.pdf        10 pages of invented text (reportlab, invariant mode)
  fixtures/docs/office/report.docx      headings, paragraphs, a list and a 4x3 table (python-docx)
  fixtures/docs/office/budget.xlsx      2 sheets: Budget (13 rows x 4 cols, a SUM formula), Notes (python-openpyxl)
  fixtures/docs/office/deck.pptx        4 slides with titles, bullets and notes (python-pptx)
  fixtures/docs/office/notes.csv        header + 24 rows
All text is invented here from a fixed word list (seed 20261104) and released CC0. No real personal data.
Office core properties and zip member times are fixed so reruns are byte-identical.

Usage: tools/.venv/bin/python3 -I tools/fixtures/make-office.py --out fixtures
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import io
import os
import random
import re
import zipfile

SEED = 20261104
FIXED = dt.datetime(2026, 11, 4, 0, 0, 0)
WORDS = ("harbour lantern meadow quarry orchard ledger compass furnace cobble thistle beacon granary vessel canal "
         "ferry timber archive pigment loom kiln weir trellis bellows almanac pewter saddle mortar willow").split()


def sentence(rng: random.Random, n: int | None = None) -> str:
    words = [rng.choice(WORDS) for _ in range(n or rng.randint(8, 16))]
    return " ".join(words).capitalize() + "."


def paragraph(rng: random.Random) -> str:
    return " ".join(sentence(rng) for _ in range(rng.randint(3, 6)))


def normalise_zip(path: str) -> None:
    """Rewrite an OOXML zip with sorted members and a fixed timestamp (byte-identical reruns)."""
    with zipfile.ZipFile(path) as z:
        members = [(i.filename, z.read(i.filename)) for i in z.infolist()]
    stamp = FIXED.strftime("%Y-%m-%dT%H:%M:%SZ").encode()
    # openpyxl stamps dcterms:modified with "now" on save; pin it.
    members = [(n, re.sub(rb"(<dcterms:(?:created|modified)[^>]*>)[^<]*", rb"\g<1>" + stamp, d))
               if n == "docProps/core.xml" else (n, d) for n, d in members]
    # [Content_Types].xml first (OOXML convention), the rest in original order.
    members.sort(key=lambda m: m[0] != "[Content_Types].xml")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as out:
        for name, data in members:
            info = zipfile.ZipInfo(name, date_time=FIXED.timetuple()[:6])
            info.compress_type = zipfile.ZIP_DEFLATED
            out.writestr(info, data)
    with open(path, "wb") as f:
        f.write(buf.getvalue())


def make_pdf(path: str, rng: random.Random) -> None:
    from reportlab.lib.pagesizes import A4
    from reportlab.pdfgen import canvas

    c = canvas.Canvas(path, pagesize=A4, invariant=1)
    c.setTitle("Synthetic text, 10 pages")
    width, height = A4
    for page in range(1, 11):
        c.setFont("Helvetica-Bold", 16)
        c.drawString(72, height - 72, f"Chapter {page}: The {rng.choice(WORDS)} {rng.choice(WORDS)}")
        c.setFont("Helvetica", 10)
        y = height - 104
        text = c.beginText(72, y)
        for _ in range(5):
            words = paragraph(rng).split()
            line = ""
            for w in words:
                if len(line) + len(w) > 90:
                    text.textLine(line)
                    line = w
                else:
                    line = f"{line} {w}".strip()
            text.textLine(line)
            text.textLine("")
        c.drawText(text)
        c.drawString(width / 2 - 20, 40, f"Page {page}")
        c.showPage()
    c.save()


def make_docx(path: str, rng: random.Random) -> None:
    import docx

    d = docx.Document()
    d.core_properties.created = FIXED
    d.core_properties.modified = FIXED
    d.core_properties.title = "Quarterly report"
    d.core_properties.author = "AntiChat fixtures"
    d.add_heading("Quarterly report", 0)
    for section in ("Summary", "Operations", "Outlook"):
        d.add_heading(section, 1)
        d.add_paragraph(paragraph(rng))
        d.add_paragraph(paragraph(rng))
    d.add_heading("Highlights", 1)
    for _ in range(4):
        d.add_paragraph(sentence(rng, 7), style="List Bullet")
    table = d.add_table(rows=4, cols=3)
    for col, title in enumerate(("Item", "Units", "Cost")):
        table.cell(0, col).text = title
    for row in range(1, 4):
        table.cell(row, 0).text = rng.choice(WORDS).capitalize()
        table.cell(row, 1).text = str(rng.randint(1, 90))
        table.cell(row, 2).text = f"{rng.randint(100, 9000)}.00"
    d.save(path)
    normalise_zip(path)


def make_xlsx(path: str, rng: random.Random) -> None:
    import openpyxl

    wb = openpyxl.Workbook()
    wb.properties.created = FIXED
    wb.properties.modified = FIXED
    wb.properties.creator = "AntiChat fixtures"
    ws = wb.active
    ws.title = "Budget"
    ws.append(["Month", "Category", "Planned", "Actual"])
    months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    for m in months:
        ws.append([m, rng.choice(["Rent", "Food", "Travel", "Tools"]), rng.randint(500, 3000), rng.randint(400, 3200)])
    ws.append(["Total", "", "=SUM(C2:C13)", "=SUM(D2:D13)"])
    notes = wb.create_sheet("Notes")
    notes.append(["Note"])
    for _ in range(5):
        notes.append([sentence(rng, 6)])
    wb.save(path)
    normalise_zip(path)


def make_pptx(path: str, rng: random.Random) -> None:
    from pptx import Presentation

    p = Presentation()
    p.core_properties.created = FIXED
    p.core_properties.modified = FIXED
    p.core_properties.author = "AntiChat fixtures"
    p.core_properties.title = "Project deck"
    title = p.slides.add_slide(p.slide_layouts[0])
    title.shapes.title.text = "Project deck"
    title.placeholders[1].text = "Synthetic fixture"
    for n in range(2, 5):
        s = p.slides.add_slide(p.slide_layouts[1])
        s.shapes.title.text = f"Slide {n}: {rng.choice(WORDS).capitalize()}"
        body = s.placeholders[1].text_frame
        body.text = sentence(rng, 6)
        for _ in range(2):
            body.add_paragraph().text = sentence(rng, 6)
        s.notes_slide.notes_text_frame.text = sentence(rng)
    p.save(path)
    normalise_zip(path)


def make_csv(path: str, rng: random.Random) -> None:
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["date", "place", "item", "amount"])
        for day in range(1, 25):
            w.writerow([f"2026-03-{day:02d}", rng.choice(WORDS), rng.choice(WORDS), f"{rng.randint(1, 500)}.{rng.randint(0, 99):02d}"])


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="fixtures")
    args = ap.parse_args()
    pdf_dir = os.path.join(args.out, "docs", "pdf")
    office = os.path.join(args.out, "docs", "office")
    os.makedirs(pdf_dir, exist_ok=True)
    os.makedirs(office, exist_ok=True)
    make_pdf(os.path.join(pdf_dir, "text-10p.pdf"), random.Random(SEED))
    make_docx(os.path.join(office, "report.docx"), random.Random(SEED + 1))
    make_xlsx(os.path.join(office, "budget.xlsx"), random.Random(SEED + 2))
    make_pptx(os.path.join(office, "deck.pptx"), random.Random(SEED + 3))
    make_csv(os.path.join(office, "notes.csv"), random.Random(SEED + 4))


if __name__ == "__main__":
    main()
