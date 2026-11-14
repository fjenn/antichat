#!/usr/bin/env python3
"""AT-245 fixtures (M8.T05, R-245): the 50-question project set and the small whole-context project.

  fixtures/projects/qa-50/docs/             120 synthetic documents of one fictional co-operative ("Kestrel Valley
                                            Co-operative"): 60 PDF (page numbers in the footer), 25 Markdown, 20 DOCX,
                                            15 XLSX; ≈ 1.5 M tokens in total (chat-9b-q4 tokenizer)
  fixtures/projects/qa-50/questions.jsonl   50 lines {"q", "answer_regex", "file", "page", "kind"}: one planted fact per
                                            question. page = the physical PDF page index (1-based), the sheet name for
                                            XLSX, null for Markdown / DOCX (one section: the file is the citation)
  fixtures/projects/qa-50/small/            3 documents (Markdown, text, 2-page PDF), ≤ 3,500 tokens together, so they
                                            stay under 30 % of the T1 default context (chat-9b-q4 at 16,384 →
                                            budget 4,915; asserted against catalog/assignments.yaml)
  fixtures/projects/qa-50/questions-small.jsonl  10 questions on small/
  fixtures/projects/qa-50/SOURCES.md

Every fact family (inspection permits, generator service, appointments, cold-store capacity, votes, rents, …) is
planted for many sites, so a question names a site and the distractors share its wording: retrieval has to find the
right (family, site) pair among ≈ 3,700 chunks. Each (family, site) pair exists exactly once in the corpus. Text is
generated from fixed templates and word lists (seed 50), CC0.

Usage: tools/.venv/bin/python3 -I tools/fixtures/make-project-qa.py --out fixtures [--seed 50] [--tokenizer <json>]
"""
from __future__ import annotations

import argparse
import io
import json
import os
import random
import re
import shutil

ORG = "Kestrel Valley Co-operative"
SITES = ("Ashford Brindle Calder Dunmore Elsworth Fenwick Garrow Halden Iverly Jessop Kelby Larkin Merrow Norbury "
         "Oakham Pendle Quarles Rothby Selwick Tamsin Ulgate Varden Whitby Yarrow Zennor").split()
FIRST = ("Amira Bram Celia Dario Edith Farid Greta Hollis Ines Joaquin Kira Linus Maren Nadia Osric Petra Quentin Rosa "
         "Soren Talia Umar Vera Wendell Xenia Yusuf Zora").split()
LAST = ("Abernethy Blackwood Castellano Driscoll Eriksen Fairweather Gallagher Holloway Ibarra Jankowski Kowalczyk "
        "Lindqvist Moreau Nakamura Okonkwo Pemberton Quintero Rasmussen Sandoval Thorne Underhill Valdivia Whitlock "
        "Yamamoto Zielinski").split()
VENDORS = ("Brightline Power Services|Copperfield Electrical|Dunlin Generator Works|Harrow & Finch Engineering|"
           "Ironbridge Plant Hire|Marlow Standby Systems|Northgate Diesel|Orchid Field Mechanical|Pellham Energy Care|"
           "Quayside Motors|Redcap Maintenance|Saltmarsh Technical|Tidewater Power|Upland Service Co.|"
           "Vantage Auxiliary Power|Wexley Engines").split("|")
ROLES = ["site safety lead", "stock controller", "member liaison officer", "fleet coordinator", "quality steward",
         "training coordinator"]
PROPOSALS = ["solar canopy proposal", "four-day delivery week", "shared tool library", "bulk seed purchasing plan",
             "night-shift rota", "member discount scheme"]
MONTHS = "January February March April May June July August September October November December".split()
DEPTS = ["logistics", "membership", "finance", "maintenance", "grading", "packing", "procurement", "training"]
TOPICS = ["pallet rotation", "the spring intake schedule", "loading-bay lighting", "member onboarding", "spoilage rates",
          "fuel cards", "the grading backlog", "crate deposits", "shift handovers", "cold-chain logging",
          "supplier invoices", "the volunteer roster", "forklift charging", "returns handling", "label printing",
          "the delivery map", "seed storage humidity", "rainwater tanks", "hedge maintenance", "the canteen budget"]
