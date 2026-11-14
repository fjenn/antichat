#!/usr/bin/env python3
"""File-out golden sets (M6.T09/T10, AT-273): prompts + fixed tool-argument specs (no model).

  fixtures/prompts/fileout-golden/{pdf,docx,md,xlsx,csv}-30.jsonl   {"id", "format", "prompt", "features": [...]}
  fixtures/docs/golden-out/specs/<id>.json                 the create_document / create_spreadsheet arguments
  fixtures/docs/golden-out/specs/images.json               image ref → fixture path (CC0 photos)

The 30 topics are the same across formats (pdf-07 / docx-07 / md-07 share the content), covering tables, nested
lists, images, code, quotes, rules, long multi-page tables, page sizes, the report style, and text in Latin, Greek,
Cyrillic, CJK (SC / JP / KR), Arabic and Hebrew. Expected renderer outputs (`golden-out/expected/`) are written once by
the renderer tests (`ANTICHAT_GOLDEN_WRITE=1`), reviewed, then frozen. Deterministic; invented text, CC0.

Usage: python3 -I tools/fixtures/make-fileout-golden.py --out fixtures [--formats pdf,docx,md]
"""
from __future__ import annotations

import argparse
import json
import os

GREEK = "Η γρήγορη καφέ αλεπού πηδάει πάνω από τον τεμπέλη σκύλο."
CYRILLIC = "Съешь же ещё этих мягких французских булок, да выпей чаю."
CJK_SC = "敏捷的棕色狐狸跳过了懒狗。这是一段简体中文文本。"
CJK_JP = "いろはにほへと ちりぬるを。これは日本語のテキストです。"
CJK_KR = "다람쥐 헌 쳇바퀴에 타고파. 이것은 한국어 문장입니다."
ARABIC = "نص حكيم له سر قاطع وذو شأن عظيم مكتوب على ثوب أخضر."
HEBREW = "דג סקרן שט בים מאוכזב ולפתע מצא חברה."

IMAGES = {f"img-{i:03d}": f"images/photos-cc0/{i:03d}.jpg" for i in (1, 2, 3, 4, 5)}

REGIONS = ["North", "South", "East", "West", "Central"]


def table(header, rows, align=None):
    out = "| " + " | ".join(header) + " |\n"
    out += "|" + "|".join((align or ["---"] * len(header))) + "|\n"
    for r in rows:
        out += "| " + " | ".join(str(c) for c in r) + " |\n"
    return out


def budget_rows(n, seed):
    rows = []
    for i in range(n):
        v = (seed * 7919 + i * 104729) % 90000 / 100 + 100
        rows.append([f"Item {i + 1:03d}", REGIONS[(i + seed) % 5], f"{v:,.2f}", f"{(i * 37 + seed) % 100}%"])
    return rows


