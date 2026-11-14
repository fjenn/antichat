"""M9.T06: crash / jetsam report scanning shared by soak-report.py and crash-free.py (stdlib only).

macOS writes one `.ips` per crash to ~/Library/Logs/DiagnosticReports (older ones move to `Retired/`): line 1 is a JSON
header (`bug_type`, `app_name`/`name`, `timestamp`), the rest the JSON body (`pid`, `procName`, `procPath`, …).
`bug_type` 309 = crash, 298 = JetsamEvent (body `processes`: every process with its `reason` when it was killed),
288/409 = stackshot/hang-ish reports (not crashes). Only reports of OUR processes count: callers match by pid (the pids
a soak's sampler saw) or by the executable path inside a given bundle — never by name alone, since concurrent test runs
start other AntiChat processes.
"""
from __future__ import annotations

import datetime as dt
import json
import os

REPORT_DIRS = [os.path.expanduser("~/Library/Logs/DiagnosticReports"),
               os.path.expanduser("~/Library/Logs/DiagnosticReports/Retired")]
PROCS = ("AntiChat", "AntiChatEngine", "llama-server", "sd-server")
CRASH_TYPES = {"309", "109", "385"}  # 309 crash (JSON ips), 109 legacy crash, 385 crash (corpse)
JETSAM_TYPES = {"298"}


def parse_ips(path: str) -> dict | None:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            first = f.readline()
            rest = f.read()
        header = json.loads(first)
    except (OSError, ValueError):
        return None
    try:
        body = json.loads(rest) if rest.strip() else {}
    except ValueError:
        body = {}
    return {"path": path, "header": header, "body": body, "bug_type": str(header.get("bug_type", "")),
            "name": header.get("app_name") or header.get("name") or body.get("procName") or "",
            "pid": body.get("pid"), "procPath": body.get("procPath") or "", "time": report_time(header, path)}


def report_time(header: dict, path: str) -> float:
    ts = header.get("timestamp") or ""
    for fmt in ("%Y-%m-%d %H:%M:%S.%f %z", "%Y-%m-%d %H:%M:%S %z"):
        try:
            return dt.datetime.strptime(ts, fmt).timestamp()
        except ValueError:
            pass
    return os.path.getmtime(path)


def reports(since: float, dirs: list[str] | None = None) -> list[dict]:
    """Every parseable .ips newer than `since` (epoch s)."""
    out = []
    for d in dirs or REPORT_DIRS:
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for n in names:
            if not n.endswith(".ips"):
                continue
            p = os.path.join(d, n)
            try:
                if os.path.getmtime(p) < since:
                    continue
            except OSError:
                continue
            r = parse_ips(p)
            if r and r["time"] >= since - 60:
                out.append(r)
    return sorted(out, key=lambda r: r["time"])


def is_ours(r: dict, pids: set[int] | None = None, bundle: str | None = None) -> bool:
    """A crash report of one of our processes: pid match or executable inside `bundle` (when given)."""
    if pids is not None and isinstance(r.get("pid"), int) and r["pid"] in pids:
        return True
    if bundle and r.get("procPath", "").startswith(bundle.rstrip("/") + "/"):
        return True
    return False


def is_antichat(r: dict) -> bool:
    """A crash report of an AntiChat process family (name), for the M9-wide count of crash-free.py."""
    name = os.path.basename(r.get("procPath") or "") or r.get("name", "")
    return name in PROCS or r.get("name", "") in PROCS or "/AntiChat" in (r.get("procPath") or "")


def crashes(rs: list[dict]) -> list[dict]:
    return [r for r in rs if r["bug_type"] in CRASH_TYPES]


def jetsam_kills(rs: list[dict], pids: set[int] | None = None, names: tuple[str, ...] = PROCS) -> list[dict]:
    """Processes a JetsamEvent report killed (`reason` set) that are ours (pid in `pids`, else by name)."""
    out = []
    for r in rs:
        if r["bug_type"] not in JETSAM_TYPES:
            continue
        for p in r["body"].get("processes", []) or []:
            if not isinstance(p, dict) or not p.get("reason"):
                continue
            mine = p.get("pid") in pids if pids is not None else p.get("name") in names
            if mine:
                out.append({"report": r["path"], "pid": p.get("pid"), "name": p.get("name"), "reason": p.get("reason"),
                            "time": r["time"]})
    return out