ITEMS = ["pallet truck", "label printer", "chest freezer", "moisture meter", "forklift battery", "hand truck",
         "vacuum sealer", "weighing scale", "laptop", "radio handset", "pressure washer", "dehumidifier"]

FILLER = [
    "The {site} {dept} team reviewed {topic} during the {month} meeting and agreed to revisit {topic2} next quarter.",
    "Members at {site} raised {topic} again, and the {dept} group promised a written answer before the end of {month}.",
    "A short note on {topic}: the {site} figures for {month} were in line with the co-operative average.",
    "Volunteers from {site} helped the {dept} team with {topic} over three weekends in {month}.",
    "The board asked every site, including {site}, to report on {topic} using the shared template.",
    "In {month} the {dept} group at {site} trialled a simpler checklist for {topic} and kept it.",
    "Comments on {topic} from the {site} members' evening were passed to the {dept} committee.",
    "No change to {topic} is planned at {site} until the {dept} review of {topic2} is finished.",
    "The {site} newsletter for {month} covered {topic}, {topic2} and the usual notices from {dept}.",
    "Staff at {site} noted that {topic} takes longer in {month} because of the seasonal intake.",
    "The {dept} lead thanked the {site} crew for keeping {topic} on track during a busy {month}.",
    "A follow-up on {topic2} at {site} found nothing that needs action from {dept} this year.",
]

# Fact families: sentence, question, answer (+ regex). Values come from `value(rng)`.
def _code(rng, p):
    return f"{p}-{rng.randint(1000, 9999)}"


def _date(rng):
    return f"{rng.randint(2, 27)} {rng.choice(MONTHS)}"


def _person(rng):
    return f"{rng.choice(FIRST)} {rng.choice(LAST)}"


FAMILIES = {
    "fire": dict(
        value=lambda rng, s: _code(rng, s[:2].upper() + "F"),
        sentence="The {site} warehouse fire inspection is booked for {extra} under permit {v}.",
        extra=_date,
        q="Under which permit number is the {site} warehouse fire inspection booked?",
    ),
    "generator": dict(
        value=lambda rng, s: rng.choice(VENDORS),
        sentence="The backup generator at the {site} depot was last serviced by {v} on {extra}.",
        extra=_date,
        q="Which company last serviced the backup generator at the {site} depot?",
    ),
    "appoint": dict(
        value=lambda rng, s: _person(rng),
        sentence="{v} has been appointed {extra} for the {site} site.",
        extra=lambda rng: rng.choice(ROLES),
        q="Who has been appointed {extra} for the {site} site?",
    ),
    "coldstore": dict(
        value=lambda rng, s: str(rng.randint(41, 480)),
        sentence="The {site} cold-store can hold at most {v} pallets once the {extra} racking is installed.",
        extra=lambda rng: rng.choice(["new", "second", "mezzanine", "mobile"]),
        q="How many pallets can the {site} cold-store hold at most?",
    ),
    "vote": dict(
        value=lambda rng, s: str(rng.randint(51, 94)),
        sentence="At the {site} general meeting, {v} percent of members voted in favour of the {extra}.",
        extra=lambda rng: rng.choice(PROPOSALS),
        q="What percentage of {site} members voted in favour of the {extra}?",
    ),
    "rent": dict(
        value=lambda rng, s: f"£{rng.randint(18, 96)},{rng.choice(['000', '250', '500', '750'])}",
        sentence="After the {extra} review, the annual rent of the {site} branch rose to {v}.",
        extra=lambda rng: rng.choice(MONTHS),
        q="What did the annual rent of the {site} branch rise to?",
    ),
    "route": dict(
        value=lambda rng, s: f"Route {rng.randint(11, 98)}{rng.choice('ABCDEFGH')}",
        sentence="Deliveries from {site} to the {extra} market now run on {v}.",
        extra=lambda rng: rng.choice(["Thursday", "Saturday", "farmers'", "harbour", "evening"]),
        q="Which route do deliveries from {site} to the {extra} market run on?",
    ),
    "audit": dict(
        value=lambda rng, s: rng.choice(["amber", "green", "red"]) + " rating with " + str(rng.randint(2, 19)) + " findings",
        sentence="The {extra} food-safety audit gave the {site} packing hall a {v}.",
        extra=lambda rng: rng.choice(MONTHS),
        q="What result did the {site} packing hall get in its food-safety audit?",
    ),
}