def topics():
    t = []

    def add(title, prompt, md, features, **opts):
        t.append({"title": title, "prompt": prompt, "markdown": md, "features": features, **opts})

    add("Weekly Team Update", "a short weekly team update with a heading, two paragraphs and a bullet list",
        "# Weekly Team Update\n\nThis week the team finished the onboarding flow and started on search.\n\n"
        "Next week we focus on **performance** and *polish*.\n\n- Onboarding shipped\n- Search prototype\n- Bug triage\n",
        ["headings", "paragraphs", "list"])
    add("Quarterly Budget Summary", "a quarterly budget summary with a table of regions and amounts",
        "# Quarterly Budget Summary\n\nSpending by region for Q3.\n\n" +
        table(["Region", "Planned", "Actual"], [[r, f"{1000 + i * 250:,}", f"{980 + i * 260:,}"] for i, r in enumerate(REGIONS)],
              ["---", "---:", "---:"]) + "\nTotals are in euros.\n",
        ["table", "number alignment"])
    add("Packing Checklist", "a packing checklist with nested lists",
        "# Packing Checklist\n\n- Clothes\n  - Shirts\n  - Trousers\n    - One formal pair\n- Documents\n  - Passport\n  - Tickets\n"
        "- Electronics\n\n1. Book the taxi\n2. Check in online\n   1. Choose a seat\n   2. Print the pass\n3. Leave by 7:00\n",
        ["nested bullet list", "nested numbered list"])
    add("Garden Photo Notes", "a short document with two of the attached photos and captions",
        "# Garden Photo Notes\n\nTwo pictures from the walk.\n\n![A view from the path](img-001)\n\n"
        "The second one was taken an hour later.\n\n![Late afternoon](img-002)\n",
        ["images", "captions"], images=[{"ref": "img-001", "alt": "A view from the path"}, {"ref": "img-002", "alt": "Late afternoon"}])
    add("Greek Reading Sample", "a one-page reading sample in Greek with a heading",
        f"# Δείγμα ανάγνωσης\n\n{GREEK}\n\n{GREEK} {GREEK}\n", ["greek"])
    add("Russian Reading Sample", "a reading sample in Russian (Cyrillic) with a short list",
        f"# Образец текста\n\n{CYRILLIC}\n\n- Первый пункт\n- Второй пункт\n", ["cyrillic", "list"])
    add("Chinese Notes", "notes in simplified Chinese with a heading and paragraphs",
        f"# 中文笔记\n\n{CJK_SC}\n\n{CJK_SC}\n", ["cjk-sc"])
    add("Japanese Memo", "a memo in Japanese", f"# 日本語のメモ\n\n{CJK_JP}\n\n**重要**: {CJK_JP}\n", ["cjk-jp", "bold"])
    add("Korean Notice", "a notice in Korean", f"# 한국어 공지\n\n{CJK_KR}\n\n{CJK_KR}\n", ["cjk-kr"])
    add("Arabic Letter", "a short letter in Arabic (right to left)",
        f"# رسالة قصيرة\n\n{ARABIC}\n\n{ARABIC}\n", ["arabic", "rtl"])
    add("Hebrew Notice", "a notice in Hebrew (right to left)", f"# הודעה\n\n{HEBREW}\n\n{HEBREW}\n", ["hebrew", "rtl"])
    add("Multilingual Glossary", "a glossary table with the same greeting in seven scripts",
        "# Multilingual Glossary\n\n" + table(["Language", "Greeting"], [
            ["English", "Hello"], ["Greek", "Γεια σας"], ["Russian", "Здравствуйте"], ["Chinese", "你好"],
            ["Japanese", "こんにちは"], ["Korean", "안녕하세요"], ["Arabic", "مرحبا"], ["Hebrew", "שלום"]]),
        ["table", "greek", "cyrillic", "cjk", "arabic", "hebrew"])
    add("Mixed Script Report", "a report mixing English with Arabic and Hebrew quotes",
        f"# Mixed Script Report\n\nThe sign read:\n\n> {ARABIC}\n\nAnd below it:\n\n> {HEBREW}\n\nBoth were translated on site.\n",
        ["quote", "arabic", "hebrew", "mixed direction"])
    add("Python Snippet Guide", "a guide with a Python code block and inline code",
        "# Python Snippet Guide\n\nUse `sorted()` with a key:\n\n```python\nrows = [(\"b\", 2), (\"a\", 1)]\n"
        "for name, n in sorted(rows, key=lambda r: r[1]):\n    print(name, n)\n```\n\nThe output lists `a` first.\n",
        ["code block", "inline code"])
    add("Release Notes 2.4", "release notes with sections, links and a horizontal rule",
        "# Release Notes 2.4\n\n## New\n\n- Faster search\n- [Documentation](https://example.org/docs) updated\n\n---\n\n## Fixed\n\n"
        "- Crash when the list was empty\n- ~~Old export~~ replaced by the new one\n",
        ["sections", "link", "rule", "strikethrough"])
    add("Annual Inventory", "a long inventory table that spans several pages",
        "# Annual Inventory\n\nEvery item counted in the December audit.\n\n" +
        table(["Item", "Region", "Value", "Share"], budget_rows(90, 3), ["---", "---", "---:", "---:"]),
        ["long table", "multi-page", "repeated header"])
    add("Meeting Minutes", "meeting minutes with attendees, decisions and action items",
        "# Meeting Minutes\n\n**Date:** 4 November\n\n## Attendees\n\n- Ana\n- Bo\n- Chen\n\n## Decisions\n\n1. Ship on Friday\n"
        "2. Freeze the API\n\n## Action items\n\n| Owner | Task | Due |\n|---|---|---|\n| Ana | Release notes | Thu |\n| Bo | QA pass | Fri |\n",
        ["headings", "numbered list", "table"])
    add("Project Proposal", "a project proposal in the report style",
        "# Project Proposal\n\n## Summary\n\nWe propose a small study of reading speed on paper and screen.\n\n## Method\n\n"
        "Twenty volunteers read four short texts. Each text is about *three hundred* words.\n\n## Budget\n\n" +
        table(["Line", "Cost"], [["Printing", "120"], ["Snacks", "60"], ["Room", "0"]], ["---", "---:"]),
        ["report style", "serif", "table"], style="report")
    add("US Letter Flyer", "a one-page flyer on US Letter paper",
        "# Community Bake Sale\n\nSaturday, 10:00 to 14:00, at the library.\n\n- Bread\n- Cakes\n- Cookies\n\nAll proceeds go to the reading club.\n",
        ["letter page size"], page_size="Letter")
    add("A4 Handout", "a one-page handout on A4 paper", "# Handout\n\nRead pages 4 to 9 before class.\n\n1. Summarise\n2. Ask one question\n",
        ["a4 page size"], page_size="A4")
    add("Recipe Card", "a recipe with ingredients and steps",
        "# Lemon Pancakes\n\n## Ingredients\n\n- 2 eggs\n- 200 g flour\n- 300 ml milk\n- 1 lemon\n\n## Steps\n\n1. Whisk the eggs and milk.\n"
        "2. Fold in the flour.\n3. Add zest and juice.\n4. Fry until golden.\n", ["list", "numbered list"])
    add("Travel Itinerary", "a travel itinerary with a day-by-day table and a photo",
        "# Travel Itinerary\n\n" + table(["Day", "Place", "Notes"], [["1", "Lisbon", "Arrive 14:00"], ["2", "Sintra", "Day trip"],
                                                                    ["3", "Porto", "Train 09:10"]]) +
        "\n![Station at dawn](img-003)\n", ["table", "image"], images=[{"ref": "img-003", "alt": "Station at dawn"}])
    add("Study Notes Chapter 3", "study notes with headings H1 to H4",
        "# Chapter 3\n\n## 3.1 Cells\n\n### Membranes\n\n#### Transport\n\nPassive and active transport move molecules across the membrane.\n",
        ["heading levels"])
    add("Customer FAQ", "an FAQ with questions in bold and short answers",
        "# Customer FAQ\n\n**How do I reset my password?**\n\nUse the link on the sign-in page.\n\n**Can I change my plan?**\n\n"
        "Yes, at any time, from Settings.\n\n**Is there a phone line?**\n\nNot yet; write to us instead.\n", ["bold", "paragraphs"])
    add("Lab Report", "a lab report with a results table, a quote and a photo",
        "# Lab Report\n\n## Results\n\n" + table(["Sample", "pH", "Temp (°C)"], [["A", "6.8", "21.5"], ["B", "7.1", "21.9"], ["C", "7.4", "22.0"]],
                                                ["---", "---:", "---:"]) +
        "\n> Readings were taken twice and averaged.\n\n![Bench setup](img-004)\n", ["table", "quote", "image"],
        images=[{"ref": "img-004", "alt": "Bench setup"}])
    add("Long Essay", "a long essay of about four pages",
        "# On Walking\n\n" + "\n\n".join(
            f"## Part {i + 1}\n\nWalking is the oldest way to think. " * 1 +
            ("A path rewards patience, and patience rewards the walker with small discoveries along the way. " * 14)
            for i in range(6)) + "\n", ["long text", "multi-page"])
    add("Shopping List Multilingual", "a shopping list with items in Greek, Russian and Chinese",
        f"# Shopping List\n\n- Ψωμί (bread)\n- Молоко (milk)\n- 苹果 (apples)\n- {GREEK[:12]}\n", ["list", "greek", "cyrillic", "cjk-sc"])
    add("Contract Summary", "a contract summary with numbered clauses and a signature line",
        "# Contract Summary\n\n1. **Term.** Twelve months from signing.\n2. **Fees.** Paid monthly in advance.\n3. **Notice.** Thirty days in writing.\n\n---\n\n"
        "Signed: ______________________\n", ["numbered list", "bold", "rule"])
    add("Photo Gallery", "a gallery page with three photos",
        "# Photo Gallery\n\n![Morning](img-001)\n\n![Noon](img-005)\n\n![Evening](img-002)\n", ["images"],
        images=[{"ref": "img-001", "alt": "Morning"}, {"ref": "img-005", "alt": "Noon"}, {"ref": "img-002", "alt": "Evening"}])
    add("Kitchen Sink", "a document that uses every element: headings, lists, table, code, quote, rule, image, and six scripts",
        "# Kitchen Sink\n\nPlain, **bold**, *italic*, `code`, ~~struck~~ and a [link](https://example.org).\n\n"
        "- One\n  - One point one\n- Two\n\n1. First\n2. Second\n\n" + table(["A", "B"], [["1", "2"], ["3", "4"]]) +
        "\n```\nplain code\n```\n\n> A quote.\n\n---\n\n![Picture](img-003)\n\n"
        f"{GREEK}\n\n{CYRILLIC}\n\n{CJK_SC}\n\n{ARABIC}\n\n{HEBREW}\n\n{CJK_KR}\n",
        ["everything", "greek", "cyrillic", "cjk", "arabic", "hebrew"], images=[{"ref": "img-003", "alt": "Picture"}])
    assert len(t) == 30, len(t)
    return t


