#!/usr/bin/env python3
"""M9.T06 (AT-NFR-S3; also NFR-R1 evidence): continuous 1 s phys_footprint of ONE soak app's processes. Stdlib only.

  soak-sampler.py --bundle <AntiChat.app> --app-pid PID --out <dir> [--interval 1] [--scan 5]

Which processes: the app pid, every process whose executable lies inside `--bundle` (the engine helper
AntiChatEngine.xpc, llama-server, sd-server — each soak runs its own copy of the app, so this never matches the
concurrent test runs' AntiChat processes) and their descendants (re-scanned every `--scan` s; a restarted helper is
followed). Cost: one proc_pid_rusage per tracked pid per second, a pid-path scan every 5 s.

Writes `<out>/sampler.csv` (t_s, app, helper, children, engine = helper + its descendants, other = bundle processes
outside the helper's tree, total; bytes) and, every 60 s and
at exit, `<out>/sampler.json`: peaks (engine = what NFR-R1 bounds: the helper and its children, i.e. the same
quantity as `antichat-bench soak` / tools/soak/mini-soak.sh; app; total), the peak per process name and every pid seen
(name, path, first/last second) — soak-report.py matches crash reports against those pids. Ends when the app pid is gone
(+5 s) or on SIGTERM/SIGINT.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from footprint import phys_footprint  # noqa: E402  (ctypes rusage_info_v4, shared with NFR-R1's sampler)

_libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
PROC_PPID_ONLY = 6
PROC_PIDPATHINFO_MAXSIZE = 4096


def all_pids() -> list[int]:
    n = _libproc.proc_listallpids(None, 0)
    buf = (ctypes.c_int * (n + 256))()
    got = _libproc.proc_listallpids(buf, ctypes.sizeof(buf))
    return [p for p in buf[:max(0, got)] if p > 0]


def child_pids(pid: int) -> list[int]:
    buf = (ctypes.c_int * 512)()
    got = _libproc.proc_listpids(PROC_PPID_ONLY, ctypes.c_uint32(pid), buf, ctypes.sizeof(buf))
    return [p for p in buf[:max(0, got) // ctypes.sizeof(ctypes.c_int)] if p > 0]


def pid_path(pid: int) -> str:
    buf = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
    n = _libproc.proc_pidpath(pid, buf, PROC_PIDPATHINFO_MAXSIZE)
    return buf.value.decode("utf-8", "replace") if n > 0 else ""


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def scan(bundle: str, app_pid: int) -> dict[int, tuple[str, str]]:
    """pid → (executable path, root name): the app, processes inside the bundle, and their descendants; a descendant's
    root is the bundle process it descends from (llama-server / sd-server → AntiChatEngine)."""
    found: dict[int, tuple[str, str]] = {}
    if alive(app_pid):
        found[app_pid] = (pid_path(app_pid), "AntiChat")
    for p in all_pids():
        path = pid_path(p)
        if path.startswith(bundle + "/") and p not in found:
            found[p] = (path, os.path.basename(path))
    # The helper's tree first, so llama-server / sd-server (inside the bundle too) are rooted at AntiChatEngine.
    todo = sorted(found, key=lambda p: found[p][1] != "AntiChatEngine")
    rooted: set[int] = set()
    while todo:
        parent = todo.pop(0)
        for c in child_pids(parent):
            if c in rooted or c == app_pid:
                continue
            rooted.add(c)
            found[c] = (found[c][0] if c in found else pid_path(c), found[parent][1])
            todo.append(c)
    return found


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle", required=True)
    ap.add_argument("--app-pid", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--scan", type=float, default=5.0)
    a = ap.parse_args()
    bundle = os.path.realpath(a.bundle).rstrip("/")
    os.makedirs(a.out, exist_ok=True)
    stop = {"now": False}
    for s in (signal.SIGTERM, signal.SIGINT):
        signal.signal(s, lambda *_: stop.update(now=True))
    csv = open(os.path.join(a.out, "sampler.csv"), "w", buffering=1)
    csv.write("t_s,app,helper,children,engine,other,total\n")
    seen: dict[int, dict] = {}
    peak = {"engine": 0, "engine_t": 0.0, "app": 0, "app_t": 0.0, "total": 0, "total_t": 0.0}
    by_name: dict[str, int] = {}
    t0 = time.monotonic()
    tracked: dict[int, tuple[str, str]] = {}
    next_scan = next_dump = 0.0
    gone_at = None
    n = 0

    def dump() -> None:
        out = {"bundle": bundle, "app_pid": a.app_pid, "interval_s": a.interval, "samples": n,
               "seconds": round(time.monotonic() - t0, 1), "peak_engine_bytes": peak["engine"], "peak_engine_t_s": peak["engine_t"],
               "peak_app_bytes": peak["app"], "peak_app_t_s": peak["app_t"], "peak_total_bytes": peak["total"],
               "peak_total_t_s": peak["total_t"], "peak_by_name": by_name,
               "pids": {str(k): v for k, v in sorted(seen.items())}, "app_exited_t_s": gone_at}
        tmp = os.path.join(a.out, "sampler.json.tmp")
        with open(tmp, "w") as f:
            json.dump(out, f, indent=1, sort_keys=True)
        os.replace(tmp, os.path.join(a.out, "sampler.json"))

    while not stop["now"]:
        t = time.monotonic() - t0
        if t >= next_scan:
            tracked = scan(bundle, a.app_pid)
            next_scan = t + a.scan
        app = helper = kids = other = 0
        for pid, (path, root) in list(tracked.items()):
            fp = phys_footprint(pid)
            if fp == 0 and not alive(pid):
                tracked.pop(pid, None)
                continue
            name = os.path.basename(path) or "?"
            s = seen.setdefault(pid, {"name": name, "path": path, "root": root, "first_t_s": round(t, 1)})
            s["last_t_s"] = round(t, 1)
            by_name[name] = max(by_name.get(name, 0), fp)
            if pid == a.app_pid:
                app += fp
            elif name == "AntiChatEngine":
                helper += fp
            elif root == "AntiChatEngine":
                kids += fp  # llama-server, sd-server, …
            else:
                other += fp  # bundle processes outside the helper's tree (e.g. the standby service)
        engine, total = helper + kids, app + helper + kids + other
        for k, v in (("engine", engine), ("app", app), ("total", total)):
            if v > peak[k]:
                peak[k], peak[k + "_t"] = v, round(t, 1)
        csv.write(f"{t:.1f},{app},{helper},{kids},{engine},{other},{total}\n")
        n += 1
        if gone_at is None and not alive(a.app_pid):
            gone_at = round(t, 1)
        if gone_at is not None and t - gone_at > 5:
            break
        if t >= next_dump:
            dump()
            next_dump = t + 60
        time.sleep(max(0.0, a.interval - (time.monotonic() - t0 - t)))
    dump()
    return 0


if __name__ == "__main__":
    sys.exit(main())