def answer_regex(fam: str, v: str) -> str:
    if fam == "rent":
        return re.escape(v).replace(",", ",?")
    if fam == "audit":
        colour, rest = v.split(" rating with ")
        n = rest.split()[0]
        return rf"(?is)\b{colour}\b.{{0,40}}\b{n}\b|\b{n}\b.{{0,40}}\b{colour}\b"
    if fam == "appoint":
        first, last = v.split()
        return rf"{re.escape(first)}\s+{re.escape(last)}"
    if fam == "generator":
        return re.escape(v.split()[0])
    if fam == "route":
        return re.escape(v).replace(r"\ ", r"\s*")
    return rf"\b{re.escape(v)}\b"


def filler(rng: random.Random, n: int) -> list[str]:
    out = []
    for _ in range(n):
        t = rng.choice(FILLER)
        a, b = rng.sample(TOPICS, 2)
        out.append(t.format(site=rng.choice(SITES), dept=rng.choice(DEPTS), topic=a, topic2=b, month=rng.choice(MONTHS)))
    return out


class Planner:
    """Hands out (family, site) pairs, each once: gold facts first, distractors after."""

    def __init__(self, rng: random.Random):
        self.rng = rng
        self.pairs = [(f, s) for f in FAMILIES for s in SITES]
        rng.shuffle(self.pairs)

    def take(self):
        return self.pairs.pop() if self.pairs else None

    def fact(self, pair):
        fam, site = pair
        F = FAMILIES[fam]
        v = F["value"](self.rng, site)
        extra = F["extra"](self.rng)
        return dict(fam=fam, site=site, v=v, extra=extra, sentence=F["sentence"].format(site=site, v=v, extra=extra),
                    q=F["q"].format(site=site, extra=extra))


# ---- writers ----

def make_pdf(title: str, pages: list[list[str]]) -> bytes:
    from reportlab.lib.pagesizes import A4
    from reportlab.pdfgen import canvas
    buf = io.BytesIO()
    c = canvas.Canvas(buf, pagesize=A4, invariant=1)
    c.setTitle(title)
    n = len(pages)
    for i, sentences in enumerate(pages, 1):
        t = c.beginText(56, 790)
        t.setFont("Helvetica-Bold", 10)
        t.textLine(f"{ORG} — {title}")
        t.setFont("Helvetica", 9)
        t.textLine("")
        line = ""
        for s in sentences:
            for w in s.split():
                if len(line) + len(w) + 1 > 104:
                    t.textLine(line)
                    line = w
                else:
                    line = f"{line} {w}".strip()
        if line:
            t.textLine(line)
        c.drawText(t)
        c.setFont("Helvetica", 8)
        c.drawCentredString(297, 30, f"Page {i} of {n}")
        c.showPage()
    c.save()
    return buf.getvalue()


def make_docx(title: str, sections: list[tuple[str, list[str]]]) -> bytes:
    import docx  # python-docx
    d = docx.Document()
    d.core_properties.author = ORG
    d.core_properties.created = __import__("datetime").datetime(2026, 1, 1)
    d.core_properties.modified = __import__("datetime").datetime(2026, 1, 1)
    d.add_heading(title, level=1)
    for h, paras in sections:
        d.add_heading(h, level=2)
        for p in paras:
            d.add_paragraph(p)
    buf = io.BytesIO()
    d.save(buf)
    return normalize_zip(buf.getvalue())


