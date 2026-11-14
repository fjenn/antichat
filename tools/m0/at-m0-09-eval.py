#!/usr/bin/env python3
"""Evaluate AT-M0-09 from the artefacts tools/m0/at-m0-09.sh produced; write result.json and judges.md.
Exit 0 only if every check passes (M0.md C4)."""
from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--fixtures", required=True)
    ap.add_argument("--raw", required=True)
    ap.add_argument("--commit", required=True)
    o = ap.parse_args()
    checks = []

    swap = json.load(open(os.path.join(o.out, "swap-stats.json")))
    # M0.md AT-M0-09: NFR-C7 measured in both directions; an empty/one-sided raw file must not pass vacuously.
    dirs = sorted(swap)
    checks.append({"name": "NFR-C7 both swap directions measured", "value": dirs, "bar": "normal->evil and evil->normal",
                   "pass": {"normal->evil", "evil->normal"} <= set(dirs)})
    for d, v in sorted(swap.items()):
        checks.append({"name": f"NFR-C7 {d} measured (n=20, p50/p95 vs target)", "value": {"p50": v["p50"], "p95": v["p95"], "n": v["n"],
                       "errors": v["errors"], "meets_target": v["pass"], "peak_footprint_gb": v["peak_footprint_gb_max"]},
                       "bar": f"n >= 20, 0 errors; target <= {v['target_s']} s recorded", "pass": v["n"] >= 20 and v["errors"] == 0})

    ag = json.load(open(os.path.join(o.out, "agentic.json")))
    off = ag.get("evil-9b|thinking=off", {})
    checks.append({"name": "Evil tool-call validity, agentic-30, thinking off", "value": off.get("valid_rate"), "bar": ">= 0.90",
                   "pass": off.get("n") == 30 and off.get("valid_rate", 0) >= 0.90})
    checks.append({"name": "tool-call validity (information)", "value": ag, "bar": "reported", "pass": True})

    answers = {json.loads(l)["file"]: json.loads(l) for l in open(os.path.join(o.fixtures, "images/ocr/answers.jsonl")) if l.strip()}
    vis = {}
    for f in ("doc-00", "receipt-00", "chart-00"):
        p = os.path.join(o.raw, f"family-evil-9b-vision-{f}.jsonl")
        if not os.path.exists(p):
            continue
        r = json.loads(open(p).read().splitlines()[0])
        want = answers[f + ".png"]["answer"]
        vis[f] = {"expected": want, "text": r.get("text", "")[:120], "correct": want.lower() in r.get("text", "").lower()}
    checks.append({"name": "vision with mmproj: doc-00 answered correctly", "value": vis, "bar": "doc-00 contains the expected string",
                   "pass": vis.get("doc-00", {}).get("correct", False)})

    jp = os.path.join(o.out, "judges.json")
    if os.path.exists(jp):
        j = json.load(open(jp))
        c = j["combined"].get("consumer-60", {})
        s = j["combined"].get("evil-quality-smoke-40", {})
        delta = c.get("delta_pct_mean")
        checks.append({"name": "consumer-60 quality delta recorded (Evil vs Normal, 2 blind judges)", "value": c,
                       "bar": "recorded; < -10 % triggers the model-matrix §9.5 fallback", "pass": delta is not None,
                       "fallback_triggered": delta is not None and delta < -10})
        checks.append({"name": "evil-quality-smoke-40 delta (information)", "value": s, "bar": "reported", "pass": True})
        with open(os.path.join(o.out, "judges.md"), "w") as f:
            f.write("# AT-M0-09 blind pairwise judges\n\nProtocol: `tools/eval/judge-pairwise.md`. Pairs: `pairs.jsonl` (blind), key: `pairs-key.json`.\n"
                    "Raw verdicts: `judge-1.jsonl`, `judge-2.jsonl`. Delta = (mean Evil − mean Normal) / mean Normal.\n\n"
                    "| Set | Judge | n | mean Evil | mean Normal | delta % | Evil wins | Normal wins | ties |\n|---|---|---|---|---|---|---|---|---|\n")
            for pj in j["per_judge"]:
                for name, v in sorted(pj["sets"].items()):
                    f.write(f"| {name} | {pj['judge']} | {v['n']} | {v['mean_evil']} | {v['mean_normal']} | {v['delta_pct']} | "
                            f"{v['evil_wins']} | {v['normal_wins']} | {v['ties']} |\n")
            for name, v in sorted(j["combined"].items()):
                f.write(f"| {name} | **both** | {v['n']} | {v['mean_evil']} | {v['mean_normal']} | **{v['delta_pct_mean']}** | | | |\n")
    else:
        checks.append({"name": "consumer-60 quality delta recorded", "value": None, "bar": "judges.json present", "pass": False})

    hw = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string", "hw.memsize"], capture_output=True, text=True).stdout.split("\n")
    res = {"at": "AT-M0-09", "pass": all(c["pass"] for c in checks), "checks": checks, "commit": o.commit,
           "host": {"chip": hw[0], "mem_bytes": int(hw[1] or 0), "macos": platform.mac_ver()[0], "tier_cap": "T1 (B = 9.5 GB)"}}
    with open(os.path.join(o.out, "result.json"), "w") as f:
        json.dump(res, f, indent=2)
        f.write("\n")
    for c in checks:
        print(("[pass] " if c["pass"] else "[FAIL] ") + c["name"])
    print("AT-M0-09", "PASS" if res["pass"] else "FAIL")
    return 0 if res["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
