#!/usr/bin/env python3
"""M9.T06 AT-NFR-S1: crash-free sessions across the M9 test runs. Stdlib only.

  python3 -I tools/perf/crash-free.py --since <M9 start, YYYY-MM-DD[THH:MM]> --min-sessions 400
          [--unified-log] [--exclude-kind FinalAcceptanceProbe,…] [--extra-sessions N] [--out build/at/AT-NFR-S1/<date>.json]

Sessions = app launches of the test-flavoured builds (UI suites, probes, benches, perf, visual QA, the soak):
  1. the session ledger every Debug / perf-harness launch appends to (`~/Library/Logs/AntiChat-Dev/sessions.jsonl`,
     App/AntiChat/SessionLedger.swift: start + normal end, pid, bundle, kind, dev container) — the primary source;
  2. `--unified-log`: AntiChat processes that logged under subsystem app.antichat since `--since` (`log show`; slow, and
     only as far back as the log is retained) for launches before the ledger existed; pids the ledger has are not
     counted twice;
  3. `--extra-sessions N` for counted launches without either (stated in the report as unverified).
Crashes = `.ips` crash reports (bug_type 309/109/385) of AntiChat, AntiChatEngine, llama-server or sd-server since
`--since` + MetricKit crash diagnostics (`crash-*.json` the app's MetricKitCrashSubscriber keeps in each container's
Diagnostics/, the soak's probe/metrickit/; `--metrickit-glob`), deduplicated by pid. A crash belongs to the session
whose pid crashed; a helper / llama-server / sd-server crash to the session whose bundle holds that executable and that
was running then (else it counts as one more crashed session). Crash-free = sessions without a crash / sessions.
Lost saved messages: for a crashed session whose run kept a saved-message ledger (the soak's probe/saved.jsonl), every
saved reply must still be `done` in its container database; crashes without that evidence are listed as `unverified`
(their chat must be checked by canonical dump, tools/install-test/steps/db-canon.py; `--allow-unverified` reports them
without failing).
Pass: ≥ `--min-sessions` sessions, crash-free ≥ 99.5 %, 0 lost saved messages (and no unverified crash).
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import sqlite3
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import crashscan  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
LEDGER = os.path.expanduser("~/Library/Logs/AntiChat-Dev/sessions.jsonl")
BAR = 0.995
MK_GLOBS = ["build/soak/*/container/Diagnostics/crash-*.json", "build/soak/*/probe/metrickit/diag-*.json",
            "build/at/**/Diagnostics/crash-*.json"]


def parse_since(s: str) -> float:
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%d"):
        try:
            return dt.datetime.strptime(s, fmt).timestamp()
        except ValueError:
            pass
    raise SystemExit(f"--since {s}: use YYYY-MM-DD[THH:MM[:SS]]")


def ledger_sessions(path: str, since: float) -> dict[int, dict]:
    """pid → session (start, end, bundle, kind, container); a pid reused later keeps the latest start."""
    sessions: dict[int, dict] = {}
    try:
        f = open(path, encoding="utf-8")
    except OSError:
        return sessions
    with f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            pid = e.get("pid")
            if not isinstance(pid, int):
                continue
            if e.get("event") == "start" and e.get("t", 0) >= since:
                sessions[pid] = {"pid": pid, "start": e["t"], "end": None, "bundle": e.get("bundle", ""),
                                 "kind": e.get("kind", "app"), "container": e.get("container"), "source": "ledger"}
            elif e.get("event") == "end" and pid in sessions and sessions[pid]["end"] is None:
                sessions[pid]["end"] = e.get("t")
    return sessions


def unified_log_sessions(since: float) -> tuple[dict[int, dict], str | None]:
    start = dt.datetime.fromtimestamp(since).strftime("%Y-%m-%d %H:%M:%S")
    try:
        p = subprocess.run(["log", "show", "--start", start, "--style", "ndjson", "--predicate",
                            'subsystem BEGINSWITH "app.antichat" AND process == "AntiChat"'],
                           capture_output=True, text=True, timeout=3600)
    except (OSError, subprocess.TimeoutExpired) as e:
        return {}, f"log show: {e}"
    out: dict[int, dict] = {}
    for line in p.stdout.splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        pid = e.get("processID")
        if isinstance(pid, int) and pid not in out:
            ts = e.get("timestamp", "")
            try:
                t = dt.datetime.strptime(ts[:26], "%Y-%m-%d %H:%M:%S.%f").timestamp()
            except ValueError:
                t = since
            out[pid] = {"pid": pid, "start": t, "end": None, "bundle": os.path.dirname(os.path.dirname(os.path.dirname(
                e.get("processImagePath", "")))), "kind": "unified-log", "container": None, "source": "unified-log"}
    return out, None


def metrickit_crashes(globs: list[str], since: float) -> list[dict]:
    out, seen = [], set()
    for g in globs:
        for p in glob.glob(os.path.join(ROOT, g) if not os.path.isabs(g) else g, recursive=True):
            if p in seen or os.path.getmtime(p) < since:
                continue
            seen.add(p)
            try:
                d = json.load(open(p))
            except (OSError, ValueError):
                continue
            diags = d.get("crashDiagnostics") if isinstance(d, dict) and "crashDiagnostics" in d else [d]
            for c in diags or []:
                if not isinstance(c, dict):
                    continue
                meta = c.get("diagnosticMetaData") or c.get("metaData") or {}
                if "crash" not in os.path.basename(p) and "exceptionType" not in json.dumps(meta):
                    continue  # a diag payload without a crash
                out.append({"path": p, "pid": meta.get("pid"), "time": os.path.getmtime(p), "name": "AntiChat", "source": "metrickit"})
    return out


def lost_for(session: dict) -> dict | None:
    """The soak's saved-message check for a crashed session (None = no evidence available)."""
    c = session.get("container")
    if not c:
        return None
    saved = os.path.join(os.path.dirname(c.rstrip("/")), "probe", "saved.jsonl")
    db = os.path.join(c, "antichat.sqlite")
    if not (os.path.exists(saved) and os.path.exists(db)):
        return None
    rows = [json.loads(x) for x in open(saved) if x.strip()]
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    lost = [r["message"] for r in rows
            if (con.execute("SELECT status FROM message WHERE id = ?", (r["message"],)).fetchone() or [None])[0] != "done"]
    con.close()
    return {"checked": len(rows), "lost": lost}


