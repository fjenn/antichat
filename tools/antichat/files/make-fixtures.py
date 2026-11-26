#!/usr/bin/env python3
"""Fixtures with known answers for the files engine (M10).

    PYTHONPATH=<dir with reportlab python-docx openpyxl python-pptx Pillow> \
        tools/antichat/files/make-fixtures.py

Writes tools/antichat/files/fixtures/ and fixtures/answers.json. Deterministic.
"""
import csv
import datetime
import json
import os
import random

from docx import Document
from docx.enum.text import WD_BREAK
from openpyxl import Workbook
from PIL import Image, ImageDraw, ImageFilter, ImageFont
from pptx import Presentation
from reportlab.lib.pagesizes import A4
from reportlab.lib.utils import ImageReader
from reportlab.pdfgen import canvas

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fixtures')
os.makedirs(OUT, exist_ok=True)
rng = random.Random(20261124)
answers = {}


def wrap(text, width=92):
    words, lines, line = text.split(), [], ''
    for word in words:
        if len(line) + len(word) + 1 > width:
            lines.append(line)
            line = word
        else:
            line = (line + ' ' + word).strip()
    if line:
        lines.append(line)
    return lines


def text_pdf(name, pages):
    c = canvas.Canvas(os.path.join(OUT, name), pagesize=A4, pageCompression=1, invariant=1)
    for number, (title, paragraphs) in enumerate(pages, 1):
        y = 790
        c.setFont('Helvetica-Bold', 14)
        c.drawString(60, y, title)
        y -= 26
        c.setFont('Helvetica', 10.5)
        for paragraph in paragraphs:
            for line in wrap(paragraph):
                c.drawString(60, y, line)
                y -= 14
            y -= 8
        c.setFont('Helvetica', 9)
        c.drawString(280, 40, f'Page {number}')
        c.showPage()
    c.save()


# ---- three-pages.pdf
text_pdf('three-pages.pdf', [
    ('Northwind Travel Policy - Allowances', [
        'This policy applies to every employee of Northwind Cartography who travels for work.',
        'The daily meal allowance in Lisbon is 47 euros. Receipts are not required for meals under this amount.',
        'Employees based in the Rotterdam office must book rail travel for any journey shorter than 400 kilometres.',
    ]),
    ('Northwind Travel Policy - Booking', [
        'All flights are booked through the travel desk, which is reachable at extension 3319.',
        'Hotel bookings may not exceed 165 euros per night unless the regional director approves in writing.',
        'Changes made less than two days before departure are charged to the cost centre of the traveller.',
    ]),
    ('Northwind Travel Policy - Reimbursement', [
        'Expense reports must be filed within 21 days of returning from a trip.',
        'Mileage for private cars is reimbursed at 0.38 euros per kilometre.',
        'Questions about this policy go to Marguerite Oyelaran in the finance team.',
    ]),
])
answers['three-pages.pdf'] = [
    {'q': 'What is the daily meal allowance in Lisbon?', 'a': '47 euros', 'page': 1},
    {'q': 'What is the hotel limit per night?', 'a': '165 euros', 'page': 2},
    {'q': 'Within how many days must expense reports be filed?', 'a': '21 days', 'page': 3},
]

# ---- handbook-200.pdf
TOPICS = ['warehouse safety', 'shift planning', 'vehicle maintenance', 'customer returns',
          'inventory counts', 'cold storage', 'route planning', 'onboarding', 'quality checks',
          'packaging standards', 'supplier audits', 'incident reports']
