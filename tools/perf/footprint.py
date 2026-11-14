#!/usr/bin/env python3
"""Sample `phys_footprint` of processes every 100 ms (NFR-R1; M0.md C5). Stdlib only (ctypes libproc).

  footprint.py --pids 123,456 | --match 'AntiChat|llama-server' [--interval 0.1] [--duration S]
               [--until-exit PID] [--out samples.json]

`--match` is re-resolved on every sample (pgrep -f), so helpers that restart are followed. Output:
{"max_total_bytes", "max_by_pid", "samples", "interval_s"}. `MTLDevice.currentAllocatedSize` cannot be read
from outside the process; the helper reports it in each `usage` event (`mtl_allocated_bytes`).
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import subprocess
import time

RUSAGE_INFO_V4 = 4


class RUsageInfoV4(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in (
        "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups", "ri_pageins", "ri_wired_size",
        "ri_resident_size", "ri_phys_footprint", "ri_proc_start_abstime", "ri_proc_exit_abstime",
        "ri_child_user_time", "ri_child_system_time", "ri_child_pkg_idle_wkups", "ri_child_interrupt_wkups",
        "ri_child_pageins", "ri_child_elapsed_abstime", "ri_diskio_bytesread", "ri_diskio_byteswritten",
        "ri_cpu_time_qos_default", "ri_cpu_time_qos_maintenance", "ri_cpu_time_qos_background",
        "ri_cpu_time_qos_utility", "ri_cpu_time_qos_legacy", "ri_cpu_time_qos_user_initiated",
        "ri_cpu_time_qos_user_interactive", "ri_billed_system_time", "ri_serviced_system_time",
        "ri_logical_writes", "ri_lifetime_max_phys_footprint", "ri_instructions", "ri_cycles",
        "ri_billed_energy", "ri_serviced_energy", "ri_interval_max_phys_footprint", "ri_runnable_time", "ri_flags")]


_libproc = ctypes.CDLL("/usr/lib/libproc.dylib")


def phys_footprint(pid: int) -> int:
    info = RUsageInfoV4()
    if _libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(RUSAGE_INFO_V4), ctypes.byref(info)) != 0:
        return 0
    return int(info.ri_phys_footprint)


def resolve(match: str | None, pids: list[int]) -> list[int]:
    if not match:
        return pids
    r = subprocess.run(["/usr/bin/pgrep", "-f", match], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split() if int(x) != os.getpid()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pids", default="")
    ap.add_argument("--match")
    ap.add_argument("--interval", type=float, default=0.1)
    ap.add_argument("--duration", type=float, default=0)
    ap.add_argument("--until-exit", type=int, default=0)
    ap.add_argument("--out")
    a = ap.parse_args()
    pids = [int(p) for p in a.pids.split(",") if p]
    start = time.time()
    max_total, by_pid, n = 0, {}, 0
    while True:
        cur = resolve(a.match, pids)
        total = 0
        for p in cur:
            fp = phys_footprint(p)
            total += fp
            by_pid[p] = max(by_pid.get(p, 0), fp)
        max_total = max(max_total, total)
        n += 1
        if a.duration and time.time() - start >= a.duration:
            break
        if a.until_exit:
            try:
                os.kill(a.until_exit, 0)
            except ProcessLookupError:
                break
        if not a.duration and not a.until_exit and n >= 1:
            break
        time.sleep(a.interval)
    out = {"max_total_bytes": max_total, "max_by_pid": by_pid, "samples": n, "interval_s": a.interval}
    s = json.dumps(out, indent=2)
    if a.out:
        with open(a.out, "w") as f:
            f.write(s + "\n")
    print(s)


if __name__ == "__main__":
    main()
