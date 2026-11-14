#!/usr/bin/env python3
# M2.T22 step 6 (R-235 AC2): S1-scaled pre-router p95 from `antichat-bench router --runs N --json <in>`.
# GPU part (the embed request over XPC) × pp512(M5 Max) ÷ pp512(S1 chip) [INFERENCE] (hardware-tiers §2.3; the
# tools/perf/scale.py chip table); CPU part (Accelerate scoring) unscaled. S1 = M1 and M4; the key carries the worse.
# M2.T23b: the embed now runs while the user types (RoutePrefetch); the SEND-TIME cost is `send_prefetched` (a cached
# vector → CPU scoring only, unscaled as above) and, when the user sends before the vector is back, `send_cold_capped`
# (the wait is capped at PreRouter.sendBudget = 20 ms, then the turn goes out unscored). The key carries the worse of
# the two p95s; the old GPU-scaled number stays in the entry as `embed_s1_scaled_p95` (what a cold embed costs on S1).
#   python3 -I tools/router/scale-bench.py <bench.json> [--report build/perf/report.json]
import json, os, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "perf"))
import reportio  # noqa: E402
from scale import CHIPS  # noqa: E402

BAR_MS = 30.0


def main():
    src = json.load(open(sys.argv[1]))
    report = sys.argv[sys.argv.index("--report") + 1] if "--report" in sys.argv else "build/perf/report.json"
    lat = src["latency_ms"]
    gpu, cpu = lat["embed_xpc"]["p95"], lat["cpu"]["p95"]
    ref = CHIPS["M5 Max"][1]
    per = {chip: round(gpu * ref / CHIPS[chip][1] + cpu, 1) for chip in ("M1", "M4")}
    worst = max(per.values())
    if "send_prefetched" in lat:
        embed_s1 = worst
        worst = round(max(lat["send_prefetched"]["p95"], lat["send_cold_capped"]["p95"]), 2)
        entry = {"p50": round(lat["send_prefetched"]["p50"], 3), "p95": worst, "n": lat["n"], "bar": BAR_MS,
                 "pass": worst <= BAR_MS, "unit": "ms", "scaled": ["[INFERENCE]"],
                 "method": "send-time cost: prefetched vector (CPU scoring, unscaled) or the 20 ms capped wait",
                 "send_prefetched_p95": round(lat["send_prefetched"]["p95"], 3),
                 "send_cold_capped_p95": round(lat["send_cold_capped"]["p95"], 2), "embed_s1_scaled_p95": embed_s1,
                 "per_chip_embed": per, "measured_m5max_embed_p95": round(gpu, 2), "cap": src.get("cap")}
        with reportio.locked(report) as data:
            reportio.put_legacy(data, "bench.router.S1scaled.p95", entry, replace=True)
        print(json.dumps(entry))
        return
    entry = {"p50": round(lat["total"]["p50"], 2), "p95": worst, "n": lat["n"], "bar": BAR_MS, "pass": worst <= BAR_MS,
             "unit": "ms", "scaled": ["[INFERENCE]"], "per_chip": per, "measured_m5max_p95": round(lat["total"]["p95"], 2),
             "gpu_p95_measured": round(gpu, 2), "cpu_p95": round(cpu, 3), "cap": src.get("cap")}
    with reportio.locked(report) as data:
        reportio.put_legacy(data, "bench.router.S1scaled.p95", entry, replace=True)
    print(json.dumps(entry))


if __name__ == "__main__":
    main()