def deck_topics():
    """20 decks (M6.T11, AT-275): every theme, every layout, notes, images, the 30-slide maximum, scripts."""
    themes = ["clean", "dusk", "paper", "bold"]
    imgs = ["img-001", "img-002", "img-003", "img-004", "img-005"]
    subjects = [
        ("Quarterly Review", ["Revenue up 12%", "Two new regions", "Churn down to 3%"]),
        ("Product Launch Plan", ["Beta in March", "Press in April", "General release in May"]),
        ("Team Offsite", ["Agenda", "Workshops", "Dinner on Thursday"]),
        ("Garden Club Talk", ["Soil first", "Water early", "Mulch in autumn"]),
        ("Onboarding Basics", ["Accounts", "Tools", "Who to ask"]),
        ("Budget 2027", ["Hiring", "Travel", "Equipment"]),
        ("Reading Club", ["This month's book", "Discussion questions", "Next meeting"]),
        ("Safety Briefing", ["Exits", "First aid", "Contacts"]),
        ("Market Overview", ["Segments", "Competitors", "Opportunities"]),
        ("Weekly Standup", ["Done", "Doing", "Blocked"]),
    ]
    t = []
    for i in range(20):
        name, pts = subjects[i % 10]
        theme = themes[i % 4]
        slides = [{"layout": "title", "title": name, "subtitle": f"Prepared with AntiChat · deck {i + 1}"}]
        slides.append({"layout": "bullets", "title": "Highlights", "bullets": pts, "notes": f"Speaker notes for {name}: keep it short."})
        if i % 2 == 0:
            slides.append({"layout": "image", "title": "In pictures", "image_ref": imgs[i % 5], "notes": "Pause on the photo."})
        if i % 3 == 0:
            slides.append({"layout": "title_bullets_image", "title": "Details", "bullets": pts + ["One more point"],
                           "image_ref": imgs[(i + 1) % 5]})
        if i == 7:
            slides.append({"layout": "bullets", "title": "Πολύγλωσσο · Многоязычный · 多语言",
                           "bullets": ["Ελληνικά", "Русский", "中文", "日本語", "한국어", "العربية", "עברית"]})
        if i == 19:  # the 30-slide maximum
            slides += [{"layout": "bullets", "title": f"Topic {k}", "bullets": [f"Point {k}.1", f"Point {k}.2"]}
                       for k in range(1, 31 - len(slides))]
        if i == 9:  # eight bullets (the maximum)
            slides.append({"layout": "bullets", "title": "Checklist", "bullets": [f"Item {k}" for k in range(1, 9)]})
        refs = sorted({s["image_ref"] for s in slides if "image_ref" in s})
        t.append({"filename": name, "theme": theme, "slides": slides, "images": refs,
                  "prompt": f"Make me a slide deck called \"{name}\" in the {theme} theme: a title slide, the highlights"
                            + (", a photo slide" if i % 2 == 0 else "") + (" and a details slide with a photo" if i % 3 == 0 else "")
                            + (", 30 slides in total" if i == 19 else "") + ", with speaker notes."})
    return t


