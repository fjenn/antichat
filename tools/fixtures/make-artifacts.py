#!/usr/bin/env python3
"""M6.T13 fixtures (AT-016, AT-277): artifact sources, their ScriptedEngine replies and the 8 file formats.

  tools/.venv/bin/python3 -I tools/fixtures/make-artifacts.py fixtures

Writes (deterministic; invented text, CC0):
  docs/artifacts/{long-code-40l.md, long-code-41l.md, long-code-60l.md, page.html, broken.html, drawing.svg, flow.mmd,
                  chart.vl.json, counter.jsx, net-probe.html, SOURCES.md}
  scripts/artifacts-<name>.jsonl   one reply per fixture (the source in its fence; long-code-*.md are whole replies),
  scripts/artifacts-fix.jsonl      the corrected broken.html (panel.fix → v2),
  scripts/artifacts-edit.jsonl     long-code-60l with only lines 10–12 changed (Edit selection → v2),
  docs/formats-8/{report.pdf, report.docx, budget.xlsx, deck.pptx, notes.csv, photo.png, photo.jpg, memo.m4a, SOURCES.md}
    (PDF/Office/CSV copied from docs/pdf + docs/office, PNG re-encoded from photos-cc0/001.jpg with Pillow, M4A = a 2 s
    440 Hz tone encoded with macOS `afconvert -f m4af -d aac`).
"""
from __future__ import annotations

import json
import math
import shutil
import struct
import subprocess
import sys
import tempfile
import wave
from pathlib import Path


def python_block(n: int, tweak: bool = False) -> str:
    lines = ["def checklist_total(items):", '    """Sum the estimated hours of a launch checklist."""', "    total = 0"]
    i = 0
    while len(lines) < n - 1:
        i += 1
        lines.append(f"    total += items.get('step_{i:02d}', 0)  # step {i}")
    lines.append("    return total")
    if tweak:  # lines 10–12 (1-based) only
        for k in (9, 10, 11):
            lines[k] = lines[k].replace("items.get(", "items.get_hours(")
    return "\n".join(lines)


def reply_with_block(lang: str, body: str, intro: str) -> str:
    return f"{intro}\n\n```{lang}\n{body}\n```\n"


PAGE = """<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Launch checklist</title>
<style>
  body { font: 15px -apple-system, system-ui, sans-serif; margin: 24px; }
  li.done { text-decoration: line-through; color: #595959; }
</style>
</head>
<body>
<h1>Launch checklist</h1>
<ul id="list">
  <li class="done">Write the release notes</li>
  <li>Record the demo video</li>
  <li>Tell the beta testers</li>
</ul>
<p id="count"></p>
<script>
  const open = document.querySelectorAll('#list li:not(.done)').length;
  document.getElementById('count').textContent = open + ' steps left';
</script>
</body>
</html>"""

BROKEN = PAGE.replace("<title>Launch checklist</title>", "<title>Broken widget</title>").replace(
    "document.getElementById('count').textContent = open + ' steps left';",
    "document.getElementById('count').textContent = formatSteps(open);")
FIXED = BROKEN.replace(
    "  const open = document",
    "  function formatSteps(n) { return n + ' steps left'; }\n  const open = document")

SVG = """<svg xmlns="http://www.w3.org/2000/svg" width="320" height="200" viewBox="0 0 320 200">
  <title>Sunrise</title>
  <rect width="320" height="200" fill="#bfe3ff"/>
  <circle cx="160" cy="150" r="56" fill="#ffb347"/>
  <rect y="150" width="320" height="50" fill="#3c8d5a"/>
  <path d="M40 60 q20 -20 40 0 q20 -20 40 0" fill="none" stroke="#ffffff" stroke-width="4"/>
</svg>"""

MERMAID = """flowchart TD
    A[Draft] --> B{Review}
    B -->|approved| C[Publish]
    B -->|changes| A
    C --> D[Announce]"""

