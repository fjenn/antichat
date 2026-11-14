#!/usr/bin/env python3
"""Merge the M1.T13 conformance outputs into build/at/AT-229/conformance.json (one row per engine x family).

Inputs: build/at/AT-229/rows/<row>-{tools,thinking,cancel}.json (ConformanceSuite) and build/at/AT-229/recovery.json
(ToolCallRecoveryConformanceTests: the 10 parser-level tool rows per dialect). A row's tool score is its 40 model
cases + the 10 recovery rows of its dialect (qwen35 for Qwen rows, gemma4 for Gemma, json for the tiny fixture; the
llama-server row's parser is llama.cpp's own, so its recovery rows are reported `n/a` and its tool score is x/40).
Pass per row: tools all pass, thinking 20/20, cancel 10/10 (each <= 300 ms, nothing after done).
D-023: the starter (chat-0.8b) is chat-only (the harness offers it no tools), so its tool score is reported but not
gated; chat-35b-q4 and chat-g26 keep the 50/50 bar but a miss is `pending` until the re-measure after M1.T16.
Usage: python3 -I tools/at/conformance-report.py [--root build/at/AT-229] ; exit 1 if a present row fails
(pending rows make the AT `pending`, exit 0).
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def load(p: Path):
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else None


def dialect(row: dict) -> str | None:
    if row.get("engine") == "llama":
        return None
    fam = (row.get("family") or "").lower()
    if "gemma" in fam:
        return "gemma4"
    if "tiny" in fam:
        return "json"
    return "qwen3_5"


# D-023 (a): chat-only models, tool cases informational only.
CHAT_ONLY = {"chat-0.8b"}
# D-023 (b): rows whose tool bar is re-measured after M1.T16 (a miss before then is pending, not final).
# M1.T16 landed (ToolSelection in front of every case, build/at/AT-229/tuning/): the re-measure is done, so these
# rows carry the plain 50/50 bar again; a miss is a fail (and a model-change decision for that tier, D-023 b).
REMEASURE_AFTER_T16: set[str] = set()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="build/at/AT-229", type=Path)
    a = ap.parse_args()
    rec = load(a.root / "recovery.json") or {"families": []}
    rec_by = {f["format"]: f for f in rec.get("families", [])}
    rows: dict[str, dict] = {}
    for f in sorted((a.root / "rows").glob("*.json")):
        d = load(f)
        rid, kind = d["row"], f.stem[len(d["row"]) + 1:]
        r = rows.setdefault(rid, {"row": rid, "engine": d["engine"], "family": d["family"], "model": d["model"], "cap": d["cap"],
                                  "plumbing": bool(d.get("plumbing")) or rid == "mlx-tiny"})
        r[kind] = {"passed": d["passed"], "total": d["total"], "date": d["date"], "runtime_s": round(d.get("runtime_s", 0), 1),
                   "failing": [{"id": c["id"], "why": c.get("why")} for c in d["cases"] if not c.get("pass")]}
        if kind == "tools":
            r[kind]["calls"] = d.get("calls")
            r[kind]["constrained_calls"] = d.get("constrained_calls")
        if kind == "cancel":
            r[kind]["max_cancel_ms"] = d.get("max_cancel_ms")
            r[kind]["phase_hits"] = sum(1 for c in d["cases"] if c.get("phase_hit"))
    ok_all = True
    for r in rows.values():
        dl = dialect(r)
        fam = rec_by.get(dl) if dl else None
        t = r.get("tools", {"passed": 0, "total": 0})
        r["recovery"] = ({"dialect": dl, "passed": fam["passed"], "total": fam["total"]} if fam else
                         {"dialect": "llama.cpp native parser", "status": "n/a (parser-level rows target mlx-swift-lm's parser)"})
        rp, rt = (fam["passed"], fam["total"]) if fam else (0, 0)
        r["tool_score"] = f"{t['passed'] + rp}/{t['total'] + rt}"
        parts = [r.get(k) for k in ("tools", "thinking", "cancel")]
        r["complete"] = all(p is not None for p in parts)
        tools_ok = t["passed"] == t["total"] and rp == rt
        rest_ok = all(p is not None and p["passed"] == p["total"] for p in parts[1:])
        r["pass"] = r["complete"] and tools_ok and rest_ok
        r["status"] = "pass" if r["pass"] else "fail"
        if r["model"] in CHAT_ONLY:
            r["tool_bar"] = "n/a: chat-only, no tools exposed (D-023 a)"
            r["pass"] = r["complete"] and rest_ok
            r["status"] = "pass" if r["pass"] else "fail"
        elif r["model"] in REMEASURE_AFTER_T16 and r["complete"] and rest_ok and not tools_ok:
            r["tool_bar"] = "50/50, re-measure after M1.T16 (D-023 b); still missing then -> model-change decision"
            r["pass"] = False
            r["status"] = "pending"
        if r["plumbing"]:  # random-weight fixture: contract plumbing only, not a shipped engine x family row
            r["pass"] = None
            r["status"] = "plumbing"
            continue
        ok_all &= r["pass"] or r["status"] == "pending"
    shipped = [r for r in rows.values() if not r["plumbing"]]
    pending = [r["row"] for r in shipped if r["status"] == "pending"]
    status = "fail" if not (ok_all and shipped) else "pending" if pending else "pass"
    out = {"id": "AT-229", "rows": list(rows.values()), "recovery_source": rec.get("parser"),
           "pass": status == "pass", "status": status, "pending_rows": pending, "decision": "D-023"}
    (a.root / "conformance.json").write_text(json.dumps(out, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    for r in rows.values():
        print(f"{r['row']:<18} tools {r['tool_score']:<6} thinking {r.get('thinking', {}).get('passed', '-')}/"
              f"{r.get('thinking', {}).get('total', '-')} cancel {r.get('cancel', {}).get('passed', '-')}/"
              f"{r.get('cancel', {}).get('total', '-')} {r['status'].upper()}"
              f"{'  (' + r['tool_bar'] + ')' if r.get('tool_bar') else ''}")
    print(f"AT-229: {status.upper()}" + (f" (pending: {', '.join(pending)})" if pending else ""))
    raise SystemExit(0 if status != "fail" else 1)


if __name__ == "__main__":
    main()
