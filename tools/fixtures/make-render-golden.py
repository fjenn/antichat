#!/usr/bin/env python3
"""Renderer golden fixtures (M1.T09; AT-008 leg 2/4): 100 Markdown samples for RendererGoldenTests.

  python3 -I tools/fixtures/make-render-golden.py --out tools/fixtures/render/golden-100          # write NNN.md
  python3 -I tools/fixtures/make-render-golden.py --out tools/fixtures/render/golden-100 --check  # verify

001–040 LaTeX (inline `$…$` / `\\(…\\)`, block `$$…$$` / `\\[…\\]`), 041–070 tables, 071–090 Mermaid, 091–100 mixed.
The reference images NNN.png are recorded by the renderer itself (`RECORD_GOLDEN=1 make test-unit
FILTER=RendererGoldenTests`) and then guard against regressions (per-pixel ΔE ≤ 2). All text is authored here (CC0).
Deterministic, stdlib only.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

INLINE = [
    r"x^2 + y^2 = z^2", r"e^{i\pi} + 1 = 0", r"\frac{a}{b} + \frac{c}{d}", r"\sqrt{2} \approx 1.414",
    r"\alpha + \beta = \gamma", r"\sum_{k=1}^{n} k = \frac{n(n+1)}{2}", r"\lim_{x \to 0} \frac{\sin x}{x} = 1",
    r"\int_0^1 x\,dx = \tfrac{1}{2}", r"f'(x) = 2x", r"\binom{n}{k}", r"a \le b < c", r"\pi r^2",
    r"\mathbb{R}^n", r"\vec{v} \cdot \vec{w}", r"\log_2 8 = 3", r"\Delta t", r"E = mc^2", r"\theta \in [0, 2\pi)",
    r"n! = n \cdot (n-1)!", r"\overline{z} = a - bi",
]
BLOCK = [
    r"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}",
    r"\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}",
    r"\sum_{n=0}^{\infty} \frac{x^n}{n!} = e^x",
    r"\begin{pmatrix} a & b \\ c & d \end{pmatrix} \begin{pmatrix} x \\ y \end{pmatrix} = \begin{pmatrix} ax + by \\ cx + dy \end{pmatrix}",
    r"\nabla \cdot \mathbf{E} = \frac{\rho}{\varepsilon_0}",
    r"f(x) = \begin{cases} x^2 & x \ge 0 \\ -x & x < 0 \end{cases}",
    r"\prod_{i=1}^{n} (1 + x_i) \ge 1 + \sum_{i=1}^{n} x_i",
    r"\frac{d}{dx}\left( \frac{1}{x} \right) = -\frac{1}{x^2}",
    r"P(A \mid B) = \frac{P(B \mid A)\,P(A)}{P(B)}",
    r"\lim_{n \to \infty} \left(1 + \frac{1}{n}\right)^n = e",
    r"a^2 - b^2 = (a - b)(a + b)",
    r"\det \begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix} = -2",
    r"\oint_C \mathbf{F} \cdot d\mathbf{r} = 0",
    r"\sigma = \sqrt{\frac{1}{N} \sum_{i=1}^{N} (x_i - \mu)^2}",
    r"\cos^2 \theta + \sin^2 \theta = 1",
    r"\zeta(s) = \sum_{n=1}^{\infty} \frac{1}{n^s}",
    r"\mathbf{A}\mathbf{x} = \lambda \mathbf{x}",
    r"\int_a^b f'(x)\,dx = f(b) - f(a)",
    r"\binom{n}{k} = \frac{n!}{k!\,(n-k)!}",
    r"e^{i\theta} = \cos\theta + i \sin\theta",
]
PROSE = [
    "Here is the idea in one line:", "A short derivation follows.", "This is the standard result.",
    "Keep this identity in mind:", "The formula below does the work.",
]

FRUIT = ["Apples", "Pears", "Plums", "Cherries", "Figs", "Grapes", "Lemons", "Limes", "Mangoes", "Oranges"]
CITIES = ["Lisbon", "Porto", "Madrid", "Seville", "Lyon", "Turin", "Ghent", "Bergen", "Krakow", "Tallinn"]
LANGS = ["Swift", "Python", "Rust", "Go", "Kotlin", "TypeScript", "C", "Ruby"]

MERMAID = [
    "flowchart TD\n    A[Start] --> B{Is it working?}\n    B -->|Yes| C[Ship it]\n    B -->|No| D[Debug]\n    D --> B",
    "flowchart LR\n    Draft --> Review --> Merge --> Release",
    "sequenceDiagram\n    participant U as User\n    participant A as App\n    U->>A: Send message\n    A-->>U: Stream reply",
    "classDiagram\n    class Chat {\n      +String title\n      +send()\n    }\n    class Message\n    Chat \"1\" --> \"*\" Message",
    "stateDiagram-v2\n    [*] --> Idle\n    Idle --> Streaming: send\n    Streaming --> Idle: done\n    Streaming --> Interrupted: stop",
    "erDiagram\n    CHAT ||--o{ MESSAGE : contains\n    MESSAGE ||--o{ PART : has",
    "pie title Fruit basket\n    \"Apples\" : 40\n    \"Pears\" : 25\n    \"Plums\" : 35",
    "gantt\n    title Plan\n    dateFormat YYYY-MM-DD\n    section Build\n    Renderer :a1, 2026-11-01, 4d\n    Palette :after a1, 3d",
    "flowchart TB\n    subgraph Mac\n      App --> Helper\n    end\n    Helper --> Model[(Weights)]",
    "sequenceDiagram\n    Alice->>Bob: Hello Bob\n    Bob-->>Alice: Hi Alice\n    Alice->>Bob: How are you?\n    Bob-->>Alice: Great!",
    "flowchart LR\n    A((Circle)) --> B([Stadium]) --> C[[Subroutine]] --> D[/Parallelogram/]",
    "stateDiagram-v2\n    [*] --> Queued\n    Queued --> Loading\n    Loading --> Ready\n    Ready --> [*]",
    "classDiagram\n    Animal <|-- Duck\n    Animal <|-- Fish\n    Animal : +int age\n    Duck : +swim()",
    "flowchart TD\n    Q[Question] --> S[Search]\n    Q --> T[Think]\n    S --> A[Answer]\n    T --> A",
    "pie title Languages\n    \"Swift\" : 55\n    \"Python\" : 30\n    \"Other\" : 15",
    "erDiagram\n    USER ||--o{ PROJECT : owns\n    PROJECT ||--|{ FILE : includes",
    "sequenceDiagram\n    participant C as Composer\n    participant T as TurnController\n    participant E as Engine\n    C->>T: send\n    T->>E: generate\n    E-->>T: tokens\n    T-->>C: done",
    "flowchart LR\n    Low -->|+1| Medium -->|+1| High",
    "gantt\n    title Week\n    dateFormat YYYY-MM-DD\n    section Days\n    Monday :2026-11-02, 1d\n    Tuesday :2026-11-03, 1d",
    "flowchart TD\n    A --> B\n    A --> C\n    B --> D\n    C --> D",
]


def latex(i: int) -> str:
    prose = PROSE[i % len(PROSE)]
    if i < 20:  # inline
        f = INLINE[i]
        if i % 2 == 0:
            return f"{prose} the value ${f}$ appears inline, and the sentence continues after it.\n"
        return f"{prose} written with parentheses, \\({f}\\), it reads the same.\n"
    f = BLOCK[i - 20]
    if i % 2 == 0:
        return f"{prose}\n\n$$\n{f}\n$$\n\nThat completes the step.\n"
    return f"{prose}\n\n\\[\n{f}\n\\]\n\nThat completes the step.\n"


def table(i: int) -> str:
    cols = 2 + i % 5  # 2…6 columns
    rows = 2 + (i * 3) % 6  # 2…7 rows
    head = ["Item"] + [f"Q{c}" for c in range(1, cols)]
    align = ["---"] + [(":---:" if (i + c) % 3 == 0 else "---:" if (i + c) % 3 == 1 else "---") for c in range(1, cols)]
    out = [f"Table {i + 1}: quarterly figures.", "", "| " + " | ".join(head) + " |", "| " + " | ".join(align) + " |"]
    names = FRUIT if i % 2 == 0 else CITIES
    for r in range(rows):
        cells = [names[(i + r) % len(names)]]
        for c in range(1, cols):
            v = (i * 37 + r * 11 + c * 7) % 1000
            cell = f"{v}"
            if (r + c) % 4 == 0:
                cell = f"**{v}**"
            elif (r + c) % 5 == 0:
                cell = f"`{v}`"
            cells.append(cell)
        out.append("| " + " | ".join(cells) + " |")
    if i % 10 == 9:  # a wide table: horizontal scroll
        out[2] = out[2][:-2] + " | " + " | ".join(f"Extra column {k}" for k in range(1, 7)) + " |"
        out[3] = out[3][:-2] + " | " + " | ".join("---" for _ in range(6)) + " |"
        for r in range(4, len(out)):
            out[r] = out[r][:-2] + " | " + " | ".join(f"value {k}" for k in range(1, 7)) + " |"
    return "\n".join(out) + "\n"


def mermaid(i: int) -> str:
    return f"A diagram:\n\n```mermaid\n{MERMAID[i]}\n```\n"


def mixed(i: int) -> str:
    lang = LANGS[i % len(LANGS)]
    return (
        f"## Notes on {lang}\n\n"
        f"Here is a **short** summary with *emphasis*, `inline code` and a [link](https://example.com/{i}).\n\n"
        f"1. First point about {lang}\n2. Second point, with $a_{i} + b_{i}$ inline\n   - a nested bullet\n"
        f"3. Third point\n\n"
        f"> A quoted remark about sample {i + 1}.\n\n"
        f"```{lang.lower()}\n// sample {i + 1}\nlet total = {i} + {i + 1}\n```\n\n"
        f"| Key | Value |\n|---|---:|\n| sample | {i + 1} |\n| square | {(i + 1) ** 2} |\n\n"
        f"$$\n\\sum_{{k=1}}^{{{i + 2}}} k = {sum(range(1, i + 3))}\n$$\n"
    )


def samples() -> dict[str, str]:
    s: dict[str, str] = {}
    n = 1
    for i in range(40):
        s[f"{n:03d}"] = latex(i); n += 1
    for i in range(30):
        s[f"{n:03d}"] = table(i); n += 1
    for i in range(20):
        s[f"{n:03d}"] = mermaid(i); n += 1
    for i in range(10):
        s[f"{n:03d}"] = mixed(i); n += 1
    return s


SOURCES = """# Renderer golden fixtures (golden-100)