def make_xlsx(title: str, sheet: str, header: list[str], rows: list[list]) -> bytes:
    import openpyxl
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = sheet
    ws.append(header)
    for r in rows:
        ws.append(r)
    wb.properties.creator = ORG
    wb.properties.title = title
    dt = __import__("datetime").datetime(2026, 1, 1)
    wb.properties.created = dt
    wb.properties.modified = dt
    buf = io.BytesIO()
    wb.save(buf)
    return normalize_zip(buf.getvalue())


def normalize_zip(data: bytes) -> bytes:
    """Fixed timestamps inside the OOXML zip (byte-identical re-runs)."""
    import zipfile
    src = zipfile.ZipFile(io.BytesIO(data))
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for info in src.infolist():
            body = src.read(info.filename)
            if info.filename == "docProps/core.xml":
                body = re.sub(rb"<dcterms:(created|modified)([^>]*)>[^<]*<", rb"<dcterms:\1\2>2026-01-01T00:00:00Z<", body)
            zi = zipfile.ZipInfo(info.filename, date_time=(2026, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, body)
    return out.getvalue()


def counter(path: str):
    try:
        from tokenizers import Tokenizer
        tok = Tokenizer.from_file(path)
        return (lambda s: len(tok.encode(s).ids)), "chat-9b-q4 tokenizer.json"
    except Exception:
        return (lambda s: int(len(s.split()) * 1.3)), "words*1.3"


def t1_context(root: str) -> int:
    text = open(os.path.join(root, "catalog/assignments.yaml"), encoding="utf-8").read()
    block = text.split("\n  T1:\n", 1)[1]
    m = re.search(r"chat: \{normal: \{model: chat-9b-q4, ctx: (\d+)", block)
    assert m, "assignments.yaml: T1 chat-9b-q4 ctx not found"
    return int(m.group(1))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="the fixtures checkout")
    ap.add_argument("--seed", type=int, default=50)
    ap.add_argument("--tokenizer", default=os.path.expanduser(
        "~/Library/Application Support/AntiChat-Dev/Models/chat-9b-q4/tokenizer.json"))
    a = ap.parse_args()
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    rng = random.Random(a.seed)
    count, tok_name = counter(a.tokenizer)
    base = os.path.join(a.out, "projects/qa-50")
    if os.path.isdir(base):
        shutil.rmtree(base)
    docs_dir = os.path.join(base, "docs")
    os.makedirs(docs_dir)
    planner = Planner(rng)

    # 120 documents; 50 carry one gold fact each (32 PDF, 7 MD, 6 DOCX, 5 XLSX), every document carries 1–2 distractors.
    kinds = ["pdf"] * 60 + ["md"] * 25 + ["docx"] * 20 + ["xlsx"] * 15
    gold_quota = {"pdf": 32, "md": 7, "docx": 6, "xlsx": 5}
    by_kind = {k: [i for i, x in enumerate(kinds) if x == k] for k in gold_quota}
    gold_docs = set()
    for k, n in gold_quota.items():
        gold_docs.update(rng.sample(by_kind[k], n))
    doc_titles = ["site report", "operations handbook", "board minutes", "member bulletin", "maintenance log",
                  "quarterly review", "logistics plan", "training notes", "procurement summary", "safety bulletin"]
    questions = []
    total_tokens = 0
    tags_used = set()
    manifest = []
    for i, kind in enumerate(kinds):
        site = rng.choice(SITES)
        title = f"{site} {rng.choice(doc_titles)} {2024 + i % 3}"
        slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
        name = f"{i + 1:03d}-{slug}.{kind}"
        path = os.path.join(docs_dir, name)
        gold = planner.fact(planner.take()) if i in gold_docs and kind != "xlsx" else None
        distractors = [planner.fact(p) for p in (planner.take() for _ in range(rng.randint(1, 2))) if p]
        text_for_count = ""
        if kind == "pdf":
            n_pages = rng.randint(14, 42)
            pages = [filler(rng, rng.randint(24, 30)) for _ in range(n_pages)]
            plants = ([gold] if gold else []) + distractors
            gold_page = None
            for f in plants:
                p = rng.randint(2, n_pages)  # never the first page: the answer must come from retrieval, not the title
                pages[p - 1].insert(rng.randint(3, len(pages[p - 1]) - 3), f["sentence"])
                if f is gold:
                    gold_page = p
            open(path, "wb").write(make_pdf(title.title(), pages))
            text_for_count = "\n".join(" ".join(p) for p in pages)
            if gold:
                questions.append(dict(q=gold["q"], answer_regex=answer_regex(gold["fam"], gold["v"]), file=name,
                                      page=gold_page, kind="pdf", answer=gold["v"]))
        elif kind in ("md", "docx"):
            n_sec = rng.randint(6, 12)
            sections = [(f"{rng.choice(TOPICS).capitalize()} at {rng.choice(SITES)}",
                         [" ".join(filler(rng, rng.randint(4, 7))) for _ in range(rng.randint(5, 9))]) for _ in range(n_sec)]
            for f in ([gold] if gold else []) + distractors:
                s = rng.randint(1, n_sec - 1)
                paras = sections[s][1]
                j = rng.randrange(len(paras))
                sents = paras[j].split(". ")
                sents.insert(rng.randint(1, len(sents) - 1), f["sentence"].rstrip("."))
                paras[j] = ". ".join(sents)
            if kind == "md":
                body = f"# {title.title()}\n\n_{ORG}_\n\n" + "\n\n".join(
                    f"## {h}\n\n" + "\n\n".join(ps) for h, ps in sections) + "\n"
                open(path, "w", encoding="utf-8").write(body)
                text_for_count = body
            else:
                open(path, "wb").write(make_docx(title.title(), sections))
                text_for_count = "\n".join(h + "\n" + "\n".join(ps) for h, ps in sections)
            if gold:
                questions.append(dict(q=gold["q"], answer_regex=answer_regex(gold["fam"], gold["v"]), file=name,
                                      page=None, kind=kind, answer=gold["v"]))
        else:  # xlsx asset register
            sheet = "Assets"
            header = ["Asset tag", "Site", "Item", "Purchased", "Cost (GBP)", "Custodian"]
            rows = []
            for _ in range(rng.randint(260, 420)):
                while True:
                    tag = f"KV-{rng.randint(10000, 99999)}"
                    if tag not in tags_used:
                        tags_used.add(tag)
                        break
                rows.append([tag, rng.choice(SITES), rng.choice(ITEMS), f"{rng.randint(2019, 2025)}-{rng.randint(1, 12):02d}",
                             rng.randint(40, 9000), _person(rng)])
            open(path, "wb").write(make_xlsx(title.title(), sheet, header, rows))
            text_for_count = "\n".join("| " + " | ".join(map(str, r)) + " |" for r in [header] + rows)
            if i in gold_docs:
                r = rng.choice(rows[5:])
                first, last = r[5].split()
                questions.append(dict(q=f"Who is the custodian of asset {r[0]} in the asset register?",
                                      answer_regex=rf"{first}\s+{last}", file=name, page=sheet, kind="xlsx", answer=r[5]))
        t = count(text_for_count)
        total_tokens += t
        manifest.append(dict(file=name, kind=kind, tokens=t))
    assert len(questions) == 50, len(questions)
    rng.shuffle(questions)
    with open(os.path.join(base, "questions.jsonl"), "w", encoding="utf-8") as f:
        for q in questions:
            f.write(json.dumps(q, ensure_ascii=False, sort_keys=True) + "\n")

    # small/: three short documents, whole-context mode at T1
    small = os.path.join(base, "small")
    os.makedirs(small)
    sq = []
    facts_small = [
        ("The pottery studio opens at 7:30 on weekdays and at 9:00 on Saturdays.", "When does the pottery studio open on Saturdays?", r"9[:.]00|nine"),
        ("Glaze batch G-17 uses 42 percent feldspar.", "What percentage of feldspar does glaze batch G-17 use?", r"\b42\b"),
        ("The large kiln is called Bertha and fires to cone 10.", "What is the large kiln called?", r"Bertha"),
        ("Members may store up to six pieces on the drying shelves.", "How many pieces may a member store on the drying shelves?", r"\b(six|6)\b"),
        ("Clay is ordered from Millbrook Clays every second Tuesday.", "From which supplier is clay ordered?", r"Millbrook"),
    ]
    md = "# Studio handbook\n\n" + "\n\n".join(
        " ".join([f[0]] + [s.replace("Kestrel", "Studio") for s in filler(rng, 3)]) for f in facts_small) + "\n"
    open(os.path.join(small, "studio-handbook.md"), "w", encoding="utf-8").write(md)
    sq += [dict(q=q, answer_regex=r, file="studio-handbook.md", page=None, kind="md") for _, q, r in facts_small]
    facts_txt = [
        ("The beginners' wheel class runs on Monday evenings from 18:00.", "On which evening does the beginners' wheel class run?", r"Monday"),
        ("The raku workshop costs 35 pounds per person.", "How much does the raku workshop cost per person?", r"\b35\b"),
        ("Children's clay club meets in Room B.", "Where does the children's clay club meet?", r"Room\s*B"),
    ]
    txt = "Class schedule\n\n" + "\n".join(" ".join([f[0]] + filler(rng, 2)) for f in facts_txt) + "\n"
    open(os.path.join(small, "class-schedule.txt"), "w", encoding="utf-8").write(txt)
    sq += [dict(q=q, answer_regex=r, file="class-schedule.txt", page=None, kind="txt") for _, q, r in facts_txt]
    facts_pdf = [
        ("Dust masks of class FFP3 must be worn when mixing dry glaze.", "Which class of dust mask must be worn when mixing dry glaze?", r"FFP3", 1),
        ("The fire blanket hangs next to the north door.", "Where does the fire blanket hang?", r"north\s+door", 2),
    ]
    pdf_pages = [[facts_pdf[0][0]] + filler(rng, 4), [facts_pdf[1][0]] + filler(rng, 4)]
    open(os.path.join(small, "safety-sheet.pdf"), "wb").write(make_pdf("Studio Safety Sheet", pdf_pages))
    sq += [dict(q=q, answer_regex=r, file="safety-sheet.pdf", page=p, kind="pdf") for _, q, r, p in facts_pdf]
    small_text = md + txt + "\n".join(" ".join(p) for p in pdf_pages)
    small_tokens = count(small_text)
    ctx = t1_context(root)
    budget = int(ctx * 0.30)
    assert small_tokens <= 3500 and len(small_text) / 4 <= 3500, (small_tokens, len(small_text) / 4)
    assert small_tokens < budget, (small_tokens, budget)
    assert len(sq) == 10
    with open(os.path.join(base, "questions-small.jsonl"), "w", encoding="utf-8") as f:
        for q in sq:
            f.write(json.dumps(q, ensure_ascii=False, sort_keys=True) + "\n")

    assert 1_300_000 <= total_tokens <= 1_700_000, total_tokens
    with open(os.path.join(base, "SOURCES.md"), "w", encoding="utf-8") as f:
        f.write(f"""# fixtures/projects/qa-50 (M8.T05, AT-245)

Generated by `tools/fixtures/make-project-qa.py --seed {a.seed}` (synthetic text from fixed templates and word lists;
CC0). {ORG} is fictional.

- `docs/`: 120 documents (60 PDF, 25 Markdown, 20 DOCX, 15 XLSX), {total_tokens:,} tokens ({tok_name}).
- `questions.jsonl`: 50 planted facts; `page` = physical PDF page (1-based), XLSX sheet name, null = the file.
- `small/`: 3 documents, {small_tokens:,} tokens — under the T1 whole-context budget ({budget:,} = 30 % of {ctx:,}).
- `questions-small.jsonl`: 10 questions on `small/`.
""")
    print(f"[ok] qa-50: 120 docs, {total_tokens:,} tokens ({tok_name}); 50 questions; small {small_tokens} tokens "
          f"(budget {budget}) -> {base}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
