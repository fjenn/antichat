#!/usr/bin/env python3
"""AT-271 check 3a (M6.T04 step 6): character error rate of the OCR output against ground truth.

CER(page) = Levenshtein(pred, gt) / len(gt), both normalised the same way: Markdown markers dropped (`#`, list
`- `, table pipes and `---` rule rows), every whitespace run → one space, trimmed. Pass: mean CER ≤ 0.03.

  python3 -I tools/at/cer.py --gt fixtures/docs/ocr-30p --pred build/at/AT-271/<date>/ocr --out <json>
Pairs `<gt>/<name>.gt.txt` with `<pred>/<name>.md` (or `.txt`).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys


def normalise(s: str) -> str:
    out = []
    for line in s.splitlines():
        t = line.strip()
        if re.fullmatch(r"\|?(\s*-{3,}\s*\|)+\s*-*", t):
            continue
        t = re.sub(r"^#+\s*", "", t)
        t = re.sub(r"^[-*]\s+", "", t)
        t = t.replace("|", " ")
        out.append(t)
    return re.sub(r"\s+", " ", " ".join(out)).strip()


def levenshtein(a: str, b: str) -> int:
    if len(a) < len(b):
        a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gt", required=True)
    ap.add_argument("--pred", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--max", type=float, default=0.03)
    a = ap.parse_args()
    rows = []
    for fn in sorted(os.listdir(a.gt)):
        if not fn.endswith(".gt.txt"):
            continue
        name = fn[: -len(".gt.txt")]
        pred_path = next((os.path.join(a.pred, name + e) for e in (".md", ".txt")
                          if os.path.exists(os.path.join(a.pred, name + e))), None)
        gt = normalise(open(os.path.join(a.gt, fn), encoding="utf-8").read())
        pred = normalise(open(pred_path, encoding="utf-8").read()) if pred_path else ""
        d = levenshtein(pred, gt)
        rows.append({"page": name, "cer": d / max(1, len(gt)), "edits": d, "gt_chars": len(gt), "missing": pred_path is None})
    mean = sum(r["cer"] for r in rows) / max(1, len(rows))
    out = {"check": "AT-271 3a", "pages": len(rows), "mean_cer": mean, "max_allowed": a.max,
           "pass": bool(rows) and mean <= a.max, "rows": rows}
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w") as fh:
        json.dump(out, fh, indent=1)
    print(f"mean CER {mean:.4f} over {len(rows)} pages ({'pass' if out['pass'] else 'FAIL'}) -> {a.out}")
    return 0 if out["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
