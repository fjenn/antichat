#!/usr/bin/env python3
"""Synthetic intake fixtures for M6.T01 (AT-020: TypeSnifferTests, AdapterFixtureTests, IntakeTests):
  fixtures/docs/pdf/corrupt.pdf              "%PDF-1.7" header, then garbage (extraction must fail -> error tile)
  fixtures/docs/pdf/encrypted.pdf            2 pages, RC4-128 user password "antichat" (pypdf) -> encrypted tile
  fixtures/docs/office/legacy.doc            an OLE compound-file header without a Workbook stream -> unsupported
  fixtures/docs/text/{sample.txt, sample.md, sample.rtf, sample.html, sample.json, sample.swift, sample.tsv}
  fixtures/docs/epub/sample.epub             EPUB 3: container.xml -> OPF (manifest + spine) -> 3 XHTML chapters
  fixtures/images/upload-errors/{sample.png, sample.gif, sample.webp}  from photos-cc0/001.jpg (Pillow)
  fixtures/images/upload-errors/heic-named.jpg  photos-cc0/002.jpg as HEIC (`sips`), named .jpg -> isLying
All text is invented from a fixed word list (seed 20261105) and released CC0; images derive from the CC0 photos.
Zip member times are fixed so reruns are byte-identical (the HEIC comes from `sips`, stable for a given macOS).

Usage: tools/.venv/bin/python3 -I tools/fixtures/make-intake.py --out fixtures
"""
from __future__ import annotations

import argparse
import io
import json
import os
import random
import subprocess
import tempfile
import zipfile

SEED = 20261105
WORDS = ("harbour lantern meadow quarry orchard ledger compass furnace cobble thistle beacon granary vessel canal "
         "ferry timber archive pigment loom kiln weir trellis bellows almanac pewter saddle mortar willow").split()
ZIP_TIME = (2026, 11, 5, 0, 0, 0)


def sentence(rng: random.Random) -> str:
    return " ".join(rng.choice(WORDS) for _ in range(rng.randint(8, 14))).capitalize() + "."


def paragraph(rng: random.Random) -> str:
    return " ".join(sentence(rng) for _ in range(rng.randint(3, 5)))


def write(path: str, data: bytes | str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data.encode("utf-8") if isinstance(data, str) else data)


