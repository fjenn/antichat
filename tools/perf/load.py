#!/usr/bin/env python3
"""Machine-load sampling and the quiet-machine gate for `make perf` (M1.T26a). Stdlib only, no sudo.

This Mac is shared by several build agents, so every measurement records the load it ran under, and run.py refuses
(or, with --allow-noisy, flags) runs taken on a busy machine. test-strategy §6 / nfr.md "Statistics": idle machine,
AC power, normal thermal state.

Signals (each command is optional; a missing one is recorded as null, never guessed):
  load averages      os.getloadavg(); ncpu from sysctl hw.ncpu
  CPU busy %         `top -l 2 -s 1` second sample "CPU usage" line (the first sample is since boot)
  other-process CPU  same `top` sample, per process (cores = %CPU / 100), minus the processes being measured
  GPU busy %         `ioreg -r -d 1 -c IOAccelerator` PerformanceStatistics "Device Utilization %"
  GPU lock           /tmp/antichat-gpu.lock held by another job (`lockf -t 0` probe), the one-GPU-job rule
  power / thermal    `pmset -g batt` (AC?), `pmset -g therm` (CPU speed limit / warning level), `pmset -g` powermode
                     (Low Power Mode = 1 → noisy, also on AC; recorded in every sample and summary)
  memory             `memory_pressure -Q` free %, `sysctl vm.swapusage`
A background `Sampler` repeats the cheap signals every few seconds while a probe runs, so a burst of load in the
middle of a run is seen too (max / mean are recorded).

  python3 -I tools/perf/load.py                # print one sample + the verdict as JSON
  python3 -I tools/perf/load.py --gpu          # verdict with the GPU thresholds too
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import threading
import time

# Default thresholds (override per run: run.py --max-other-cores … or env ANTICHAT_PERF_MAX_*). Chosen for the
# 18-core M5 Max dev Mac [ASSUMPTION]: "quiet" = other processes use ≤ 2 cores (fseventsd alone idles near one core
# here) and the 1-min load average ≤ the core count (macOS counts I/O-blocked threads, so it reads high even when
# the CPU is mostly idle: load1 30 at 11% busy on 2026-10-30), which keeps a UI probe's main core and the GPU free.
THRESHOLDS = {
    "max_other_cores": float(os.environ.get("ANTICHAT_PERF_MAX_OTHER_CORES", 2.0)),
    "max_load1_per_cpu": float(os.environ.get("ANTICHAT_PERF_MAX_LOAD1_PER_CPU", 1.0)),
    "max_gpu_busy_pct": float(os.environ.get("ANTICHAT_PERF_MAX_GPU_BUSY", 10)),
    # Self-tests only (tools/ci/tests): a Mac in Low Power Mode must still be able to test the clean path.
    "allow_low_power": os.environ.get("ANTICHAT_PERF_ALLOW_LOW_POWER") == "1",
}
GPU_LOCK = "/tmp/antichat-gpu.lock"
# Processes that are part of a measurement (never counted as "other" load).
OWN = re.compile(r"^(AntiChat|AntiChatEngine|antichat-bench|csc-bench|llama-server|sd-server|top|python3?(\.[0-9]+)?|Python)$")  # csc-bench: the F7 probe itself; python3.N: the video runtime child (M9.T05)
NOISY_HINT = re.compile(r"^(swift-frontend|swift-build|swift-driver|clang|ld|xcodebuild|XCBBuildService|SWBBuildService|"
                        r"xctest|XCTRunner|AntiChat|AntiChatEngine|llama-server|sd-server|python3?|node|mds_stores|mdworker.*)")


def _run(cmd: list[str], timeout: float = 10) -> str | None:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.stdout if p.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def ncpu() -> int:
    out = _run(["sysctl", "-n", "hw.ncpu"])
    return int(out.strip()) if out and out.strip().isdigit() else (os.cpu_count() or 1)


def parse_top(text: str) -> dict:
    """Second sample of `top -l 2 -s 1 -n N -o cpu -stats pid,command,cpu`."""
    samples = text.split("Processes:")
    last = samples[-1] if len(samples) > 1 else text
    m = re.search(r"CPU usage:\s*([\d.]+)% user,\s*([\d.]+)% sys,\s*([\d.]+)% idle", last)
    procs = []
    head = re.search(r"^\s*PID\s+COMMAND\s+%CPU\s*$", last, re.M)
    if head:
        for line in last[head.end():].splitlines():
            mm = re.match(r"^\s*(\d+)\s+(.+?)\s+([\d.]+)\s*$", line)
            if mm:
                procs.append({"pid": int(mm.group(1)), "command": mm.group(2).strip(), "cpu_pct": float(mm.group(3))})
    return {"cpu_busy_pct": round(100 - float(m.group(3)), 1) if m else None, "top": procs}


def parse_gpu(text: str) -> float | None:
    vals = [int(x) for x in re.findall(r'"Device Utilization %"=(\d+)', text or "")]
    return float(max(vals)) if vals else None


def parse_batt(text: str) -> bool | None:
    if not text:
        return None
    return "AC Power" in text.splitlines()[0]


def parse_therm(text: str) -> str | None:
    if text is None:
        return None
    m = re.search(r"CPU_Speed_Limit\s*=\s*(\d+)", text)
    if m and int(m.group(1)) < 100:
        return f"speed_limit_{m.group(1)}"
    if re.search(r"thermal warning level.*?(\d+)", text) and "No thermal warning" not in text:
        return "warning"
    return "nominal"


def parse_swap(text: str) -> float | None:
    m = re.search(r"used = ([\d.]+)M", text or "")
    return round(float(m.group(1)) / 1024, 2) if m else None


def parse_mem_free(text: str) -> float | None:
    m = re.search(r"free percentage:\s*(\d+)%", text or "")
    return float(m.group(1)) if m else None


def parse_power_mode(text: str) -> int | None:
    """`pmset -g` (the active power source's live settings): `powermode` (macOS 14+: 0 automatic, 1 low power,
    2 high power) or the older `lowpowermode` 0/1. Low Power Mode throttles CPU and GPU (≈ 2.7× slower timing seen
    on AC, 2026-11-09), so any value 1 makes a measurement noisy. None = not reported."""
    m = re.search(r"^\s*(?:powermode|lowpowermode)\s+(\d+)", text or "", re.M)
    return int(m.group(1)) if m else None


def gpu_lock_held() -> bool | None:
    """True when another job holds the one-GPU-job lock (we only probe; never keep it). Under
    `~/AntiChat-tools/gpu-run.sh timing` the lock is held by our own wrapper, which exports
    ANTICHAT_GPU_LOCK_HELD=timing: then this probe is skipped (False); every other load check still applies."""
    if os.environ.get("ANTICHAT_GPU_LOCK_HELD") == "timing":
        return False
    if not os.path.exists(GPU_LOCK):
        return False
    try:
        p = subprocess.run(["lockf", "-t", "0", GPU_LOCK, "true"], capture_output=True, timeout=5)
        return p.returncode != 0
    except (OSError, subprocess.TimeoutExpired):
        return None


def sample(full: bool = True, own_pids: set[int] | None = None) -> dict:
    own_pids = own_pids or set()
    la = os.getloadavg()
    n = ncpu()
    s = {"t": time.time(), "load1": round(la[0], 2), "load5": round(la[1], 2), "load15": round(la[2], 2), "ncpu": n}
    top = _run(["top", "-l", "2", "-s", "1", "-n", "15", "-o", "cpu", "-stats", "pid,command,cpu"], timeout=15)
    t = parse_top(top or "")
    others = [p for p in t["top"] if p["pid"] not in own_pids and p["pid"] != os.getpid() and not OWN.match(p["command"])]
    s["cpu_busy_pct"] = t["cpu_busy_pct"]
    s["other_cores"] = round(sum(p["cpu_pct"] for p in others) / 100, 2) if top else None
    s["top_other"] = [f"{p['command']}:{p['cpu_pct']:.0f}%" for p in others[:6]]
    s["gpu_busy_pct"] = parse_gpu(_run(["ioreg", "-r", "-d", "1", "-c", "IOAccelerator"]) or "")
    s["power_mode"] = parse_power_mode(_run(["pmset", "-g"]) or "")  # every sample: the mode can change mid-run
    if full:
        s["gpu_lock_held"] = gpu_lock_held()
        s["ac_power"] = parse_batt(_run(["pmset", "-g", "batt"]) or "")
        s["thermal"] = parse_therm(_run(["pmset", "-g", "therm"]))
        s["swap_used_gb"] = parse_swap(_run(["sysctl", "vm.swapusage"]))
        s["mem_free_pct"] = parse_mem_free(_run(["memory_pressure", "-Q"]))
        s["build_like"] = sorted({p["command"] for p in t["top"] if NOISY_HINT.match(p["command"]) and p["pid"] not in own_pids
                                  and p["cpu_pct"] >= 5})
    return s


def verdict(samples: list[dict], gpu: bool, thresholds: dict | None = None) -> dict:
    """quality = clean | noisy, with the reasons. Uses the worst sample."""
    th = dict(THRESHOLDS, **(thresholds or {}))
    reasons = []
    def worst(k):
        vs = [s[k] for s in samples if s.get(k) is not None]
        return max(vs) if vs else None
    oc = worst("other_cores")
    if oc is not None and oc > th["max_other_cores"]:
        reasons.append(f"other processes use {oc:.2f} cores > {th['max_other_cores']}")
    l1 = worst("load1")
    n = samples[0].get("ncpu", 1) if samples else 1
    if l1 is not None and l1 / n > th["max_load1_per_cpu"]:
        reasons.append(f"load1 {l1:.2f} / {n} cpu > {th['max_load1_per_cpu']}")
    if gpu:
        g = worst("gpu_busy_pct")
        if g is not None and g > th["max_gpu_busy_pct"]:
            reasons.append(f"GPU busy {g:.0f}% > {th['max_gpu_busy_pct']}% before the run")
    for s in samples:
        if s.get("ac_power") is False:
            reasons.append("on battery (nfr.md Statistics: AC power)")
            break
    for s in samples:
        if s.get("power_mode") == 1 and not th.get("allow_low_power"):
            reasons.append("low power mode (pmset powermode 1: CPU/GPU throttled; owner: `sudo pmset -c powermode 0` "
                           "or System Settings › Battery › Low Power Mode: Only on Battery / Never)")
            break
    for s in samples:
        if s.get("thermal") not in (None, "nominal"):
            reasons.append(f"thermal {s['thermal']}")
            break
    return {"quality": "noisy" if reasons else "clean", "reasons": reasons, "thresholds": th}


def summarize(samples: list[dict]) -> dict:
    """Compact record stored with every measurement."""
    def agg(k):
        vs = [s[k] for s in samples if s.get(k) is not None]
        return {"max": max(vs), "mean": round(sum(vs) / len(vs), 2)} if vs else None
    first = samples[0] if samples else {}
    return {
        "n_samples": len(samples), "ncpu": first.get("ncpu"),
        "load1": agg("load1"), "cpu_busy_pct": agg("cpu_busy_pct"), "other_cores": agg("other_cores"),
        "gpu_busy_pct": agg("gpu_busy_pct"),
        "ac_power": first.get("ac_power"), "thermal": first.get("thermal"),
        "power_mode": max((s["power_mode"] for s in samples if s.get("power_mode") is not None), default=None), "swap_used_gb": first.get("swap_used_gb"),
        "mem_free_pct": first.get("mem_free_pct"), "gpu_lock_held_before": first.get("gpu_lock_held"),
        "build_like": sorted({c for s in samples for c in s.get("build_like", [])}),
        "top_other": first.get("top_other", []),
    }


class Sampler:
    """Samples the cheap signals every `interval` s on a thread while a probe runs."""

    def __init__(self, interval: float = 5.0, own_pids: set[int] | None = None):
        self.interval, self.own_pids = interval, own_pids or set()
        self.samples: list[dict] = []
        self._stop = threading.Event()
        self._t = threading.Thread(target=self._loop, daemon=True)

    def _loop(self):
        while not self._stop.wait(self.interval):
            self.samples.append(sample(full=False, own_pids=self.own_pids))

    def __enter__(self):
        self._t.start()
        return self

    def __exit__(self, *exc):
        self._stop.set()
        self._t.join(timeout=20)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gpu", action="store_true")
    a = ap.parse_args()
    s = sample()
    print(json.dumps({"sample": s, "verdict": verdict([s], a.gpu)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
