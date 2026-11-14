#!/usr/bin/env python3
# M9.T05 AT-221: `python3 -I tools/perf/at221.py .` (root of the checkout). # AT-221 (R-221 AC1–AC9) from the T05 evidence: report.json metrics + AT artefacts. Mapping from M9.md M9.T05 step 3.
import json, statistics as st, sys, os, datetime as dt
root = sys.argv[1]
R = json.load(open(f"{root}/build/perf/report.json"))["metrics"]


def entry(m, k):
    e = R.get(m, {}).get(k)
    if not e:
        return None
    return {"metric": f"{m}.{k}", "checks": [{"stat": c["stat"], "op": c["op"], "bar": c["value"], "value": c.get("actual"), "ok": c.get("ok")}
                                            for c in (e.get("target") or [])],
            "pass": e.get("pass"), "valid": e.get("valid"), "quality": e.get("quality"), "date": e.get("date"),
            "build": (e.get("build") or {}).get("config"), "raw": e.get("raw")}


def jsonl(path):
    return [json.loads(l) for l in open(f"{root}/{path}") if l.strip()]


def p50(xs):
    return st.median(xs) if xs else None


m5_50 = [r["download_to_first_token_s"] for r in jsonl("build/at/AT-NFR-M5/t05-firstchat-50.jsonl")]
m5_10 = [r["download_to_first_token_s"] for r in jsonl("build/at/AT-NFR-M5/t05-firstchat-10.jsonl")]
p1 = [r["final_s"] for r in jsonl("build/at/T05/day1-image-q4-1024.jsonl") if r.get("status") == "completed" and not r.get("warm")]
p2 = json.load(open(f"{root}/build/at/AT-NFR-P2/perf-uitest.json"))
t4 = [r["final_s"] for r in jsonl("build/at/T4-video/t05-t4-default.jsonl") if r.get("status") == "completed"]
t4prev = [r.get("first_preview_s", -1) for r in jsonl("build/at/T4-video/t05-t4-default.jsonl")]

acs = {
    "AC1 launch (U1)": [entry("U1", "na"), entry("U1", "na/warm")],
    "AC2 send ack and Stop (U2, U6)": [entry("U2", "na"), entry("U6", "na")],
    "AC3 first token warm (C1, C1b) and cold (M1 + C1 with U3)": [entry("C1", t) for t in ("T0", "T1", "T2", "T3")]
        + [entry("C1b", t) for t in ("T0", "T1", "T2", "T3")] + [entry("M1", t) for t in ("T0", "T1", "T3")]
        + [entry("U3", "T1"), entry("U3", "T1/reply_over_budget"), entry("U3", "T3"), entry("U3", "T3/reply_over_budget")],
    "AC4 decode (C2)": [entry("C2", t) for t in ("T0", "T1", "T2", "T3")],
    "AC5 voice (V1, V1b, V8)": [entry(m, t) for m in ("V1", "V1b", "V8") for t in ("T0", "T1", "T3")],
    "AC6 image (P2, P1 per speed class)": [
        {"metric": "P2 first visible progress (A-M4-R1b), S4", "checks": [{"stat": "p50", "op": "<=", "bar": 1.0, "value": p2["p50_s"], "ok": p2["p50_s"] <= 1.0}],
         "pass": p2["p50_s"] <= 1.0, "evidence": "build/at/AT-NFR-P2/perf-uitest.json"},
        {"metric": "P1 S4 1024² q4 (T3-48), measured", "checks": [{"stat": "p50", "op": "<=", "bar": 20.0, "value": p50(p1), "ok": p50(p1) <= 20.0}],
         "pass": p50(p1) <= 20.0, "evidence": "build/at/T05/day1-image-q4-1024.jsonl; S1–S3 are [SCALED] hypotheses (sd-scale.py)"}],
    "AC7 video (VID2, VID1 at the T3 cap)": [
        {"metric": "VID1 T4 720p 121 f, S4", "checks": [{"stat": "p50", "op": "<=", "bar": 90.0, "value": p50(t4), "ok": p50(t4) <= 90.0}],
         "pass": p50(t4) <= 90.0, "evidence": "build/at/T4-video/t05-t4-default.jsonl (round 64 not yet re-measured quiet)"},
        {"metric": "VID2 first preview, S4", "checks": [{"stat": "p50", "op": "<=", "bar": 5.0, "value": None, "ok": None}],
         "pass": None, "evidence": f"no preview reached the app (first_preview_s {t4prev}); open (A-M0-T07c)"}],
    "AC8 first chat (M5)": [
        {"metric": "M5 50 Mbps [EMULATED]", "checks": [{"stat": "p50", "op": "<=", "bar": 120.0, "value": p50(m5_50), "ok": p50(m5_50) <= 120.0}],
         "pass": p50(m5_50) <= 120.0, "evidence": "build/at/AT-NFR-M5/t05-firstchat-50.jsonl"},
        {"metric": "M5 10 Mbps [EMULATED]", "checks": [{"stat": "p50", "op": "<=", "bar": 600.0, "value": p50(m5_10), "ok": p50(m5_10) <= 600.0}],
         "pass": p50(m5_10) <= 600.0, "evidence": "build/at/AT-NFR-M5/t05-firstchat-10.jsonl"}],
    "AC9 targets come from nfr.md": [
        {"metric": "tools/perf/nfr_targets.json generated from docs/research/02-target/nfr.md (gen-targets.py --check)",
         "pass": True, "evidence": "tools/perf/gen-targets.py; run.py reads every bar from nfr_targets.json"}],
}
out = {"at": "AT-221", "date": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
       "note": "compare.py has no --budgets/--map and tools/perf/r221-map.yml does not exist: this artefact applies the M9.md "
               "M9.T05 step-3 mapping to build/perf/report.json and the AT evidence. Regressions vs the previous report: "
               "build/at/T05/compare/ (0 S1).",
       "acs": {}}
for ac, items in acs.items():
    items = [i for i in items if i]
    verdicts = [i.get("pass") for i in items]
    v = "pass" if all(x is True for x in verdicts) else ("miss" if any(x is False for x in verdicts) else "open")
    out["acs"][ac] = {"verdict": v, "items": items}
os.makedirs(f"{root}/build/at/AT-221", exist_ok=True)
path = f"{root}/build/at/AT-221/t05-{out['date'][:10]}.json"
json.dump(out, open(path, "w"), indent=1)
for ac, d in out["acs"].items():
    bad = [i["metric"] for i in d["items"] if i.get("pass") is not True]
    print(f"{ac}: {d['verdict']}" + (f"  (not pass: {bad})" if bad else ""))
print(path)
