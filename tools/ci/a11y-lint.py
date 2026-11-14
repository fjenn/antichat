#!/usr/bin/env python3
"""Accessibility lint over the SwiftUI sources (M9.T01 definition of done; R-223, NFR-A2/A3). Run with `python3 -I`.

Keeps UI that lands after M9 accessible: every interactive control is found by a small Swift scanner (strings and
comments skipped) together with its argument list, trailing closures and modifier chain, and checked:

  label     (hard)  an icon-only control (its label is an Image and nothing that reads as text) needs
                    `.accessibilityLabel(…)` (or `.accessibilityRepresentation`) in its chain;
  symbol    (hard)  an accessibility label is never a raw SF Symbol name (`Text("square.and.arrow.up")`);
  tap       (hard)  a view made tappable with `.onTapGesture` exposes the action to VoiceOver/keyboard:
                    `.accessibilityAddTraits(.isButton)`, `.accessibilityAction`, or is `.accessibilityHidden(true)`;
  hidden-ctl(hard)  a Button/Toggle is never `.accessibilityHidden(true)` (an unreachable control);
  ident     (ratchet) a Button / Toggle has an `.accessibilityIdentifier(…)` or `.probeID(…)` (the XCUITest anchor, M9.md T01 DoD):
                    per file the count may not grow past tools/a11y/a11y-lint-baseline.json (`--update-baseline`
                    after fixing old ones; growth fails, so every new control carries an identifier).

A deliberate exception is marked on the control's first line: `// a11y-lint: ok <reason>` (e.g. the label sits on
the parent). Files: Packages/UI/Sources, Packages/Design/Sources, App/AntiChat (probes/bench excluded).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_common import ROOT, repo_files  # noqa: E402

BASELINE = "tools/a11y/a11y-lint-baseline.json"
SCOPES = ("Packages/UI/Sources/", "Packages/Design/Sources/", "App/AntiChat/")
SKIP = re.compile(r"(Probe|Bench[A-Za-z+]*|Spike[A-Za-z]*)\.swift$|/Spike/")
CONTROL = re.compile(r"(?<![\w.])(Button|Toggle|Menu)\s*(?=[({])")
SYMBOL_NAME = re.compile(r'^[a-z0-9]+(\.[a-z0-9]+)+$')
OK = "a11y-lint: ok"


def mask(src: str) -> str:
    """Same-length copy with comments and string-literal contents blanked (quotes kept), so brackets inside
    them never count. Handles "…", \"\"\"…\"\"\", #"…"#, interpolation \\( … ) (kept as code)."""
    out = list(src)
    i, n = 0, len(src)
    stack: list[tuple[str, int]] = []  # string contexts: (delimiter, interpolation paren depth)

    def blank(a: int, b: int) -> None:
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        c = src[i]
        if stack and stack[-1][1] < 0:  # inside a string literal body
            delim = stack[-1][0]
            if c == "\\" and i + 1 < n and src[i + 1] == "(":
                stack[-1] = (delim, 0)
                i += 2
                continue
            if c == "\\":
                blank(i, min(i + 2, n)); i += 2; continue
            if src.startswith(delim, i):
                stack.pop(); i += len(delim); continue
            blank(i, i + 1); i += 1; continue
        if src.startswith("//", i):
            j = src.find("\n", i); j = n if j < 0 else j
            blank(i, j); i = j; continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2); j = n if j < 0 else j + 2
            blank(i, j); i = j; continue
        if stack:  # inside interpolation code
            if c == "(":
                stack[-1] = (stack[-1][0], stack[-1][1] + 1)
            elif c == ")":
                if stack[-1][1] == 0:
                    stack[-1] = (stack[-1][0], -1); i += 1; continue
                stack[-1] = (stack[-1][0], stack[-1][1] - 1)
        m = re.match(r'(#*)("""|")', src[i:i + 8])
        if m:
            delim = m.group(2) + m.group(1)
            stack.append((delim, -1))
            i += len(m.group(0))
            continue
        i += 1
    return "".join(out)


def match_close(m: str, i: int) -> int:
    """Index after the bracket that closes m[i] (one of ( { [)."""
    pairs = {"(": ")", "{": "}", "[": "]"}
    depth, j = 0, i
    while j < len(m):
        ch = m[j]
        if ch in pairs:
            depth += 1
        elif ch in ")}]":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return len(m)


def extent(m: str, start: int) -> tuple[int, int]:
    """(end of the call incl. trailing closures, end of its modifier chain) for a call whose name ends at start."""
    j = start
    while j < len(m) and m[j] in " \t":
        j += 1
    if j < len(m) and m[j] == "(":
        j = match_close(m, j)
    k = j
    while k < len(m) and m[k] in " \t":
        k += 1
    if k < len(m) and m[k] == "{":  # first trailing closure: same line
        j = match_close(m, k)
    while True:  # further labelled trailing closures: `label: { … }`, may start on the next line
        k = j
        while k < len(m) and m[k] in " \t\n":
            k += 1
        lab = re.match(r"[A-Za-z_]\w*\s*:\s*\{", m[k:])
        if not lab:
            break
        j = match_close(m, k + lab.end() - 1)
    call_end = j
    while True:  # modifier chain
        k = j
        while k < len(m) and m[k] in " \t\n":
            k += 1
        mod = re.match(r"\.[A-Za-z_]\w*", m[k:])
        if not mod or (k < len(m) - 1 and m[k + 1].isdigit()):
            break
        j = k + mod.end()
        while j < len(m) and m[j] in " \t":
            j += 1
        if j < len(m) and m[j] == "(":
            j = match_close(m, j)
        k2 = j
        while k2 < len(m) and m[k2] in " \t":
            k2 += 1
        if k2 < len(m) and m[k2] == "{":
            j = match_close(m, k2)
    return call_end, j


