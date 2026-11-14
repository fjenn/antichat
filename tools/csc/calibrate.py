#!/usr/bin/env python3
"""ChildSafetyCheck calibration (M4.T02 step 5; R-285 AC7; Packages/ChildSafetyCheck/METHOD.md). Stdlib only, `python3 -I`.

  calibrate.py run  [--private DIR] [--out DIR] [--ep coreml|cpu] [--legs nudity,overblock,age] [--bench-args '…']
        runs `csc-bench` on the lawful proxy sets (GPU wrapper: $CSC_GPU_RUN, default
        /Users/armando/AntiChat-tools/gpu-run.sh shared --); the bench writes AGGREGATES ONLY.
  calibrate.py eval --at F1|F2|F6 [--in DIR]
        judges one AT from those aggregates, prints the table, writes build/at/AT-NFR-<F>/<date>.json; exit 0 pass,
        1 fail, 2 pending (data absent).
  calibrate.py tables [--in DIR]   prints the T_n sweep (SFW flag rate) and the m_face / m_body margin tables.

Data rule (binding, D-006, D-017, D-019): nudity runs only on SFW rows (no adult-image dataset is used, D-019, which
answers Q-012); age runs only on non-sexual, age-labelled faces; they are never combined. NFR-F1 is judged from the
detector vendor's published accuracy plus the measured SFW false-positive rate; the adult leg of NFR-F6 cannot be
measured locally and is recorded as such. No image, file name or per-image value is read or written by this script.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PKG = os.path.join(ROOT, "Packages/ChildSafetyCheck")
DEFAULT_IN = os.path.join(ROOT, "build/csc")
THRESHOLDS = os.path.join(PKG, "Sources/ChildSafetyCheck/Resources/thresholds.json")
PRIVATE = os.path.expanduser(os.environ.get("CSC_PRIVATE", "~/AntiChatPrivateFixtures/csc"))
GPU_RUN = os.environ.get("CSC_GPU_RUN", "/Users/armando/AntiChat-tools/gpu-run.sh shared --")

# NFR targets (docs/research/02-target/nfr.md, by ID; same numbers as the S-8 report question).
F1 = {"recall": 0.97, "precision": 0.90}
F2 = {"recall_le15": 0.99, "recall_16_17": 0.95, "false_flag_ge30": 0.05}
F6 = {"sfw": 0.01, "nsfw_adult": 0.03}
# D-019: the vendor's own published evaluation of csc-nudity (Freepik/nsfw_image_detector model card, cited in
# model-matrix §10.1): binary correct rate per level 97.0–99.9%. Recorded as the F1 recall source, not re-measured.
VENDOR_F1 = {"source": "Freepik/nsfw_image_detector model card (model-matrix §10.1)", "binary_accuracy_min": 0.970,
             "binary_accuracy_max": 0.999}


def load(d: str, name: str):
    p = os.path.join(d, name)
    return json.load(open(p)) if os.path.exists(p) else None


def bench() -> str:
    subprocess.run(["swift", "build", "-c", "release", "--package-path", PKG, "--disable-keychain", "--product", "csc-bench"],
                   check=True, stdout=subprocess.DEVNULL)
    out = subprocess.run(["swift", "build", "-c", "release", "--package-path", PKG, "--disable-keychain", "--show-bin-path"],
                         check=True, capture_output=True, text=True).stdout.strip()
    return os.path.join(out, "csc-bench")


def cmd_run(a) -> int:
    os.makedirs(a.out, exist_ok=True)
    if not os.path.isdir(a.private):
        print(f"calibrate: private sets absent ({a.private}); F1/F2/F6 stay pending")
        return 2
    b, legs = bench(), a.legs.split(",")
    gpu = GPU_RUN.split()
    def run(*args):
        subprocess.run(gpu + [b, *args, "--ep", a.ep, *a.bench_args.split()], check=True, stdout=subprocess.DEVNULL)
    nud = os.path.join(a.private, "nudity")
    if "nudity" in legs and os.path.exists(os.path.join(nud, "labels.csv")):
        run("nudity", "--set", nud, "--labels", "labels.csv", "--out", os.path.join(a.out, "nudity.json"))
    if "overblock" in legs and os.path.exists(os.path.join(nud, "labels.csv")):
        run("overblock", "--set", nud, "--labels", "labels.csv", "--out", os.path.join(a.out, "overblock.json"))
    if "age" in legs:
        base = os.path.join(a.private, "age")
        for name in sorted(os.listdir(base)) if os.path.isdir(base) else []:
            d = os.path.join(base, name)
            if os.path.exists(os.path.join(d, "ages.csv")):
                run("age", "--set", d, "--labels", "ages.csv", "--out", os.path.join(a.out, f"age-{name}.json"))
    print(f"calibrate: aggregates in {a.out}")
    return 0


def write_at(at: str, record: dict) -> None:
    d = os.path.join(ROOT, "build/at", f"AT-NFR-{at}")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, f"{dt.date.today().isoformat()}.json")
    json.dump(record, open(p, "w"), indent=2, sort_keys=True)
    print(f"→ {os.path.relpath(p, ROOT)}")


def eval_f1(d: str) -> tuple[str, dict]:
    n = load(d, "nudity.json")
    if n is None:
        return "pending", {"reason": "no nudity.json (run `calibrate.py run`)"}
    tn = (load(d, "overblock.json") or {}).get("thresholds", {}).get("T_n")
    row = min((r for r in n["sweep"] if not r["with_marqo"]), key=lambda r: abs(r["T_n"] - (tn or 0.35)))
    rec = {"T_n": row["T_n"], "n_sfw": n["n_sfw"], "sfw_flag_rate": row["sfw_flag_rate"], "n_nsfw_adult": n["n_nsfw_adult"],
           "recall_source": VENDOR_F1, "method": "D-019: SFW false-positive set + vendor benchmark + mocked-score unit tests"}
    if n["n_nsfw_adult"]:
        rec.update(recall=row["recall"], precision=row["precision"])
        ok = row["recall"] >= F1["recall"] and row["precision"] >= F1["precision"]
    else:
        # Precision side measured as the SFW flag rate; recall from the vendor (≥ 97.0% binary accuracy per level).
        ok = VENDOR_F1["binary_accuracy_min"] >= F1["recall"] and row["sfw_flag_rate"] <= 1 - F1["precision"]
    return ("pass" if ok else "fail"), rec


def eval_f2(d: str) -> tuple[str, dict]:
    sets = {}
    for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if f.startswith("age-") and f.endswith(".json"):
            sets[f[4:-5]] = load(d, f)
    if not sets:
        return "pending", {"reason": "no age-*.json"}
    rec, ok = {"sets": {}}, True
    for name, s in sets.items():
        m = s["at_m_face"]
        good = m["recall_le15"] >= F2["recall_le15"] and m["recall_16_17"] >= F2["recall_16_17"] and \
            m["false_flag_ge30"] <= F2["false_flag_ge30"]
        ok &= good
        body = s.get("at_m_body")
        # Body-only, judged at the SHIPPED thresholds (thresholds.json): MiVOLO < 18 + m_body OR age bins ≥ T_age_bins
        # (A-M4-T02b), read from the bench's joint grid so a threshold change needs no re-run.
        shipped = json.load(open(THRESHOLDS))
        grid = (s.get("body_only_fused") or {}).get("grid") or []
        fused = next((c for c in grid if c["m_body"] == shipped["m_body"] and c["T_age_bins"] == shipped.get("T_age_bins")),
                     None)
        entry = {"style": "photo", "n": s["n_rows"], "m_face": m["m"], "face": m, "face_pass": good,
                 "mae": s["face"]["mae"], "body_only": body}
        if fused:
            entry["body_only_fused"] = fused
            entry["body_only_fused_recall_pass"] = fused["recall_le15"] >= F2["recall_le15"] and \
                fused["recall_16_17"] >= F2["recall_16_17"]
            entry["body_only_fused_pass"] = entry["body_only_fused_recall_pass"] and \
                fused["false_flag_ge30"] <= F2["false_flag_ge30"]
            entry["body_only_feasible_cells"] = len((s.get("body_only_fused") or {}).get("feasible") or [])
        rec["sets"][name] = entry
    rec["illustrated"] = "pending: no lawful illustrated set with ground-truth ages (S-8, carried)"
    return ("pass" if ok else "fail"), rec


def eval_f6(d: str) -> tuple[str, dict]:
    o = load(d, "overblock.json")
    if o is None:
        return "pending", {"reason": "no overblock.json"}
    sfw = o["sfw"]
    rec = {"thresholds": o["thresholds"], "sfw": sfw,
           "nsfw_adult": "not measurable locally: no adult-image dataset (D-019); adult content is never blocked by "
                         "the rule (DecisionRuleTests, mocked scores)"}
    ok = sfw["n"] > 0 and sfw["withheld_rate"] is not None and sfw["withheld_rate"] <= F6["sfw"]
    return ("pass" if ok else "fail"), rec


def cmd_eval(a) -> int:
    status, rec = {"F1": eval_f1, "F2": eval_f2, "F6": eval_f6}[a.at](a.inp)
    rec.update(at=f"AT-NFR-{a.at}", status=status, pass_=status == "pass",
               commit=subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip())
    rec["pass"] = rec.pop("pass_")
    print(json.dumps(rec, indent=2, sort_keys=True))
    write_at(a.at, rec)
    return {"pass": 0, "fail": 1}.get(status, 2)


def cmd_tables(a) -> int:
    n = load(a.inp, "nudity.json")
    if n:
        print("T_n   SFW flag rate (Freepik only)")
        for r in n["sweep"]:
            if not r["with_marqo"] and 0.20 <= r["T_n"] <= 0.60:
                print(f"{r['T_n']:.2f}  {r['sfw_flag_rate']:.4f}")
    for f in sorted(os.listdir(a.inp)) if os.path.isdir(a.inp) else []:
        if f.startswith("age-"):
            s = load(a.inp, f)
            for kind in ("face", "body_only"):
                sw = s.get(kind, {}).get("sweep") or []
                if sw:
                    print(f"\n{f[4:-5]} {kind}: m  recall≤15  recall16-17  flag18-29  false≥30")
                    for r in sw:
                        print(f"  {r['m']:>2}  {r['recall_le15']:.4f}  {r['recall_16_17']:.4f}  {r['flag_rate_18_29']:.4f}  {r['false_flag_ge30']:.4f}")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--private", default=PRIVATE)
    r.add_argument("--out", default=DEFAULT_IN)
    r.add_argument("--ep", default="coreml")
    r.add_argument("--legs", default="nudity,overblock,age")
    r.add_argument("--bench-args", default="", help="threshold overrides for a trial, e.g. '--mface 8 --tn2 off'")
    e = sub.add_parser("eval")
    e.add_argument("--at", required=True, choices=["F1", "F2", "F6"])
    e.add_argument("--in", dest="inp", default=DEFAULT_IN)
    t = sub.add_parser("tables")
    t.add_argument("--in", dest="inp", default=DEFAULT_IN)
    a = p.parse_args()
    return {"run": cmd_run, "eval": cmd_eval, "tables": cmd_tables}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