SENTENCES = [
    'Team leads review the {t} checklist at the start of every shift and record the result in the logbook.',
    'When a problem with {t} is found, it is reported to the duty manager before the end of the working day.',
    'New colleagues shadow an experienced operator for two weeks before working on {t} alone.',
    'The {t} procedure is reviewed every quarter and changes are announced in the Monday briefing.',
    'Records about {t} are kept for five years and may be inspected by the regional office at any time.',
    'Good practice in {t} depends on clear handovers, tidy workstations and honest reporting of near misses.',
    'Every depot keeps a printed copy of the {t} guidance next to the main entrance.',
    'Training material for {t} is available in four languages on the internal portal.',
    'Small improvements to {t} suggested by staff are collected monthly and the best one is rewarded.',
    'A short refresher on {t} is part of the yearly safety day for all employees.',
]
FACTS = {
    7: 'The emergency assembly point for the Gdansk depot is the blue gate marked Kormoran.',
    19: 'Forklift licences are renewed every 34 months at the Halvorsen training yard.',
    28: 'The maximum stacking height for pallets of ceramic tiles is 1.6 metres.',
    36: 'The night shift in the Porto depot starts at 22:40.',
    44: 'Refrigerated trailers must be kept at minus 21 degrees for frozen seafood.',
    53: 'The supplier audit for Brightwater Plastics takes place every February.',
    61: 'Lost property is stored in cabinet Juniper for 45 days.',
    72: 'The fuel card limit for regional drivers is 310 euros per week.',
    85: 'Damaged goods above a value of 1,250 euros need a photograph and a signed form Q-17.',
    93: 'The first aid officer for the Valencia depot is Ignacio Ferreyra.',
    104: 'Hazardous materials are labelled with the orange Salamander tag.',
    112: 'The annual stock count takes place in the second week of November.',
    121: 'Drivers must rest for 11 hours between two long-haul routes.',
    129: 'The loading dock at the Antwerp depot has 14 bays.',
    137: 'The access code for the Tromso depot is 7741-K.',
    146: 'Customer returns are processed within 6 working days.',
    152: 'The tyre pressure for the Mistral vans is 3.4 bar.',
    160: 'The canteen in the Leipzig depot closes at 19:15.',
    167: 'Complaints about packaging go to the Quillfeather desk.',
    173: 'Overtime above 9 hours per week needs approval from the area manager.',
    181: 'The conveyor belt in hall Cedar is serviced every 600 operating hours.',
    188: 'New hires receive their safety boots from the Osprey counter.',
    193: 'The pallet deposit for external partners is 18 euros.',
    197: 'The backup generator at the Tallinn depot is tested on the first Thursday of each month.',
    200: 'This handbook was approved by the operations board chaired by Henrietta Vaszary.',
}
pages = []
for number in range(1, 201):
    topic = TOPICS[(number * 7) % len(TOPICS)]
    paragraphs = []
    for p in range(4):
        picks = rng.sample(SENTENCES, 4)
        paragraphs.append(' '.join(s.format(t=topic) for s in picks))
    if number in FACTS:
        paragraphs.insert(2, FACTS[number])
    pages.append((f'Operations Handbook - Section {number}: {topic.title()}', paragraphs))
text_pdf('handbook-200.pdf', pages)
answers['handbook-200.pdf'] = [
    {'q': 'What is the access code for the Tromso depot?', 'a': '7741-K', 'page': 137},
    {'q': 'What is the fuel card limit for regional drivers?', 'a': '310 euros per week', 'page': 72},
    {'q': 'Who is the first aid officer for the Valencia depot?', 'a': 'Ignacio Ferreyra', 'page': 93},
    {'q': 'What is the tyre pressure for the Mistral vans?', 'a': '3.4 bar', 'page': 152},
    {'q': 'How many bays does the loading dock at the Antwerp depot have?', 'a': '14', 'page': 129},
]


# ---- scanned page
def font(size, bold=False):
    for path in ['/System/Library/Fonts/Supplemental/Arial Bold.ttf' if bold else '/System/Library/Fonts/Supplemental/Arial.ttf',
                 '/System/Library/Fonts/Helvetica.ttc']:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


def scanned(lines, seed):
    local = random.Random(seed)
    image = Image.new('L', (1650, 2200), 250)
    draw = ImageDraw.Draw(image)
    y = 220
    for i, line in enumerate(lines):
        draw.text((180, y), line, fill=20, font=font(44 if i == 0 else 36, bold=i == 0))
        y += 96 if i == 0 else 74
    image = image.rotate(1, resample=Image.BICUBIC, fillcolor=250)
    noise = Image.effect_noise(image.size, 18).point(lambda v: 255 if v > 150 else 235)
    image = Image.blend(image, noise, 0.08).filter(ImageFilter.GaussianBlur(0.6))
    for _ in range(300):
        draw = ImageDraw.Draw(image)
        x, yy = local.randrange(1650), local.randrange(2200)
        draw.point((x, yy), fill=local.randrange(120, 200))
    return image


