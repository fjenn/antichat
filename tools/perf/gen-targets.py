#!/usr/bin/env python3
"""Generate tools/perf/nfr_targets.json from the NFR tables (M1.T26a; numbers are never hand-typed). Stdlib only.

Sources (the only places numbers live, PRD §4):
  * docs/research/02-target/nfr.md — every NFR row of the M1 set (PRD §4 row M1) plus M1/R1 (M0 smoke rows);
  * docs/research/02-target/hardware-tiers.md §2.3 — chip → speed class (S1…S4), for U1's S1 / S2+ split;
  * docs/prd/M1.md — the two non-NFR perf keys an M1 AT names (`sidebarUpdate` ≤ 100 ms AT-011, `composerDock`
    ≤ 300 ms AT-001) and the AT-NFR-U4 tolerance (± 100 ms).
Each metric below says WHICH cell and WHICH phrase to read (regexes); the values come from the text. If a phrase is
not found (nfr.md was edited), the generator fails instead of guessing, so `--check` in CI catches drift.

  python3 -I tools/perf/gen-targets.py            # write tools/perf/nfr_targets.json
  python3 -I tools/perf/gen-targets.py --check    # exit 1 when the committed file is stale

Target model (consumed by run.py / compare.py):
  metric → {nfr, title, unit, direction (lower|higher|range|equal), star, gate_stat,
            tiers: {<tier key>: [check, …]}, variants: {<name>: {<tier key>: [check, …]}}, text, source}
  check  = {"stat": p50|p95|p99|mean|max|min|rate, "op": "<="|"<"|">="|">"|"=="|"within", "value": x[, "tol": t | "hi": y]}
  tier key: T0…T4 (tier family; T2-24 → T2), S1/S2+ (speed class), or "default".
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
NFR = os.path.join(ROOT, "docs/research/02-target/nfr.md")
TIERS_MD = os.path.join(ROOT, "docs/research/02-target/hardware-tiers.md")
M1_MD = os.path.join(ROOT, "docs/prd/M1.md")
M3_MD = os.path.join(ROOT, "docs/prd/M3.md")
OUT = os.path.join(ROOT, "tools/perf/nfr_targets.json")
NUM = r"(\d+(?:[.,]\d+)?)"
TIER_COLS = ["T0", "T1", "T2", "T3", "T4"]
# ★ metrics (PRD §4: regression > 25% = S1).
STAR = {"U1", "U2", "C1", "C2", "V1", "P1", "M5"}


class Drift(Exception):
    pass


def clean(cell: str) -> str:
    return re.sub(r"\*\*", "", cell).strip()


def f(x: str) -> float:
    return float(x.replace(",", ""))


def find(pattern: str, text: str, what: str) -> re.Match:
    m = re.search(pattern, text)
    if not m:
        raise Drift(f"{what}: pattern {pattern!r} not found in {text[:160]!r}")
    return m


def nfr_rows(md: str) -> dict[str, list[str]]:
    rows = {}
    for line in md.splitlines():
        m = re.match(r"^\|\s*(NFR-[A-Z0-9]+[a-z]?)\s*\|(.*)\|\s*$", line)
        if m:
            rows[m.group(1)] = [clean(c) for c in m.group(2).split("|")]
    return rows


def speed_classes(md: str) -> dict[str, list[str]]:
    """hardware-tiers §2.3 → {"S4": ["M5 Pro", "M5 Max", "M5 Ultra"], …} (chip names expanded)."""
    sec = md[md.index("### 2.3 Speed classes"):]
    sec = sec[: sec.index("\n---")]
    out: dict[str, list[str]] = {}
    for line in sec.splitlines():
        m = re.match(r"^\|\s*\*\*(S\d)[^|]*\|[^|]*\|\s*(.+?)\s*\|\s*$", line)
        if not m:
            continue
        chips: list[str] = []
        for part in re.split(r",| and ", re.sub(r"\([^)]*\)", "", m.group(2))):
            part = part.strip().replace(" base", "")
            if not part:
                continue
            mm = re.match(r"^((?:M\d/)+M\d)\s+(.+)$", part)  # "M2/M3/M4 Pro" → M2 Pro, M3 Pro, M4 Pro
            if mm:
                chips += [f"{c} {mm.group(2)}" for c in mm.group(1).split("/")]
            elif re.match(r"^(M\d/)+M\d$", part):
                chips += part.split("/")
            else:
                chips.append(part)
        out[m.group(1)] = chips
    if set(out) != {"S1", "S2", "S3", "S4"}:
        raise Drift(f"hardware-tiers §2.3: speed classes {sorted(out)}")
    return out


def chk(stat, op, value, **kw):
    d = {"stat": stat, "op": op, "value": value}
    d.update(kw)
    return d


def build(nfr_md: str, tiers_md: str, m1_md: str, m3_md: str | None = None) -> dict:
    rows = nfr_rows(nfr_md)

    def cell(i: str, col: int = 1) -> str:
        if i not in rows:
            raise Drift(f"{i} missing from nfr.md")
        return rows[i][col]

    def tiered(i: str, stat: str, op: str) -> dict:
        cs = rows[i][1:6]
        out = {}
        for t, c in zip(TIER_COLS, cs):
            m = re.search(NUM, c)
            if not m:
                raise Drift(f"{i} {t}: no number in {c!r}")
            out[t] = [chk(stat, op, f(m.group(1)))]
        return out

    T: dict[str, dict] = {}

    def add(mid, nfr, unit, direction, gate_stat, tiers, text, variants=None, source="nfr.md"):
        T[mid] = {"nfr": nfr, "title": rows[nfr][0] if nfr in rows else nfr, "unit": unit, "direction": direction,
                  "star": mid in STAR, "gate_stat": gate_stat, "tiers": tiers, "variants": variants or {},
                  "text": text, "source": source}

    # §1 Felt speed
    c = cell("NFR-U1")
    s2 = find(r"p50 ≤ " + NUM + r" s \(S2\+\)", c, "U1 S2+")
    s1 = find(r"≤ " + NUM + r" s \(S1\)", c, "U1 S1")
    warm = find(r"warm relaunch ≤ " + NUM + r" s", c, "U1 warm")
    add("U1", "NFR-U1", "s", "lower", "p50", {"S2+": [chk("p50", "<=", f(s2[1]))], "S1": [chk("p50", "<=", f(s1[1]))]}, c,
        variants={"warm": {"default": [chk("p50", "<=", f(warm[1]))]}})
    c = cell("NFR-U2")
    p99 = find(r"p99 < " + NUM + r" ms", c, "U2 p99")
    p50 = find(r"p50 ≤ " + NUM + r" ms", c, "U2 p50")
    add("U2", "NFR-U2", "ms", "lower", "p99", {"default": [chk("p99", "<", f(p99[1])), chk("p50", "<=", f(p50[1]))]}, c)
    c = cell("NFR-U4")
    at = find(r"appears after " + NUM + r" s", c, "U4")
    tol = find(r"AT-NFR-U4\*\*.*?" + NUM + r" s ± " + NUM + r" ms", m1_md, "M1.md AT-NFR-U4 tolerance")
    if f(tol[1]) != f(at[1]):
        raise Drift(f"U4: nfr.md {at[1]} s vs M1.md {tol[1]} s")
    add("U4", "NFR-U4", "s", "range", "p50",
        {"default": [chk("min", ">=", round(f(at[1]) - f(tol[2]) / 1000, 3)), chk("max", "<=", round(f(at[1]) + f(tol[2]) / 1000, 3))]},
        c + f" | tolerance ± {tol[2]} ms from M1.md AT-NFR-U4", source="nfr.md + M1.md AT-NFR-U4")
    c = cell("NFR-U5")
    hz = find(NUM + r"–" + NUM + r" Hz", c, "U5 cadence")
    fade = find(NUM + r"–" + NUM + r" ms per-word fade", c, "U5 fade")
    frame = find(r"no frame > " + NUM + r" ms on the main thread", c, "U5 hitch")
    jump = find(r"no layout jump > " + NUM + r" px", c, "U5 jump")
    add("U5", "NFR-U5", "hitches", "equal", "max", {"default": [chk("max", "==", 0, frame_ms=f(frame[1]))]}, c, variants={
        "cadence": {"default": [chk("p50", "within", f(hz[1]), hi=f(hz[2]), unit="Hz")]},
        "fade": {"default": [chk("p50", "within", f(fade[1]), hi=f(fade[2]), unit="ms")]},
        "jump": {"default": [chk("max", "<=", f(jump[1]), unit="px")]},
    })
    c = cell("NFR-U6")
    p50 = find(r"idle ≤ " + NUM + r" ms", c, "U6 p50")
    p95 = find(r"p95 ≤ " + NUM + r" s", c, "U6 p95")
    add("U6", "NFR-U6", "ms", "lower", "p50", {"default": [chk("p50", "<=", f(p50[1])), chk("p95", "<=", f(p95[1]) * 1000)]}, c)
    c = cell("NFR-U7")
    t1 = find(r"≤ " + NUM + r" s after the first reply starts \(T1\+\)", c, "U7 T1+")
    t0 = find(r"≤ " + NUM + r" s \(T0\)", c, "U7 T0")
    add("U7", "NFR-U7", "s", "lower", "p50", {"T0": [chk("p50", "<=", f(t0[1]))], "default": [chk("p50", "<=", f(t1[1]))]}, c)
    c = cell("NFR-U8")
    f60 = find(r"≥ " + NUM + r" fps at 60 Hz", c, "U8 60")
    f120 = find(r"≥ " + NUM + r" fps at 120 Hz", c, "U8 120")
    add("U8", "NFR-U8", "fps", "higher", "p50", {"default": [chk("p50", ">=", f(f60[1]))]}, c,
        variants={"120hz": {"default": [chk("p50", ">=", f(f120[1]))]}})
    c = cell("NFR-U9")
    v = find(r"≤ " + NUM + r" ms p95", c, "U9")
    add("U9", "NFR-U9", "ms", "lower", "p95", {"default": [chk("p95", "<=", f(v[1]))]}, c)
    c = cell("NFR-U10")
    v = find(r"≤ " + NUM + r" ms p95", c, "U10")
    add("U10", "NFR-U10", "ms", "lower", "p95", {"default": [chk("p95", "<=", f(v[1]))]}, c)
    c = cell("NFR-U11")
    v = find(r"rendered ≤ " + NUM + r" ms", c, "U11")
    add("U11", "NFR-U11", "ms", "lower", "p95", {"default": [chk("p95", "<=", f(v[1]))]}, c)

    # §2 Chat
    add("C1", "NFR-C1", "s", "lower", "p50", tiered("NFR-C1", "p50", "<="), " | ".join(rows["NFR-C1"][1:6]))
    add("C1b", "NFR-C1b", "s", "lower", "p95", tiered("NFR-C1b", "p95", "<="), " | ".join(rows["NFR-C1b"][1:6]))
    c2 = tiered("NFR-C2", "p50", ">=")
    add("C2", "NFR-C2", "tok/s", "higher", "p50", c2, " | ".join(rows["NFR-C2"][1:6]))
    c = cell("NFR-C3")
    pct = find(r"≥ " + NUM + r"% of NFR-C2", c, "C3")
    add("C3", "NFR-C3", "tok/s", "higher", "p50",
        {t: [chk("p50", ">=", round(v[0]["value"] * f(pct[1]) / 100, 3), derived=f"{pct[1]}% of NFR-C2 {t}")] for t, v in c2.items()}, c)
    add("C4", "NFR-C4", "tok/s", "higher", "p50", tiered("NFR-C4", "p50", ">="), " | ".join(rows["NFR-C4"][1:6]))
    c = cell("NFR-C5")
    pct = find(NUM + r"% of cases", c, "C5")
    add("C5", "NFR-C5", "%", "higher", "rate", {"default": [chk("rate", ">=", f(pct[1]))]}, c)
    c = cell("NFR-C6")
    find(r"TTFT within NFR-C1", c, "C6")
    add("C6", "NFR-C6", "s", "lower", "p50",
        {t: [dict(v[0], derived=f"NFR-C1 {t}")] for t, v in T["C1"]["tiers"].items()}, c)

    # §3 Voice (M3.T03: dictation; gate p50, the V1 convention — p95 is reported beside it)
    c = cell("NFR-V5")
    v = find(r"≤ " + NUM + r" ms \(all tiers\)", c, "V5")
    add("V5", "NFR-V5", "ms", "lower", "p50", {"default": [chk("p50", "<=", f(v[1]))]}, c)
    c = cell("NFR-V6")
    t0 = find(r"≤ " + NUM + r" s \(T0\)", c, "V6 T0")
    t1 = find(r"≤ " + NUM + r" s \(T1\+\)", c, "V6 T1+")
    add("V6", "NFR-V6", "s", "lower", "p50", {"T0": [chk("p50", "<=", f(t0[1]))], "default": [chk("p50", "<=", f(t1[1]))]}, c)
    # The voice table has four tier columns (T0 · T1 · T2 · T3–T4), then Basis.
    v7 = [f(find(NUM, x, f"V7 col {i}")[1]) for i, x in enumerate(rows["NFR-V7"][1:5])]
    add("V7", "NFR-V7", "s", "lower", "p50", {t: [chk("p50", "<=", v)] for t, v in zip(TIER_COLS, v7 + [v7[3]])},
        " | ".join(rows["NFR-V7"][1:5]))
    v8 = [f(find(NUM, x, f"V8 col {i}")[1]) for i, x in enumerate(rows["NFR-V8"][1:5])]  # M3.T07: T0 · T1 · T2 · T3–T4
    add("V8", "NFR-V8", "s", "lower", "p50", {t: [chk("p50", "<=", v)] for t, v in zip(TIER_COLS, v8 + [v8[3]])},
        " | ".join(rows["NFR-V8"][1:5]))
    c = cell("NFR-V9")
    t1 = find(r"WER ≤ " + NUM + r"% \(T1\+\)", c, "V9 T1+")
    t0 = find(r"≤ " + NUM + r"% \(T0\)", c, "V9 T0")
    add("V9", "NFR-V9", "%", "lower", "max", {"T0": [chk("max", "<=", f(t0[1]))], "default": [chk("max", "<=", f(t1[1]))]},
        c + " | max over languages; CER for ja/zh (A-M3-02)")
    c = cell("NFR-V11")  # M3.T06: n = 3 runs of the 60-min file (A-M3-03); gate p50 of the real-time factor
    t1 = find(r"≥ " + NUM + r"× real time \(T1\+\)", c, "V11 T1+")
    t0 = find(r"≥ " + NUM + r"× \(T0\)", c, "V11 T0")
    add("V11", "NFR-V11", "x", "higher", "p50", {"T0": [chk("p50", ">=", f(t0[1]))], "default": [chk("p50", ">=", f(t1[1]))]}, c)
    c = cell("NFR-V10")
    v = find(r"within " + NUM + r" ms of mic-button hover", c, "V10")
    add("V10", "NFR-V10", "ms", "lower", "p50", {"T0": [], "default": [chk("p50", "<=", f(v[1]))]}, c)
    # M3.T10/T11: the conversation (V1 p50 / V1b p95 per tier, T0 · T1 · T2 · T3–T4; V2 T3 stages; V3 barge-in).
    for mid, stat in (("V1", "p50"), ("V1b", "p95")):
        vals = [f(find(NUM, x, f"{mid} col {i}")[1]) for i, x in enumerate(rows[f"NFR-{mid}"][1:5])]
        add(mid, f"NFR-{mid}", "s", "lower", stat, {t: [chk(stat, "<=", v)] for t, v in zip(TIER_COLS, vals + [vals[3]])},
            " | ".join(rows[f"NFR-{mid}"][1:5]))
    c = rows["NFR-V2"][4]
    stages = {}
    for name, label in (("endpointing", "endpointing"), ("stt_final", "STT final"), ("llm_ttft", "LLM TTFT"),
                        ("first_clause", "first clause decoded"), ("tts_first_chunk", "TTS first chunk"),
                        ("audio_out", "audio out")):
        v = find(label + r" ≤ " + NUM + r" ms", c, f"V2 {name}")
        stages[name] = {"T3": [chk("p50", "<=", f(v[1]))], "T4": [chk("p50", "<=", f(v[1]))]}
    add("V2", "NFR-V2", "ms", "lower", "p50", {}, c, variants=stages)
    c = cell("NFR-V3")
    silent = find(r"≤ " + NUM + r" ms; LLM", c, "V3 silent")
    cancel = find(r"LLM generation cancelled ≤ " + NUM + r" ms", c, "V3 cancel")
    add("V3", "NFR-V3", "ms", "lower", "p50", {"default": [chk("p50", "<=", f(silent[1]))]}, c,
        variants={"cancel": {"default": [chk("p50", "<=", f(cancel[1]))]}})
    v4 = find(r"≤ " + NUM + r"% of a 50-utterance fixture", rows["NFR-V4"][1], "V4")
    v4_checks = [chk("max", "<=", f(v4[1]))]
    add("V4", "NFR-V4", "%", "lower", "max", {"default": v4_checks}, " | ".join(rows["NFR-V4"][:2]),
        variants={bed: {"default": v4_checks} for bed in ("cafe", "fan", "keyboard")})
    if m3_md is not None:
        v283 = find(r"p50 end-of-speech → final transcript ≤ " + NUM + r" ms at T1", m3_md, "V283")
        T["V283_EOS_FINAL"] = {
            "nfr": None, "title": "End-of-turn decision → final transcript (R-283)", "unit": "ms",
            "direction": "lower", "star": False, "gate_stat": "p50",
            "tiers": {"T1": [chk("p50", "<=", f(v283[1]))]}, "variants": {},
            "text": v283[0], "source": "M3.md AT-283 (A-M3-04)",
        }

    # §5/§6/§8/§9
    c = cell("NFR-M1")
    loads = re.findall(r"≤ " + NUM + r" s for ≤ " + NUM + r" GB|≤ " + NUM + r" s ≤ " + NUM + r" GB", c)
    bands = []
    for a, b, x, y in loads:
        bands.append({"max_weights_gb": f(b or y), "value": f(a or x)})
    if len(bands) != 4:
        raise Drift(f"M1 bands: {bands}")
    add("M1", "NFR-M1", "s", "lower", "p50", {"default": [chk("p50", "<=", None, by_weights_gb=bands)]}, c)
    # M2.T15 NFR-C7: cold switch ≤ NFR-M1 band (by the Evil model's weights) + NFR-C1 of the tier; warm (T3+) ≤ X s.
    c = cell("NFR-C7")
    find(r"≤ NFR-M1 load time \+ NFR-C1", c, "C7 cold")
    warm = find(r"≤ " + NUM + r" s when both models fit warm \(T3\+\)", c, "C7 warm")
    c7 = {t: [chk("p50", "<=", None, by_weights_gb=[dict(x, value=round(x["value"] + v[0]["value"], 3)) for x in bands],
                  derived=f"NFR-M1 band + NFR-C1 {t}")] for t, v in T["C1"]["tiers"].items() if t in ("T0", "T1", "T2")}
    for t in ("T3", "T4"):
        c7[t] = [chk("p50", "<=", f(warm[1]), derived="both models fit warm (T3+)")]
    add("C7", "NFR-C7", "s", "lower", "p50", c7, c)
    c = cell("NFR-R1")
    b = find(r"T0 " + NUM + r" · T1 " + NUM + r" · T2 " + NUM + r"/" + NUM + r"/" + NUM + r" · T3 " + NUM + r"/" + NUM + r" · T4 " + NUM + r"/" + NUM + r" GB", c, "R1")
    vals = [f(x) for x in b.groups()]
    r1 = {"T0": vals[0], "T1": vals[1], "T2-24": vals[2], "T2-32": vals[3], "T2-36": vals[4], "T3-48": vals[5], "T3-64": vals[6],
          "T4-96": vals[7], "T4-128": vals[8]}
    add("R1", "NFR-R1", "GB", "lower", "max", {t: [chk("max", "<=", v)] for t, v in r1.items()}, c)
    c = cell("NFR-R3")
    rss = find(r"≤ " + NUM + r" MB RSS", c, "R3 rss")
    cpu = find(r"≤ " + NUM + r"% CPU averaged over " + NUM + r" s", c, "R3 cpu")
    find(r"no GPU work", c, "R3 gpu")
    add("R3", "NFR-R3", "MB", "lower", "max", {"default": [chk("max", "<=", f(rss[1]))]}, c, variants={
        "cpu": {"default": [chk("mean", "<=", f(cpu[1]), unit="%", window_s=f(cpu[2]))]},
        "gpu": {"default": [chk("max", "==", 0, unit="bytes")]},
    })
    c = cell("NFR-B1")
    ei = find(r"≤ " + NUM + r" averaged over " + NUM + r" min", c, "B1")
    hz = find(r"no timers faster than " + NUM + r" Hz", c, "B1 timers")
    add("B1", "NFR-B1", "energy impact", "lower", "mean", {"default": [chk("mean", "<=", f(ei[1]), window_min=f(ei[2]))]}, c,
        variants={"timers": {"default": [chk("max", "<=", f(hz[1]), unit="Hz")]}})
    c = cell("NFR-S2")
    s = find(r"every ≤ " + NUM + r" s or " + NUM + r" tokens", c, "S2")
    add("S2", "NFR-S2", "s", "lower", "max", {"default": [chk("max", "<=", f(s[1]))]}, c,
        variants={"tokens": {"default": [chk("max", "<=", f(s[2]), unit="tokens")]}})
    c = cell("NFR-S4")
    s = find(r"restarts ≤ " + NUM + r" s", c, "S4")
    add("S4", "NFR-S4", "s", "lower", "p95", {"default": [chk("p95", "<=", f(s[1]))]}, c)

    # §F ChildSafetyCheck (M4.T02): per-image check p95 at T1.
    c = cell("NFR-F7")
    v = find(r"per-image check ≤ " + NUM + r" ms p95", c, "F7")
    add("F7", "NFR-F7", "ms", "lower", "p95", {"default": [chk("p95", "<=", f(v[1]))]}, c)

    # Non-NFR perf keys named by M1 ATs (M1.md)
    m = find(r"visible update ≤ " + NUM + r" ms \(signpost `sidebarUpdate`\)", m1_md, "M1.md sidebarUpdate")
    T["sidebarUpdate"] = {"nfr": None, "title": "Sidebar update after a chat mutation (AT-011)", "unit": "ms", "direction": "lower",
                          "star": False, "gate_stat": "p95", "tiers": {"default": [chk("p95", "<=", f(m[1]))]}, "variants": {},
                          "text": m[0], "source": "M1.md M1.T07 step 6"}
    m = find(r"animation duration \(signpost `composerDock`\) ≤ " + NUM + r" ms", m1_md, "M1.md AT-001 composerDock")
    v = m[1]
    T["composerDock"] = {"nfr": None, "title": "Composer docks after the first send (AT-001)", "unit": "ms", "direction": "lower",
                         "star": False, "gate_stat": "max", "tiers": {"default": [chk("max", "<=", f(v))]}, "variants": {},
                         "text": m[0], "source": "M1.md AT-001 / M1.T07"}

    return {
        "generated_by": "tools/perf/gen-targets.py",
        # Paths only: each metric's `text` holds the exact phrase read, so --check goes stale only when a cell the
        # targets come from changes (not on every unrelated M1.md edit).
        "sources": sorted(os.path.relpath(p, ROOT) for p in (NFR, TIERS_MD, M1_MD, M3_MD)),
        "speed_classes": speed_classes(tiers_md),
        "metrics": T,
    }


def render(d: dict) -> str:
    return json.dumps(d, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args()
    try:
        d = build(open(NFR).read(), open(TIERS_MD).read(), open(M1_MD).read(), open(M3_MD).read())
    except Drift as e:
        print(f"[fail] {e}", file=sys.stderr)
        return 2
    text = render(d)
    if a.check:
        cur = open(a.out).read() if os.path.exists(a.out) else ""
        if cur != text:
            print(f"[fail] {os.path.relpath(a.out, ROOT)} is stale: run python3 -I tools/perf/gen-targets.py", file=sys.stderr)
            return 1
        print("[ok] nfr_targets.json up to date")
        return 0
    with open(a.out, "w") as fh:
        fh.write(text)
    print(f"[ok] wrote {os.path.relpath(a.out, ROOT)} ({len(d['metrics'])} metrics)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