CHART = {
    "$schema": "https://vega.github.io/schema/vega-lite/v6.json",
    "title": "Quarterly revenue",
    "data": {"values": [{"quarter": "Q1", "revenue": 120}, {"quarter": "Q2", "revenue": 150},
                        {"quarter": "Q3", "revenue": 135}, {"quarter": "Q4", "revenue": 180}]},
    "mark": "bar",
    "encoding": {"x": {"field": "quarter", "type": "ordinal"}, "y": {"field": "revenue", "type": "quantitative"}},
}

COUNTER = """import React, { useState } from 'react';

export default function Counter() {
  const [count, setCount] = useState(0);
  return (
    <div style={{ fontFamily: 'system-ui', padding: 16 }}>
      <p id="value">Count: {count}</p>
      <button id="inc" onClick={() => setCount(count + 1)}>Add one</button>
    </div>
  );
}"""

NET_PROBE = """<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Net probe</title>
<link rel="stylesheet" href="https://antichat-probe.invalid/style.css">
<script src="https://antichat-probe.invalid/script.js"></script>
</head>
<body>
<h1>Network probe</h1>
<img src="https://antichat-probe.invalid/pixel.png" alt="">
<iframe src="https://antichat-probe.invalid/frame.html"></iframe>
<script>
  const results = {};
  const done = () => { document.title = 'probe:' + JSON.stringify(results); };
  fetch('https://antichat-probe.invalid/fetch.json').then(() => { results.fetch = 'loaded'; done(); })
    .catch(() => { results.fetch = 'blocked'; done(); });
  const img = new Image();
  img.onload = () => { results.image = 'loaded'; done(); };
  img.onerror = () => { results.image = 'blocked'; done(); };
  img.src = 'https://antichat-probe.invalid/js-pixel.png';
  try {
    const ws = new WebSocket('wss://antichat-probe.invalid/socket');
    ws.onopen = () => { results.websocket = 'open'; done(); };
    ws.onerror = () => { results.websocket = 'blocked'; done(); };
  } catch (e) { results.websocket = 'blocked'; done(); }
  setTimeout(() => { location.href = 'https://antichat-probe.invalid/redirect.html'; }, 50);
</script>
</body>
</html>"""


def script(reply: str, title: str) -> str:
    out = [f"# M6.T13 AT-016: {title} (make-artifacts.py)", json.dumps({"t": "title", "v": title, "delayMs": 200})]
    # Deltas of ≤ 80 chars, line-aligned where possible (the renderer sees a streaming fence, then the closed one).
    chunk = ""
    for line in reply.splitlines(keepends=True):
        if len(chunk) + len(line) > 80 and chunk:
            out.append(json.dumps({"t": "textDelta", "v": chunk, "delayMs": 5}))
            chunk = ""
        chunk += line
    if chunk:
        out.append(json.dumps({"t": "textDelta", "v": chunk, "delayMs": 5}))
    return "\n".join(out) + "\n"