def pdfs(out: str, rng: random.Random) -> None:
    write(f"{out}/docs/pdf/corrupt.pdf", b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n" + bytes(rng.randrange(256) for _ in range(4096)))
    from pypdf import PdfWriter
    from reportlab.pdfgen import canvas
    buf = io.BytesIO()
    c = canvas.Canvas(buf, invariant=1)
    for n in (1, 2):
        c.drawString(72, 720, f"Encrypted fixture page {n}. {sentence(rng)}")
        c.showPage()
    c.save()
    w = PdfWriter(clone_from=io.BytesIO(buf.getvalue()))
    w.encrypt(user_password="antichat", owner_password="antichat-owner", algorithm="RC4-128")
    dst = io.BytesIO()
    w.write(dst)
    write(f"{out}/docs/pdf/encrypted.pdf", dst.getvalue())


def legacy_doc(out: str) -> None:
    # OLE2 compound file signature + a minimal header (sector size 512); the directory names "WordDocument".
    header = bytearray(512)
    header[0:8] = bytes.fromhex("D0CF11E0A1B11AE1")
    header[24:26] = (0x3E).to_bytes(2, "little")
    header[26:28] = (3).to_bytes(2, "little")
    header[28:30] = (0xFFFE).to_bytes(2, "little")
    header[30:32] = (9).to_bytes(2, "little")
    body = bytearray(512)
    name = "WordDocument".encode("utf-16-le")
    body[0:len(name)] = name
    write(f"{out}/docs/office/legacy.doc", bytes(header) + bytes(body))


def texts(out: str, rng: random.Random) -> None:
    d = f"{out}/docs/text"
    paras = [paragraph(rng) for _ in range(4)]
    write(f"{d}/sample.txt", "\n\n".join(paras) + "\n")
    write(f"{d}/sample.md", "# Harbour notes\n\n" + paras[0] + "\n\n## Ledger\n\n- " + sentence(rng) + "\n- "
          + sentence(rng) + "\n\n" + paras[1] + "\n")
    rtf_body = "\\par ".join(p.replace("\\", "") for p in paras[:2])
    write(f"{d}/sample.rtf", "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs24 {\\b Harbour report}\\par "
          + rtf_body + "\\par }\n")
    write(f"{d}/sample.html", "<!doctype html><html><head><meta charset=\"utf-8\"><title>Harbour</title></head><body>"
          f"<h1>Harbour report</h1><p>{paras[0]}</p><h2>Ledger</h2><ul><li>{sentence(rng)}</li><li>{sentence(rng)}"
          f"</li></ul><p>{paras[1]}</p></body></html>\n")
    write(f"{d}/sample.json", json.dumps({"title": "Harbour", "items": [{"id": i, "note": sentence(rng)}
                                                                         for i in range(5)]}, indent=2) + "\n")
    write(f"{d}/sample.swift", "// Harbour fixture (CC0)\nstruct Ledger {\n    var entries: [String] = []\n"
          "    mutating func add(_ s: String) { entries.append(s) }\n}\n")
    rows = ["region\tquarter\tamount"] + [f"{rng.choice(WORDS)}\tQ{rng.randint(1, 4)}\t{rng.randint(100, 9999)}"
                                          for _ in range(12)]
    write(f"{d}/sample.tsv", "\n".join(rows) + "\n")


def epub(out: str, rng: random.Random) -> None:
    chapters = [(f"Chapter {i}: {rng.choice(WORDS).capitalize()}", [paragraph(rng) for _ in range(3)]) for i in (1, 2, 3)]
    files: list[tuple[str, str, bool]] = [("mimetype", "application/epub+zip", False)]
    files.append(("META-INF/container.xml", '<?xml version="1.0"?>\n<container version="1.0" '
                  'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile '
                  'full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>\n',
                  True))
    manifest = "".join(f'<item id="c{i}" href="text/ch{i}.xhtml" media-type="application/xhtml+xml"/>'
                       for i in (1, 2, 3))
    spine = "".join(f'<itemref idref="c{i}"/>' for i in (1, 2, 3))
    files.append(("OEBPS/content.opf", '<?xml version="1.0" encoding="utf-8"?>\n<package xmlns="http://www.idpf.org/2007/opf" '
                  'version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
                  '<dc:identifier id="id">antichat-fixture-epub</dc:identifier><dc:title>Harbour Almanac</dc:title>'
                  f'<dc:language>en</dc:language></metadata><manifest>{manifest}</manifest><spine>{spine}</spine>'
                  '</package>\n', True))
    for i, (title, ps) in enumerate(chapters, 1):
        body = "".join(f"<p>{p}</p>" for p in ps)
        files.append((f"OEBPS/text/ch{i}.xhtml", '<?xml version="1.0" encoding="utf-8"?>\n<html '
                      'xmlns="http://www.w3.org/1999/xhtml"><head><title>' + title + '</title></head><body><h1>'
                      + title + '</h1>' + body + '</body></html>\n', True))
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for name, data, compress in files:
            info = zipfile.ZipInfo(name, date_time=ZIP_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED if compress else zipfile.ZIP_STORED
            z.writestr(info, data)
    write(f"{out}/docs/epub/sample.epub", buf.getvalue())


def images(out: str) -> None:
    from PIL import Image
    src = f"{out}/images/photos-cc0/001.jpg"
    d = f"{out}/images/upload-errors"
    im = Image.open(src).convert("RGB")
    im.thumbnail((640, 640))
    im.save(f"{d}/sample.png", optimize=False)
    im.convert("P", palette=Image.Palette.ADAPTIVE).save(f"{d}/sample.gif")
    im.save(f"{d}/sample.webp", quality=80, method=0)
    with tempfile.TemporaryDirectory() as t:
        small = os.path.join(t, "src.jpg")
        Image.open(f"{out}/images/photos-cc0/002.jpg").convert("RGB").resize((512, 384)).save(small, quality=85)
        heic = os.path.join(t, "x.heic")
        subprocess.run(["/usr/bin/sips", "-s", "format", "heic", small, "--out", heic], check=True,
                       stdout=subprocess.DEVNULL)
        with open(heic, "rb") as f:
            write(f"{d}/heic-named.jpg", f.read())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    rng = random.Random(SEED)
    pdfs(a.out, rng)
    legacy_doc(a.out)
    texts(a.out, rng)
    epub(a.out, rng)
    images(a.out)


if __name__ == "__main__":
    main()
