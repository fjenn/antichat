#!/usr/bin/env python3
"""Evaluate AT-M0-10 from the `-Bench firstchat` raw runs; write result.json, runs.csv and the report.json keys
m0.M5.50mbps, m0.M5.10mbps, m0.D6.refetch_bytes. Exit 0 only if every check passes (M0.md C4)."""
from __future__ import annotations

import argparse
import csv
import json
import os
import platform
import statistics
import subprocess
import sys

CHUNK_BAR = 64 * 1024 * 1024  # NFR-D6: ≤ 1 chunk (≤ 64 MB) re-downloaded


def load(p: str) -> list[dict]:
    return [json.loads(l) for l in open(p) if l.strip()] if os.path.exists(p) else []


def pct(xs: list[float], q: float) -> float:
    xs = sorted(xs)
    if not xs:
        return -1
    k = (len(xs) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--raw", required=True)
    ap.add_argument("--report", required=True)
    ap.add_argument("--commit", required=True)
    o = ap.parse_args()
    runs = {k: load(os.path.join(o.raw, f"firstchat-{k}.jsonl")) for k in ("50", "10", "disconnect", "kill", "stall", "corrupt")}
    checks, rep_keys = [], {}
    for rate, n_min, bar in (("50", 10, 120.0), ("10", 5, 600.0)):
        rs = runs[rate]
        ok = [r for r in rs if "error" not in r and r["download_to_first_token_s"] > 0 and r["verified_files"] == r["files"]]
        xs = [r["download_to_first_token_s"] for r in ok]
        p50 = statistics.median(xs) if xs else -1
        label = rs[0]["label"] if rs else "?"
        checks.append({"name": f"NFR-M5 download start -> first token at {rate} Mbps {label}",
                       "value": {"p50_s": round(p50, 2), "p95_s": round(pct(xs, 0.95), 2), "n": len(xs),
                                 "download_p50_s": round(statistics.median([r['download_s'] for r in ok]), 2) if ok else -1},
                       "bar": f"p50 <= {bar:.0f} s, n >= {n_min}", "pass": len(xs) >= n_min and 0 < p50 <= bar})
        rep_keys[f"m0.M5.{rate}mbps"] = {"p50": round(p50, 3), "p95": round(pct(xs, 0.95), 3), "n": len(xs), "unit": "s", "nfr": "NFR-M5",
                                         "target": bar, "scaled_from": None, "label": label, "model": "chat-0.8b (0.67 GB)"}
    allr = [r for v in runs.values() for r in v]
    checks.append({"name": "every file sha256/git-sha1 verified before load", "value": sum(1 for r in allr if r.get("verified_files") == r.get("files")),
                   "bar": f"all {len(allr)} runs", "pass": bool(allr) and all(r.get("verified_files") == r.get("files") for r in allr)})
    refetch = []
    for kind in ("disconnect", "kill"):
        rs = runs[kind]
        vals = [r["refetched_bytes"] for r in rs]
        refetch += vals
        checks.append({"name": f"resume after {kind} re-fetches <= 1 chunk (64 MB)", "value": vals, "bar": f"3/3 <= {CHUNK_BAR}",
                       "pass": len(vals) >= 3 and all(0 <= v <= CHUNK_BAR for v in vals) and all(r.get("download_to_first_token_s", -1) > 0 for r in rs)})
    st = runs["stall"]
    checks.append({"name": "10 s zero-bandwidth stall (information)", "value": [r["refetched_bytes"] for r in st], "bar": "reported", "pass": True})
    co = runs["corrupt"]
    c = co[0] if co else {}
    checks.append({"name": "corrupted blob detected and only that file re-fetched", "value": {
        "detected": c.get("corrupt_detected"), "refetch_bytes": c.get("corrupt_refetch_bytes"), "file_size": c.get("corrupt_file_size")},
        "bar": "detected == [model.safetensors]; re-fetch == that file's size",
        "pass": bool(c) and c.get("corrupt_detected") == ["model.safetensors"] and c.get("corrupt_refetch_bytes") == c.get("corrupt_file_size")})
    rep_keys["m0.D6.refetch_bytes"] = {"p50": statistics.median(refetch) if refetch else -1, "p95": max(refetch) if refetch else -1,
                                      "n": len(refetch), "unit": "B", "nfr": "NFR-D6", "target": CHUNK_BAR, "scaled_from": None,
                                      "label": "measured (chunk %s MB)" % (runs["kill"][0]["chunk_mb"] if runs["kill"] else "?")}
    with open(os.path.join(o.out, "runs.csv"), "w", newline="") as f:
        cols = ["test", "run", "rate_mbps", "label", "chunk_mb", "download_to_first_token_s", "download_s", "ttft_after_download_s",
                "gpu_lock_wait_s", "total_bytes", "received_bytes", "prior_bytes", "refetched_bytes", "hf_requests", "attempts", "verified_files", "files", "error"]
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for r in allr:
            w.writerow({k: r.get(k, "") for k in cols})
    rep = json.load(open(o.report)) if os.path.exists(o.report) else {}
    rep.update(rep_keys)
    with open(o.report, "w") as f:
        json.dump(rep, f, indent=2, sort_keys=True)
        f.write("\n")
    hw = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    res = {"at": "AT-M0-10", "pass": all(c["pass"] for c in checks), "checks": checks, "commit": o.commit,
           "hf_requests_total": sum(r.get("hf_requests", 0) for r in allr),
           "host": {"chip": hw, "macos": platform.mac_ver()[0], "throttle": "[EMULATED] token bucket (no admin, no NLC)"}}
    with open(os.path.join(o.out, "result.json"), "w") as f:
        json.dump(res, f, indent=2)
        f.write("\n")
    for ch in checks:
        print(("[pass] " if ch["pass"] else "[FAIL] ") + ch["name"], json.dumps(ch["value"])[:160])
    print("AT-M0-10", "PASS" if res["pass"] else "FAIL")
    return 0 if res["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