def tone_m4a(dest: Path) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "tone.wav"
        with wave.open(str(wav), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(22050)
            frames = b"".join(struct.pack("<h", int(8000 * math.sin(2 * math.pi * 440 * i / 22050))) for i in range(44100))
            w.writeframes(frames)
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "64000", str(wav), str(dest)], check=True)


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "fixtures")
    art = root / "docs/artifacts"
    art.mkdir(parents=True, exist_ok=True)
    scripts = root / "scripts"
    files = {
        "long-code-40l.md": reply_with_block("python", python_block(40), "Here is the helper (40 lines):"),
        "long-code-41l.md": reply_with_block("python", python_block(41), "Here is the helper (41 lines):"),
        "long-code-60l.md": reply_with_block("python", python_block(60), "Here is the helper (60 lines):"),
        "page.html": PAGE, "broken.html": BROKEN, "drawing.svg": SVG, "flow.mmd": MERMAID,
        "chart.vl.json": json.dumps(CHART, indent=2), "counter.jsx": COUNTER, "net-probe.html": NET_PROBE,
    }
    fences = {"page.html": "html", "broken.html": "html", "drawing.svg": "svg", "flow.mmd": "mermaid",
              "chart.vl.json": "vega-lite", "counter.jsx": "jsx", "net-probe.html": "html"}
    for name, text in files.items():
        (art / name).write_text(text + ("" if text.endswith("\n") else "\n"))
        reply = text if name.endswith(".md") else reply_with_block(fences[name], text, f"Here is {name}:")
        stem = name.split(".")[0]
        (scripts / f"artifacts-{stem}.jsonl").write_text(script(reply, f"Artifact {name}"))
    (scripts / "artifacts-fix.jsonl").write_text(
        script(reply_with_block("html", FIXED, "Fixed: `formatSteps` was not defined."), "Fix broken.html"))
    (scripts / "artifacts-edit.jsonl").write_text(
        script(reply_with_block("python", python_block(60, tweak=True), "Updated only that part:"), "Edit long-code-60l"))
    (art / "SOURCES.md").write_text("""# docs/artifacts — sources

M6.T13 AT-016 (R-016): one artifact source per preview kind and the 40/41-line promotion threshold. Made by
`tools/fixtures/make-artifacts.py` (deterministic, invented text). The ScriptedEngine replies are
`scripts/artifacts-<name>.jsonl` (+ `artifacts-fix.jsonl`: the corrected `broken.html`; `artifacts-edit.jsonl`:
`long-code-60l.md` with only lines 10–12 changed).

| File | What | Licence |
|---|---|---|
| `long-code-40l.md`, `long-code-41l.md`, `long-code-60l.md` | whole replies with a 40 / 41 / 60-line `python` block (40 stays inline) | CC0 |
| `page.html`, `broken.html` | a small page; the same page calling an undefined function (`previewError` → `panel.fix`) | CC0 |
| `drawing.svg`, `flow.mmd`, `chart.vl.json` | SVG drawing, Mermaid flowchart, Vega-Lite bar chart (inline values) | CC0 |
| `counter.jsx` | React counter (default export; `#inc` increments `#value`) | CC0 |
| `net-probe.html` | fetch / img / WebSocket / iframe / stylesheet / script / redirect to `antichat-probe.invalid` (tests rewrite the host to a local counting listener) | CC0 |
""")
    f8 = root / "docs/formats-8"
    f8.mkdir(parents=True, exist_ok=True)
    for src, dst in [("docs/pdf/text-10p.pdf", "report.pdf"), ("docs/office/report.docx", "report.docx"),
                     ("docs/office/budget.xlsx", "budget.xlsx"), ("docs/office/deck.pptx", "deck.pptx"),
                     ("docs/office/notes.csv", "notes.csv"), ("images/photos-cc0/001.jpg", "photo.jpg")]:
        shutil.copyfile(root / src, f8 / dst)
    from PIL import Image  # tools/.venv (pillow pinned in tools/pyproject.toml)
    with Image.open(root / "images/photos-cc0/001.jpg") as im:
        im.convert("RGB").save(f8 / "photo.png", format="PNG", optimize=False)
    tone_m4a(f8 / "memo.m4a")
    (f8 / "SOURCES.md").write_text("""# docs/formats-8 — sources

M6.T13 AT-277 (R-277, A-M6-05): one file per supported preview format, used both as an attachment and as a generated
card. Made by `tools/fixtures/make-artifacts.py`.

| File | Origin | Licence |
|---|---|---|
| `report.pdf` | copy of `docs/pdf/text-10p.pdf` | CC0 |
| `report.docx`, `budget.xlsx`, `deck.pptx`, `notes.csv` | copies of `docs/office/*` (make-office.py) | CC0 |
| `photo.jpg` | copy of `images/photos-cc0/001.jpg` | CC0 (see images/photos-cc0/SOURCES.md) |
| `photo.png` | `photo.jpg` re-encoded as PNG with Pillow | CC0 (as its source) |
| `memo.m4a` | a 2 s 440 Hz sine tone, encoded with macOS `afconvert -f m4af -d aac -b 64000` | CC0 |
""")
    print(f"make-artifacts: {len(files)} artifact sources, {len(files) + 2} scripts, 8 formats → {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