def strip_calls(s: str, name: str) -> str:
    out, i = [], 0
    while True:
        k = s.find(name + "(", i)
        if k < 0:
            out.append(s[i:]); break
        out.append(s[i:k])
        i = match_close(s, k + len(name))
    return "".join(out)


TEXTISH = re.compile(r'(?<![\w.])(Text|Label|LabeledContent)\s*\(|CopyKey\(|CopyText\(|\btitle\s*:|"[^"\s]')


def icon_only(label: str) -> bool:
    if "Image(" not in label and "Image(systemName" not in label:
        return False
    rest = strip_calls(label, "Image")
    rest = re.sub(r"\baction\s*:", "", rest)
    return TEXTISH.search(rest) is None


def lint_file(rel: str, src: str) -> tuple[list[str], int]:
    """(hard findings, identifier-less Button/Toggle count)."""
    m = mask(src)
    lines = src.splitlines()
    errs: list[str] = []
    no_ident = 0

    def line_of(pos: int) -> int:
        return src.count("\n", 0, pos) + 1

    def ok(ln: int) -> bool:
        return OK in lines[ln - 1] if 0 < ln <= len(lines) else False

    for c in CONTROL.finditer(m):
        kind = c.group(1)
        # Skip type positions (`-> some Button`, `: Button`, `Button<Label>`, ButtonStyle etc.).
        before = m[max(0, c.start() - 12):c.start()]
        if re.search(r"(->|:|some|any)\s*$", before):
            continue
        call_end, chain_end = extent(m, c.end())
        ln = line_of(c.start())
        if ok(ln):
            continue
        label_part = src[c.end():call_end]
        # A trailing `label: { … }` closure is the control's visible label (a Menu's first closure is its content).
        labs = list(re.finditer(r"\blabel\s*:\s*\{", m[c.end():call_end]))
        if labs and match_close(m, c.end() + labs[-1].end() - 1) == call_end:
            label_part = src[c.end() + labs[-1].end():call_end]
        chain = src[call_end:chain_end]
        if kind in ("Button", "Menu") and icon_only(label_part) and not re.search(
                r"\.accessibilityLabel\(|\.accessibilityRepresentation|\.tooltipBubble\(|\.labelStyle\(|\.generatedImageLabel\(", chain):
            errs.append(f"{rel}:{ln}: label: icon-only {kind} without .accessibilityLabel")
        if kind in ("Button", "Toggle") and re.search(r"\.accessibilityHidden\(\s*true\s*\)", chain):
            errs.append(f"{rel}:{ln}: hidden-ctl: {kind} hidden from accessibility (unreachable for VoiceOver)")
        if kind in ("Button", "Toggle") and ".accessibilityIdentifier(" not in chain and ".probeID(" not in chain:
            no_ident += 1

    for t in re.finditer(r"\.onTapGesture\b", m):
        ln = line_of(t.start())
        lo, hi = max(0, ln - 14), min(len(lines), ln + 10)
        window = "\n".join(lines[lo:hi])
        if ok(ln) or re.search(r"accessibilityAddTraits\(\s*\.isButton|\.accessibilityAction|"
                               r"accessibilityHidden\(\s*true|\.accessibilityRespondsToUserInteraction", window):
            continue
        errs.append(f"{rel}:{ln}: tap: .onTapGesture without .accessibilityAddTraits(.isButton) / .accessibilityAction")

    for lab in re.finditer(r'\.accessibilityLabel\(\s*(?:Text\(\s*(?:verbatim:\s*)?)?"([^"]*)"', src):
        if SYMBOL_NAME.match(lab.group(1)):
            errs.append(f"{rel}:{line_of(lab.start())}: symbol: accessibility label is a symbol name '{lab.group(1)}'")
    return errs, no_ident


def scan(root: Path) -> tuple[list[str], dict[str, int]]:
    errs: list[str] = []
    counts: dict[str, int] = {}
    for f in repo_files(root, (".swift",)):
        rel = str(f.relative_to(root))
        if not rel.startswith(SCOPES) or SKIP.search(rel):
            continue
        e, n = lint_file(rel, f.read_text(encoding="utf-8", errors="replace"))
        errs += e
        if n:
            counts[rel] = n
    return errs, counts


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(ROOT))
    ap.add_argument("--update-baseline", action="store_true")
    a = ap.parse_args()
    root = Path(a.root).resolve()
    errs, counts = scan(root)
    bpath = root / BASELINE
    if a.update_baseline:
        bpath.parent.mkdir(parents=True, exist_ok=True)
        bpath.write_text(json.dumps(dict(sorted(counts.items())), indent=1) + "\n", encoding="utf-8")
    base = json.loads(bpath.read_text(encoding="utf-8")) if bpath.exists() else {}
    for rel, n in sorted(counts.items()):
        if n > base.get(rel, 0):
            errs.append(f"{rel}: ident: {n} Button/Toggle without .accessibilityIdentifier (baseline {base.get(rel, 0)}); "
                        f"give the new control an identifier")
    for e in errs:
        print(e)
    total = sum(counts.values())
    print(f"a11y-lint: {'FAIL ' + str(len(errs)) if errs else 'ok'} (identifier-less controls {total}, "
          f"baseline {sum(base.values())})")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