def evaluate(sessions: dict[int, dict], crashes: list[dict], min_sessions: int, extra: int, allow_unverified: bool) -> dict:
    crashed: dict[int, list[dict]] = {}
    orphans = []
    for c in crashes:
        pid = c.get("pid")
        if isinstance(pid, int) and pid in sessions:
            crashed.setdefault(pid, []).append(c)
            continue
        owner = None
        for s in sessions.values():  # a helper-side crash: the session whose bundle holds the executable, running then
            if s["bundle"] and c.get("procPath", "").startswith(s["bundle"].rstrip("/") + "/") \
                    and s["start"] <= c["time"] <= (s["end"] or c["time"] + 1):
                owner = s["pid"]
        if owner is not None:
            crashed.setdefault(owner, []).append(c)
        else:
            orphans.append(c)
    n = len(sessions) + extra
    bad = len(crashed) + len(orphans)
    rate = (n - bad) / n if n else 0.0
    lost, unverified = [], []
    for pid in crashed:
        r = lost_for(sessions[pid])
        if r is None:
            unverified.append(pid)
        else:
            lost += r["lost"]
    unverified += [None] * len(orphans)
    passed = n >= min_sessions and rate >= BAR and not lost and (allow_unverified or not unverified)
    return {"sessions": n, "ledger_or_log_sessions": len(sessions), "extra_sessions": extra, "crashed_sessions": bad,
            "crash_free": rate, "bar": BAR, "min_sessions": min_sessions, "lost_saved_messages": lost,
            "unverified_crashes": len(unverified), "pass": passed,
            "crashes": [{"pid": c.get("pid"), "name": c.get("name"), "path": c.get("path"), "source": c.get("source", "ips"),
                         "session": p} for p, cs in crashed.items() for c in cs]
            + [{"pid": c.get("pid"), "name": c.get("name"), "path": c.get("path"), "source": c.get("source", "ips"),
                "session": None} for c in orphans]}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", required=True)
    ap.add_argument("--min-sessions", type=int, default=400)
    ap.add_argument("--ledger", default=LEDGER)
    ap.add_argument("--unified-log", action="store_true")
    ap.add_argument("--extra-sessions", type=int, default=0)
    ap.add_argument("--exclude-kind", default="", help="ledger kinds whose sessions crash on purpose (comma list)")
    ap.add_argument("--metrickit-glob", action="append", default=None)
    ap.add_argument("--reports-dir", action="append", default=None, help="tests: .ips directories")
    ap.add_argument("--allow-unverified", action="store_true")
    ap.add_argument("--out")
    a = ap.parse_args()
    since = parse_since(a.since)
    sessions = ledger_sessions(a.ledger, since)
    log_err = None
    if a.unified_log:
        extra_log, log_err = unified_log_sessions(since)
        for pid, s in extra_log.items():
            sessions.setdefault(pid, s)
    excluded = [k for k in a.exclude_kind.split(",") if k]
    dropped = {p for p, s in sessions.items() if s["kind"] in excluded}
    for p in dropped:
        sessions.pop(p)
    reps = crashscan.reports(since, a.reports_dir)
    ips = [r | {"source": "ips"} for r in crashscan.crashes(reps) if crashscan.is_antichat(r) and r.get("pid") not in dropped]
    mk = [c for c in metrickit_crashes(a.metrickit_glob or MK_GLOBS, since) if c.get("pid") not in dropped]
    ips_pids = {r.get("pid") for r in ips}
    crashes = ips + [c for c in mk if c.get("pid") is None or c["pid"] not in ips_pids]
    res = evaluate(sessions, crashes, a.min_sessions, a.extra_sessions, a.allow_unverified)
    kinds: dict[str, int] = {}
    for s in sessions.values():
        kinds[s["kind"]] = kinds.get(s["kind"], 0) + 1
    res.update({"at": "AT-NFR-S1", "since": a.since, "date": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
                "sources": {"ledger": a.ledger, "unified_log": a.unified_log, "unified_log_error": log_err,
                            "ips_dirs": a.reports_dir or crashscan.REPORT_DIRS, "metrickit_globs": a.metrickit_glob or MK_GLOBS},
                "sessions_by_kind": kinds, "excluded_kinds": excluded, "excluded_sessions": len(dropped),
                "command": "python3 -I tools/perf/crash-free.py " + " ".join(sys.argv[1:])})
    out = a.out or os.path.join(ROOT, "build/at/AT-NFR-S1", dt.date.today().isoformat() + ".json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump(res, f, indent=1, sort_keys=True, default=str)
    print(f"{'PASS' if res['pass'] else 'FAIL'} AT-NFR-S1: {res['sessions']} sessions (≥ {a.min_sessions}), "
          f"{res['crashed_sessions']} with a crash → crash-free {res['crash_free'] * 100:.2f} % (≥ 99.5 %), "
          f"lost saved messages {len(res['lost_saved_messages'])}, unverified crashes {res['unverified_crashes']} → {out}")
    return 0 if res["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
