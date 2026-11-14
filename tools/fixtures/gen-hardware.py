#!/usr/bin/env python3
"""M2.T01: writes fixtures/hardware/<name>.json (-FakeHardware fixtures) and expected.json.

Each fixture holds the raw facts the probe reads (sysctl, IOKit AGXAccelerator, Metal working set, OS, disk,
power). Only t4-m5max-128 is recorded from this Mac (2026-11-03); the rest are synthetic [ASSUMPTION]: RAM from
the chip's memory options (hardware-tiers §1.1), W = recommendedMaxWorkingSetSize by the K-002 curve
(2/3 of RAM up to 36 GB, 75% at 48/64, 78% at 96, 84% at 128 measured).

expected.json is computed here independently of the Swift classifier, straight from hardware-tiers §2.1-§2.3:
  B = min(W, RAM - H_os - 0.5), tier by RAM, sub-bands T2 {24,32,36} and T4 {96,128}, speed class by chip table.
Usage: python3 -I tools/fixtures/gen-hardware.py [fixtures-root]
"""
import json, os, sys

GiB = 1 << 30
H_OS = {8: 3.5, 16: 6, 18: 6, 24: 7, 32: 8, 36: 8, 48: 10, 64: 12, 96: 14, 128: 16}
W_FRACTION = {8: 2 / 3, 16: 2 / 3, 18: 2 / 3, 24: 2 / 3, 32: 2 / 3, 36: 2 / 3, 48: 0.75, 64: 0.75, 96: 0.78}

# name: (brand, ram GB, gpu cores, p, e, os, build, free disk GB, power, speed class, bandwidth, synthetic)
FIXTURES = {
    "t0-m1-8": ("Apple M1", 8, 8, 4, 4, "26.0.1", "25A362", 120, "battery", "S1", 68),
    "t0-a18pro-8": ("Apple A18 Pro", 8, 5, 2, 4, "26.1", "25B78", 90, "battery", "S1", 60),
    "t1-m2-16": ("Apple M2", 16, 10, 4, 4, "26.1", "25B78", 200, "battery", "S1", 100),
    "t1-m1-16": ("Apple M1", 16, 8, 4, 4, "26.0.1", "25A362", 180, "ac", "S1", 68),
    "t1-m3pro-18": ("Apple M3 Pro", 18, 18, 6, 6, "26.2", "25C56", 300, "battery", "S2", 150),
    "t2-m4-24": ("Apple M4", 24, 10, 4, 6, "26.3", "25D60", 400, "ac", "S1", 120),
    "t2-m2pro-32": ("Apple M2 Pro", 32, 19, 8, 4, "26.2", "25C56", 450, "ac", "S2", 200),
    "t2-m3max-36": ("Apple M3 Max", 36, 30, 10, 4, "26.4", "25E246", 500, "ac", "S3", 300),
    "t3-m4pro-48": ("Apple M4 Pro", 48, 20, 10, 4, "26.4", "25E246", 700, "ac", "S2", 273),
    "t3-m4max-64": ("Apple M4 Max", 64, 40, 12, 4, "26.5", "25F71", 900, "ac", "S3", 546),
    "t4-m3max-96": ("Apple M3 Max", 96, 40, 12, 4, "26.5", "25F71", 1200, "ac", "S3", 400),
    "t4-m5max-128": ("Apple M5 Max", 128, 40, 6, 12, "26.6.2", "25G83", 951, "ac", "S4", 614),
    # Unknown chip: classified by RAM; speed class from the recorded MicroProbe result (K-054).
    "unknown-m7-32": ("Apple M7", 32, 12, 6, 6, "26.6.2", "25G83", 600, "ac", "S3", 210),
}
RECORDED = {"t4-m5max-128": 115448725504}  # this Mac: recommendedMaxWorkingSetSize, bytes


def tier(ram):
    if ram < 12: return "T0"
    if ram < 20: return "T1"
    if ram < 40: return "T2"
    if ram < 80: return "T3"
    return "T4"


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "..", "fixtures")
    out = os.path.join(root, "hardware")
    os.makedirs(out, exist_ok=True)
    expected = {}
    for name, (brand, ram, gpu, p, e, osv, build, free, power, sc, bw) in FIXTURES.items():
        mem = ram * GiB
        w = RECORDED.get(name) or int(mem * W_FRACTION.get(ram, 0.84))
        fx = {
            "_source": "recorded on the dev Mac 2026-11-03" if name in RECORDED else "[ASSUMPTION] synthetic (no such Mac, D-003)",
            "sysctl": {"machdep.cpu.brand_string": brand, "hw.memsize": mem, "hw.perflevel0.physicalcpu": p,
                       "hw.perflevel1.physicalcpu": e, "kern.osversion": build, "kern.memorystatus_level": 80},
            "ioreg": {"AGXAccelerator.model": brand, "AGXAccelerator.gpu-core-count": gpu},
            "metal": {"recommendedMaxWorkingSetSize": w},
            "os": {"version": osv, "build": build},
            "volume": {"availableCapacityForImportantUsage": free * 1_000_000_000},
            "power": {"source": power},
            "fmAvailable": ram >= 16 and not brand.startswith("Apple A"),
        }
        if name.startswith("unknown"):
            fx["microProbe"] = {"bandwidthGBs": bw, "matmulTFLOPS": 14.0}
        with open(os.path.join(out, name + ".json"), "w") as f:
            json.dump(fx, f, indent=1, sort_keys=True)
            f.write("\n")
        t = tier(ram)
        b = min(w / 1e9, ram - H_OS[ram] - 0.5)
        sub = f"{t}-{ram}" if t in ("T2", "T4") else None
        expected[name] = {"tier": t, "subband": sub, "B": round(b, 2), "speedClass": sc, "bandwidthGBs": bw,
                          "speedClassSource": "probe" if name.startswith("unknown") else "table"}
    with open(os.path.join(out, "expected.json"), "w") as f:
        json.dump(expected, f, indent=1, sort_keys=True)
        f.write("\n")


if __name__ == "__main__":
    main()