NAMES = {"pdf": "PDF", "docx": "Word document", "md": "Markdown file", "xlsx": "Excel spreadsheet", "csv": "CSV file"}

MONTHS = ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30", "2026-05-31", "2026-06-30",
          "2026-07-31", "2026-08-31", "2026-09-30", "2026-10-31", "2026-11-30", "2026-12-31"]


def col(header, typ, fmt=None):
    c = {"header": header, "type": typ}
    if fmt:
        c["format"] = fmt
    return c


def sheet_topics():
    """30 spreadsheet specs (M6.T10): sheets / typed columns / number formats / formulas / freeze + autofilter /
    native charts / multi-sheet / dates / percent / currency / bool / scripts / wide and long tables."""
    t = []

    def add(filename, prompt, sheets, features):
        t.append({"filename": filename, "prompt": prompt, "sheets": sheets, "features": features})

    add("Monthly Budget", "a monthly budget with planned and actual columns and a total row formula",
        [{"name": "Budget", "columns": [col("Month", "date", "yyyy-mm"), col("Planned", "currency", "#,##0.00"),
                                         col("Actual", "currency", "#,##0.00")],
          "rows": [[m, 1000 + i * 50, 980 + i * 55] for i, m in enumerate(MONTHS)],
          "formulas": {"A14": '"Total"', "B14": "SUM(B2:B13)", "C14": "SUM(C2:C13)"}}],
        ["dates", "currency", "formulas", "freeze header", "autofilter"])
    add("Sales by Region", "sales by region with a column chart",
        [{"name": "Sales", "columns": [col("Region", "text"), col("Q1", "number", "#,##0"), col("Q2", "number", "#,##0")],
          "rows": [[r, 1200 + i * 310, 1350 + i * 280] for i, r in enumerate(REGIONS)],
          "chart": {"type": "column", "title": "Sales by region", "categories": "A2:A6", "values": ["B2:B6", "C2:C6"]}}],
        ["native chart", "column chart"])
    add("Grade Book", "a grade book with averages per student",
        [{"name": "Grades", "columns": [col("Student", "text"), col("Test 1", "number"), col("Test 2", "number"),
                                         col("Average", "number", "0.0")],
          "rows": [[n, 60 + (i * 7) % 40, 55 + (i * 11) % 45, None] for i, n in enumerate(["Ana", "Bo", "Chen", "Dee", "Eli", "Fay"])],
          "formulas": {f"D{r}": f"AVERAGE(B{r}:C{r})" for r in range(2, 8)}}],
        ["formulas", "number format"])
    add("Project Schedule", "a project schedule with start and end dates and a done flag",
        [{"name": "Schedule", "columns": [col("Task", "text"), col("Start", "date", "yyyy-mm-dd"), col("End", "date", "yyyy-mm-dd"),
                                           col("Done", "bool")],
          "rows": [["Plan", "2026-01-05", "2026-01-16", True], ["Build", "2026-01-19", "2026-03-27", False],
                   ["Test", "2026-03-30", "2026-04-24", False], ["Launch", "2026-04-27", "2026-04-30", False]]}],
        ["dates", "bool"])
    add("Conversion Rates", "conversion rates as percentages",
        [{"name": "Rates", "columns": [col("Channel", "text"), col("Visits", "number", "#,##0"), col("Rate", "percent", "0.0%")],
          "rows": [["Search", 12000, 0.034], ["Email", 4300, 0.081], ["Social", 9100, 0.012], ["Direct", 2500, 0.055]]}],
        ["percent"])
    add("Inventory 500", "an inventory list of 500 items",
        [{"name": "Inventory", "columns": [col("SKU", "text"), col("Region", "text"), col("Units", "number"),
                                            col("Value", "currency", "#,##0.00")],
          "rows": [[f"SKU-{i:04d}", REGIONS[i % 5], (i * 37) % 400, round(((i * 7919) % 90000) / 100 + 10, 2)] for i in range(500)]}],
        ["long table", "autofilter"])
    add("Two Sheet Report", "a workbook with a Summary sheet and a Detail sheet",
        [{"name": "Summary", "columns": [col("Metric", "text"), col("Value", "number", "#,##0")],
          "rows": [["Orders", 1520], ["Returns", 48], ["Customers", 610]]},
         {"name": "Detail", "columns": [col("Order", "text"), col("Date", "date", "yyyy-mm-dd"), col("Amount", "currency", "#,##0.00")],
          "rows": [[f"O-{i:03d}", MONTHS[i % 12], 20 + (i * 13) % 300] for i in range(40)]}],
        ["multi-sheet"])
    add("Line Chart Temperatures", "monthly temperatures with a line chart",
        [{"name": "Weather", "columns": [col("Month", "text"), col("High", "number", "0.0"), col("Low", "number", "0.0")],
          "rows": [[m, 8 + 12 * abs(6 - i) / -6 + 12, 1 + 8 * abs(6 - i) / -6 + 8] for i, m in enumerate(
              ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"])],
          "chart": {"type": "line", "title": "Temperatures", "categories": "A2:A13", "values": ["B2:B13", "C2:C13"]}}],
        ["line chart"])
    add("Market Share Pie", "market share with a pie chart",
        [{"name": "Share", "columns": [col("Brand", "text"), col("Share", "percent", "0%")],
          "rows": [["Alpha", 0.42], ["Beta", 0.31], ["Gamma", 0.17], ["Other", 0.10]],
          "chart": {"type": "pie", "title": "Market share", "categories": "A2:A5", "values": ["B2:B5"]}}],
        ["pie chart", "percent"])
    add("Height vs Weight", "a scatter chart of height against weight",
        [{"name": "Data", "columns": [col("Height (cm)", "number"), col("Weight (kg)", "number")],
          "rows": [[150 + i * 2, 50 + (i * 17) % 35] for i in range(20)],
          "chart": {"type": "scatter", "title": "Height vs weight", "categories": "A2:A21", "values": ["B2:B21"]}}],
        ["scatter chart"])
    add("Expense Bar Chart", "expenses per category with a bar chart",
        [{"name": "Expenses", "columns": [col("Category", "text"), col("Amount", "currency", "#,##0.00")],
          "rows": [["Rent", 1200], ["Food", 450.5], ["Travel", 230.25], ["Utilities", 180], ["Other", 95.75]],
          "chart": {"type": "bar", "title": "Expenses", "categories": "A2:A6", "values": ["B2:B6"]}}],
        ["bar chart", "currency"])
    add("Multilingual Contacts", "a contact list with names in several scripts",
        [{"name": "Contacts", "columns": [col("Name", "text"), col("City", "text"), col("Phone", "text")],
          "rows": [["Ελένη", "Αθήνα", "+30 210 000 0001"], ["Иван", "Москва", "+7 495 000 0002"], ["王芳", "北京", "+86 10 0000 0003"],
                   ["さくら", "東京", "+81 3 0000 0004"], ["지민", "서울", "+82 2 000 0005"], ["سارة", "القاهرة", "+20 2 0000 0006"],
                   ["דנה", "תל אביב", "+972 3 000 0007"]]}],
        ["greek", "cyrillic", "cjk", "arabic", "hebrew"])
    add("Loan Calculator", "a loan calculator with a PMT formula",
        [{"name": "Loan", "columns": [col("Item", "text"), col("Value", "number", "#,##0.00")],
          "rows": [["Principal", 20000], ["Annual rate", 0.05], ["Years", 5], ["Monthly payment", None]],
          "formulas": {"B5": "PMT(B3/12,B4*12,-B2)"}}],
        ["formula PMT"])
    add("Timesheet", "a weekly timesheet with hours and a total",
        [{"name": "Week 45", "columns": [col("Day", "text"), col("Hours", "number", "0.00")],
          "rows": [[d, h] for d, h in zip(["Mon", "Tue", "Wed", "Thu", "Fri"], [7.5, 8, 8.25, 6.75, 8])],
          "formulas": {"A7": '"Total"', "B7": "SUM(B2:B6)"}}],
        ["formulas"])
    add("Wide Survey Table", "a survey table with 20 question columns",
        [{"name": "Survey", "columns": [col("Respondent", "text")] + [col(f"Q{i}", "number") for i in range(1, 21)],
          "rows": [[f"R{r:02d}"] + [((r * 7 + q * 3) % 5) + 1 for q in range(1, 21)] for r in range(1, 31)]}],
        ["wide table"])
    add("Stock Prices", "daily closing prices with dates and a line chart",
        [{"name": "Prices", "columns": [col("Date", "date", "yyyy-mm-dd"), col("Close", "currency", "#,##0.00")],
          "rows": [[f"2026-10-{d:02d}", round(100 + ((d * 37) % 23) - 11 + d * 0.4, 2)] for d in range(1, 31)],
          "chart": {"type": "line", "title": "Closing price", "categories": "A2:A31", "values": ["B2:B31"]}}],
        ["dates", "line chart"])
    add("Team Roster", "a team roster without frozen header and without filter",
        [{"name": "Roster", "columns": [col("Name", "text"), col("Role", "text")], "freeze_header": False, "autofilter": False,
          "rows": [["Ana", "Lead"], ["Bo", "Design"], ["Chen", "Engineering"]]}],
        ["no freeze", "no autofilter"])
    add("Fixed Column Widths", "a table with explicit column widths",
        [{"name": "Widths", "columns": [col("Code", "text"), col("Description", "text")], "column_widths": [10, 50],
          "rows": [["A1", "First item with a long description"], ["B2", "Second"]]}],
        ["column widths"])
    add("Exchange Rates", "currency exchange rates with four decimals",
        [{"name": "FX", "columns": [col("Pair", "text"), col("Rate", "number", "0.0000")],
          "rows": [["EUR/USD", 1.0832], ["GBP/USD", 1.2711], ["USD/JPY", 151.2245], ["USD/CHF", 0.8812]]}],
        ["number format"])
    add("Quarterly Totals", "quarterly totals with SUM formulas across columns",
        [{"name": "Totals", "columns": [col("Line", "text"), col("Q1", "number"), col("Q2", "number"), col("Q3", "number"),
                                         col("Q4", "number"), col("Year", "number")],
          "rows": [[f"Line {i}", 100 * i, 110 * i, 120 * i, 130 * i, None] for i in range(1, 6)],
          "formulas": {f"F{r}": f"SUM(B{r}:E{r})" for r in range(2, 7)}}],
        ["formulas"])
    add("Attendance", "attendance as yes/no booleans per day",
        [{"name": "Attendance", "columns": [col("Name", "text"), col("Mon", "bool"), col("Tue", "bool"), col("Wed", "bool")],
          "rows": [["Ana", True, True, False], ["Bo", False, True, True], ["Chen", True, False, True]]}],
        ["bool"])
    add("Recipe Costs", "recipe ingredient costs with a cost-per-portion formula",
        [{"name": "Costs", "columns": [col("Ingredient", "text"), col("Cost", "currency", "#,##0.00")],
          "rows": [["Flour", 1.2], ["Eggs", 2.5], ["Milk", 0.9], ["Lemon", 0.6], ["Portions", 4]],
          "formulas": {"A7": '"Per portion"', "B7": "SUM(B2:B5)/B6"}}],
        ["formulas", "currency"])
    add("Event Budget Chart", "an event budget with a column chart of planned vs spent",
        [{"name": "Event", "columns": [col("Item", "text"), col("Planned", "currency", "#,##0"), col("Spent", "currency", "#,##0")],
          "rows": [["Venue", 3000, 3200], ["Food", 1800, 1650], ["Music", 900, 900], ["Decor", 400, 520]],
          "chart": {"type": "column", "title": "Planned vs spent", "categories": "A2:A5", "values": ["B2:B5", "C2:C5"]}}],
        ["column chart", "currency"])
    add("Three Sheet Workbook", "a workbook with three sheets for three years",
        [{"name": str(y), "columns": [col("Month", "text"), col("Revenue", "number", "#,##0")],
          "rows": [[m, 1000 + (y - 2024) * 200 + i * 30] for i, m in enumerate(["Jan", "Feb", "Mar", "Apr"])]}
         for y in (2024, 2025, 2026)],
        ["multi-sheet"])
    add("Big Numbers", "large numbers with thousands separators",
        [{"name": "Population", "columns": [col("Country", "text"), col("Population", "number", "#,##0")],
          "rows": [["A-land", 83240000], ["B-land", 67750000], ["C-land", 5480000], ["D-land", 1331000]]}],
        ["number format"])
    add("Negative Values", "profit and loss with negative values in red",
        [{"name": "P&L", "columns": [col("Month", "text"), col("Profit", "number", "#,##0;[Red]-#,##0")],
          "rows": [["Jan", 1200], ["Feb", -340], ["Mar", 560], ["Apr", -80]]}],
        ["number format", "negative red"])
    add("Text Heavy Notes", "a notes table with long text cells",
        [{"name": "Notes", "columns": [col("Topic", "text"), col("Note", "text")],
          "rows": [[f"Topic {i}", "A long note that wraps over several words to check the automatic column width cap. " * 2]
                   for i in range(1, 6)]}],
        ["long text", "auto width"])
    add("Mixed Types", "a table mixing text, numbers, dates, booleans and percentages",
        [{"name": "Mixed", "columns": [col("Text", "text"), col("Number", "number"), col("Date", "date", "yyyy-mm-dd"),
                                        col("Flag", "bool"), col("Share", "percent", "0%")],
          "rows": [["a", 1, "2026-01-01", True, 0.1], ["b", 2.5, "2026-02-15", False, 0.25], ["c", -3, "2026-03-31", True, 1]]}],
        ["mixed types"])
    add("Arabic Hebrew Prices", "a price list with Arabic and Hebrew product names",
        [{"name": "Prices", "columns": [col("Product", "text"), col("Price", "currency", "#,##0.00")],
          "rows": [["قهوة", 12.5], ["شاي", 8.0], ["לחם", 9.9], ["חלב", 6.5]]}],
        ["arabic", "hebrew", "currency"])
    add("Everything Workbook", "a workbook using every feature: formats, formulas, chart, two sheets and booleans",
        [{"name": "Data", "columns": [col("Item", "text"), col("Date", "date", "yyyy-mm-dd"), col("Qty", "number"),
                                       col("Price", "currency", "#,##0.00"), col("Total", "currency", "#,##0.00"), col("Paid", "bool")],
          "rows": [[f"Item {i}", MONTHS[i % 12], i + 1, 10 + i * 2.5, None, i % 2 == 0] for i in range(10)],
          "formulas": {f"E{r}": f"C{r}*D{r}" for r in range(2, 12)},
          "chart": {"type": "column", "title": "Totals", "categories": "A2:A11", "values": ["E2:E11"]}},
         {"name": "Info", "columns": [col("Key", "text"), col("Value", "text")], "rows": [["Made by", "AntiChat"], ["Ελληνικά", "日本語"]]}],
        ["everything"])
    assert len(t) == 30, len(t)
    return t


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="fixtures")
    ap.add_argument("--formats", default="pdf,docx,md,xlsx,csv")
    a = ap.parse_args()
    specs = os.path.join(a.out, "docs", "golden-out", "specs")
    prompts = os.path.join(a.out, "prompts", "fileout-golden")
    os.makedirs(specs, exist_ok=True)
    os.makedirs(prompts, exist_ok=True)
    with open(os.path.join(specs, "images.json"), "w") as f:
        json.dump(IMAGES, f, indent=1, sort_keys=True)
        f.write("\n")
    for fmt in a.formats.split(","):
        rows = []
        if fmt == "pptx":
            for i, tp in enumerate(deck_topics(), start=1):
                pid = f"pptx-{i:02d}"
                spec = {"filename": tp["filename"], "theme": tp["theme"], "slides": tp["slides"]}
                with open(os.path.join(specs, f"{pid}.json"), "w") as f:
                    json.dump(spec, f, ensure_ascii=False, indent=1, sort_keys=True)
                    f.write("\n")
                rows.append({"id": pid, "format": "pptx", "prompt": tp["prompt"] + (" Use the attached photos." if tp["images"] else ""),
                             "features": [tp["theme"]] + sorted({s["layout"] for s in tp["slides"]}), "images": tp["images"]})
            with open(os.path.join(a.out, "prompts", "pptx-golden-20.jsonl"), "w") as f:
                for r in rows:
                    f.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")
            print("pptx: 20 prompts, 20 specs")
            continue
        if fmt in ("xlsx", "csv"):
            for i, tp in enumerate(sheet_topics(), start=1):
                pid = f"{fmt}-{i:02d}"
                sheets = tp["sheets"] if fmt == "xlsx" else [{k: v for k, v in tp["sheets"][0].items()
                                                              if k in ("name", "columns", "rows")}]
                if fmt == "csv":  # CSV has no formulas: fill formula cells with nothing
                    sheets[0]["rows"] = [["" if v is None else v for v in r] for r in sheets[0]["rows"]]
                spec = {"filename": tp["filename"], "format": fmt, "sheets": sheets}
                with open(os.path.join(specs, f"{pid}.json"), "w") as f:
                    json.dump(spec, f, ensure_ascii=False, indent=1, sort_keys=True)
                    f.write("\n")
                rows.append({"id": pid, "format": fmt, "prompt": f"Make me a {NAMES[fmt]} named \"{tp['filename']}\": {tp['prompt']}.",
                             "features": tp["features"], "images": []})
            with open(os.path.join(prompts, f"{fmt}-30.jsonl"), "w") as f:
                for r in rows:
                    f.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")
            print(f"{fmt}: 30 prompts, 30 specs")
            continue
        for i, tp in enumerate(topics(), start=1):
            pid = f"{fmt}-{i:02d}"
            spec = {"format": fmt, "title": tp["title"], "markdown": tp["markdown"]}
            for k in ("page_size", "style", "images"):
                if k in tp:
                    spec[k] = tp[k]
            with open(os.path.join(specs, f"{pid}.json"), "w") as f:
                json.dump(spec, f, ensure_ascii=False, indent=1, sort_keys=True)
                f.write("\n")
            att = " (use the attached photos)" if "images" in tp else ""
            rows.append({"id": pid, "format": fmt,
                         "prompt": f"Make me a {NAMES[fmt]} titled \"{tp['title']}\": {tp['prompt']}{att}.",
                         "features": tp["features"], "images": [im["ref"] for im in tp.get("images", [])]})
        with open(os.path.join(prompts, f"{fmt}-30.jsonl"), "w") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")
        print(f"{fmt}: 30 prompts, 30 specs")


if __name__ == "__main__":
    main()
