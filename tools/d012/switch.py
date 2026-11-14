#!/usr/bin/env python3
"""D-012 switch rule re-run (docs/prd/M0.md M0.T13; selection.md §11; DECISIONS D-012).

Recomputes residual gap work (P0, P0+P1), one-time, yearly and 3-year totals for A, F1, F1-R and F2
from tools/d012/baseline.json (the §11 per-gap table) and the M0 measurements in inputs.json, then
applies the rule: switch to F1 if A's 3-year total exceeds F1-R's by more than 20%.

  python3 -I tools/d012/switch.py --baseline tools/d012/baseline.json --self-test
  python3 -I tools/d012/switch.py --baseline B --inputs I --out R [--self-test]
"""
import argparse, json, sys

OPTIONS = ("A", "F1", "F1-R", "F2")
GAP_FACTOR_KEYS = {"G-010": "g010_factor_A", "G-011": "g011_factor_A", "G-041": "g041_factor_A"}


def factor(row, opt, shell):
    if opt == "A":
        return 1.0
    if opt == "F2":
        return row["f2_factor"]
    if opt == "F1-R" and row["gap"] in shell:
        return 1.0
    return row["f1_factor"]


def share(row):
    """Exact P0 share (P0 requirements / P0+P1 requirements of the gap); §11 prints it rounded to 2 decimals."""
    return row["p0_reqs"] / row["reqs"]


def compute(base, inp):
    """Returns {option: {p0, p0p1, one_time_p0, one_time, yearly, total_p0, total_p0p1, three_yr}}."""
    d = base["d012"]
    shell = set(base["f1r_shell_gaps"])
    adjust = inp.get("adjust_options", ["A", "F1", "F1-R"])  # S-3/S-5 extra work applies to both sides
    out = {}
    for opt in OPTIONS:
        p0 = p0p1 = 0.0
        for row in base["gaps"]:
            pw = row["a_pw"] * factor(row, opt, shell)
            if opt == "A" and row["gap"] == "G-067":
                pw = inp["g067_measured_pw"]  # measured extraction effort replaces the estimate
            key = GAP_FACTOR_KEYS.get(row["gap"])
            if key and opt in adjust:  # extra pw = A pw x (factor_A - 1), same on every adjusted option
                pw += row["a_pw"] * (inp.get(key, 1.0) - 1.0)
            p0 += pw * share(row)
            p0p1 += pw
        ot = d["one_time"]
        if opt == "A":
            one_p0 = one = ot["A_scaffold"]
            yearly = d["yearly"]["A"] - d["osaurus_share_of_A_yearly"] + inp["yearly_pw_osaurus"]
        elif opt in ("F1", "F1-R"):
            one_p0 = ot["F1_prune"] + ot["monolith_friction_ratio"] * p0
            one = ot["F1_prune"] + ot["monolith_friction_ratio"] * p0p1
            yearly = inp.get("yearly_" + opt, d["yearly"][opt])
        else:
            one_p0 = one = ot["F2_strip_and_sidecars"]
            yearly = inp.get("yearly_F2", d["yearly"]["F2"])
        r = lambda x: round(x, 2)
        out[opt] = {"p0": r(p0), "p0p1": r(p0p1), "one_time_p0": r(one_p0), "one_time": r(one),
                    "yearly": round(yearly, 4), "total_p0": r(p0 + one_p0), "total_p0p1": r(p0p1 + one),
                    "three_yr": r(p0p1 + one + 3 * yearly)}
    ratio = out["A"]["three_yr"] / out["F1-R"]["three_yr"]
    return out, round(ratio, 4), ratio > d["switch_ratio"]


def self_test(base):
    """Re-sum the transcribed baseline and reproduce D-012's totals with D-012's own inputs."""
    errors = [f"{r['gap']} share {r['p0_share']}" for r in base["gaps"] if round(share(r), 2) != r["p0_share"]]
    shell = set(base["f1r_shell_gaps"])
    for opt, (e0, e1) in base["expected_sums"].items():
        p0 = sum(r["a_pw"] * factor(r, opt, shell) * share(r) for r in base["gaps"])
        p1 = sum(r["a_pw"] * factor(r, opt, shell) for r in base["gaps"])
        if abs(p0 - e0) > 0.05 + 1e-9 or abs(p1 - e1) > 0.05 + 1e-9:  # §11 prints one decimal
            errors.append(f"{opt} baseline sums {p0:.2f}/{p1:.2f} != {e0}/{e1}")
    d = base["d012"]
    res, _, sw = compute(base, {"g067_measured_pw": d["g067_unmeasured_pw"],
                                "yearly_pw_osaurus": d["osaurus_share_of_A_yearly"]})
    for opt, exp in d["expected_3yr"].items():
        if abs(res[opt]["three_yr"] - exp) > 1.0:
            errors.append(f"{opt} D-012 3-year {res[opt]['three_yr']} != {exp} ±1")
    if sw:
        errors.append("D-012 inputs must not trigger the switch")
    return errors, res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--inputs")
    ap.add_argument("--out")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    base = json.load(open(a.baseline))
    errors, d012 = self_test(base)
    if a.self_test or not a.inputs:
        print(json.dumps({"self_test": "pass" if not errors else "fail", "errors": errors,
                          "d012_3yr": {o: d012[o]["three_yr"] for o in OPTIONS}}))
        if errors or not a.inputs:
            return 1 if errors else 0
    inp = json.load(open(a.inputs))
    res, ratio, sw = compute(base, inp)
    sens = []
    for s in inp.get("sensitivity", []):
        r2, q2, s2 = compute(base, {**inp, **s["overrides"]})
        sens.append({"name": s["name"], "overrides": s["overrides"], "three_yr": {o: r2[o]["three_yr"] for o in OPTIONS},
                     "ratio_A_over_F1R": q2, "switch": s2})
    result = {"rule": "switch = 3yr_A > 1.20 x 3yr_F1-R", "self_test": "pass" if not errors else "fail",
              "self_test_errors": errors, "options": res, "ratio_A_over_F1R": ratio, "switch": sw,
              "decision": "switch proposed" if sw else "A confirmed", "sensitivity": sens,
              "d012_3yr": {o: d012[o]["three_yr"] for o in OPTIONS}}
    text = json.dumps(result, indent=2) + "\n"
    if a.out:
        open(a.out, "w").write(text)
    print(text, end="")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