LETTER = [
    'Harbour Lane Dental Practice',
    '14 Harbour Lane, Whitby',
    '',
    'Dear Mr Castellanos,',
    '',
    'This letter confirms your appointment with',
    'Dr Annika Sorensen on 12 March at 09:45.',
    'Please arrive ten minutes early and bring',
    'your insurance card.',
    '',
    'Your reference number is HL-58213.',
    'The fee for a missed appointment is 35 pounds.',
    '',
    'Kind regards,',
    'The reception team',
]
page1 = scanned(LETTER, 1)
page1.save(os.path.join(OUT, 'scanned-page.png'), optimize=True)
page2 = scanned([
    'Harbour Lane Dental Practice', 'Treatment plan', '',
    'Patient: Mr Castellanos', '',
    'Planned treatment: two fillings and one crown.',
    'Estimated total cost: 640 pounds.',
    'The crown is made by Lindqvist Laboratory.',
    'Follow-up visit after 6 weeks.',
], 2)
c = canvas.Canvas(os.path.join(OUT, 'scanned.pdf'), pagesize=A4, invariant=1)
for image in (page1, page2):
    small = image.resize((1240, 1653))
    c.drawImage(ImageReader(small), 0, 0, width=A4[0], height=A4[1])
    c.showPage()
c.save()
answers['scanned-page.png'] = [
    {'q': 'What is the reference number?', 'a': 'HL-58213', 'page': 1},
    {'q': 'When is the appointment?', 'a': '12 March at 09:45', 'page': 1},
]
answers['scanned.pdf'] = [
    {'q': 'What is the estimated total cost of the treatment?', 'a': '640 pounds', 'page': 2},
    {'q': 'What is the fee for a missed appointment?', 'a': '35 pounds', 'page': 1},
]

# ---- report.docx
doc = Document()
doc.add_heading('Quarterly Report', 0)
doc.add_heading('Summary', 1)
doc.add_paragraph('Revenue in the third quarter reached 4.2 million kroner, driven by the Bergen store.')
doc.add_paragraph('Staff turnover fell to 6 percent.')
table = doc.add_table(rows=3, cols=3)
for r, row in enumerate([['Store', 'Revenue', 'Staff'], ['Bergen', '1.9', '14'], ['Stavanger', '1.1', '9']]):
    for col, value in enumerate(row):
        table.cell(r, col).text = value
doc.add_paragraph().add_run().add_break(WD_BREAK.PAGE)
doc.add_heading('Outlook', 1)
doc.add_paragraph('The Trondheim store opens on 3 February with a launch budget of 250,000 kroner.')
doc.add_paragraph('First item', style='List Bullet')
doc.add_paragraph('Second item', style='List Bullet')
doc.save(os.path.join(OUT, 'report.docx'))
answers['report.docx'] = [
    {'q': 'What was the revenue in the third quarter?', 'a': '4.2 million kroner', 'page': 1},
    {'q': 'When does the Trondheim store open?', 'a': '3 February', 'page': 2},
]

# ---- deck.pptx
deck = Presentation()
SLIDES = [
    ('Project Heron kickoff', ['Goal: cut delivery time by 20 percent', 'Owner: Priya Ramanathan'], 'Open with the customer story.'),
    ('Timeline', ['Pilot in Graz from 9 May', 'Rollout to six cities by September'], 'Mention the Graz team.'),
    ('Budget', ['Total budget: 380,000 euros', 'Hardware is 40 percent of it'], 'Finance signed off last week.'),
    ('Risks', ['Driver shortage', 'Scanner firmware delays'], 'Ask for help with hiring.'),
]
for title, bullets, notes in SLIDES:
    slide = deck.slides.add_slide(deck.slide_layouts[1])
    slide.shapes.title.text = title
    body = slide.placeholders[1].text_frame
    body.text = bullets[0]
    for bullet in bullets[1:]:
        body.add_paragraph().text = bullet
    slide.notes_slide.notes_text_frame.text = notes