Generated by `tools/fixtures/make-render-golden.py` (M1.T09, AT-008). All Markdown text is authored in that script
and dedicated to the public domain (CC0 1.0). The reference images `NNN.png` are renders of `NNN.md` by AntiChat's
own renderer (MarkdownView 3.0.0, SwiftMath, Highlightr, mermaid 12.2.0) recorded with
`RECORD_GOLDEN=1 make test-unit FILTER=RendererGoldenTests`; they carry no third-party content.

| Range | Kind |
|---|---|
| 001–040 | LaTeX: 001–020 inline (`$…$`, `\\(…\\)`), 021–040 block (`$$…$$`, `\\[…\\]`) |
| 041–070 | Tables (2–6 columns, alignment, inline bold/code, every tenth one wide) |
| 071–090 | Mermaid (flowchart, sequence, class, state, ER, pie, gantt) |
| 091–100 | Mixed (headings, lists, quote, link, code, table, block math) |
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="fixtures/render/golden-100")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    out = Path(a.out)
    files = {f"{k}.md": v for k, v in samples().items()} | {"SOURCES.md": SOURCES}
    bad = 0
    for name, text in files.items():
        p = out / name
        if a.check:
            if not p.exists() or p.read_text(encoding="utf-8") != text:
                print(f"stale: {p}")
                bad += 1
        else:
            out.mkdir(parents=True, exist_ok=True)
            p.write_text(text, encoding="utf-8")
    print(f"make-render-golden: {'FAIL ' + str(bad) if bad else 'ok'} ({len(files) - 1} samples, {out})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