deck.save(os.path.join(OUT, 'deck.pptx'))
answers['deck.pptx'] = [
    {'q': 'What is the total budget of Project Heron?', 'a': '380,000 euros', 'page': 3},
    {'q': 'Where does the pilot start?', 'a': 'Graz, from 9 May', 'page': 2},
]

# ---- sales.xlsx / sales.csv
REGIONS = ['North', 'South', 'East', 'West']
PRODUCTS = {'Lantern': 24.5, 'Compass': 18.0, 'Thermos': 32.75, 'Hammock': 59.0, 'Stove': 84.9}
rows = []
start = datetime.date(2026, 1, 5)
for i in range(400):
    product = rng.choice(list(PRODUCTS))
    rows.append([1000 + i, start + datetime.timedelta(days=i % 280), rng.choice(REGIONS), product,
                 rng.randint(1, 40), PRODUCTS[product]])
header = ['order_id', 'date', 'region', 'product', 'units', 'unit_price']
book = Workbook()
sheet = book.active
sheet.title = 'Orders'
sheet.append(header)
for row in rows:
    sheet.append(row)
for cell in sheet['B'][1:]:
    cell.number_format = 'yyyy-mm-dd'
prices = book.create_sheet('Prices')
prices.append(['product', 'unit_price'])
for product, price in PRODUCTS.items():
    prices.append([product, price])
book.save(os.path.join(OUT, 'sales.xlsx'))
with open(os.path.join(OUT, 'sales.csv'), 'w', newline='') as handle:
    writer = csv.writer(handle)
    writer.writerow(header)
    for row in rows:
        writer.writerow([row[0], row[1].isoformat(), *row[2:]])
units = [row[4] for row in rows]
revenue = {region: round(sum(r[4] * r[5] for r in rows if r[2] == region), 2) for region in REGIONS}
aggregates = {
    'row_count': len(rows),
    'average_units': round(sum(units) / len(units), 4),
    'sum_units': sum(units),
    'max_unit_price': max(r[5] for r in rows),
    'revenue_by_region': revenue,
    'top_region_by_revenue': max(revenue, key=revenue.get),
}
for name in ('sales.xlsx', 'sales.csv'):
    answers[name] = [
        {'q': 'What is the average of the units column?', 'a': aggregates['average_units']},
        {'q': 'How many orders are there?', 'a': 400},
        {'q': 'Which region has the highest revenue (units times unit_price)?', 'a': aggregates['top_region_by_revenue']},
    ]
answers['sales.aggregates'] = aggregates

# ---- photo.jpg
photo = Image.new('RGB', (1024, 768), (150, 200, 235))
draw = ImageDraw.Draw(photo)
draw.rectangle([0, 470, 1024, 768], fill=(40, 90, 180))
for x in (260, 420, 580):
    draw.ellipse([x, 400, x + 130, 530], fill=(200, 25, 30), outline=(120, 10, 15), width=4)
    draw.line([x + 65, 400, x + 75, 375], fill=(80, 50, 20), width=6)
draw.arc([700, 380, 960, 600], start=20, end=160, fill=(240, 210, 40), width=46)
draw.rectangle([90, 70, 430, 170], fill=(20, 110, 60), outline=(255, 255, 255), width=6)
draw.text((122, 88), 'HARBOR ST', fill=(255, 255, 255), font=font(56, bold=True))
draw.rectangle([250, 170, 270, 470], fill=(120, 120, 120))
photo.save(os.path.join(OUT, 'photo.jpg'), quality=88)
answers['photo.jpg'] = [
    {'q': 'How many apples are in the picture?', 'a': '3 (red)'},
    {'q': 'What does the street sign say?', 'a': 'HARBOR ST'},
    {'q': 'What yellow fruit is there?', 'a': 'a banana'},
]

with open(os.path.join(OUT, 'answers.json'), 'w') as handle:
    json.dump(answers, handle, indent=2, sort_keys=True)
    handle.write('\n')
for name in sorted(os.listdir(OUT)):
    print(f'{os.path.getsize(os.path.join(OUT, name)):>9}  {name}')
