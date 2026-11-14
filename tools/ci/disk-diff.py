#!/usr/bin/env python3
"""Incognito disk diff (M1.T20, AT-090 / AT-NFR-PR3, test-strategy §7.5). Run with `python3 -I`.

Scope: every entry named `AntiChat*` or `app.antichat*` (case-insensitive) directly under
`~/Library/{Application Support,Caches,Logs,Saved Application State}` (the data folder, incl. the DB and its WAL/SHM,
dev containers `AntiChat-*`, caches, logs, window state), plus `~/Library/Preferences/app.antichat*.plist`
(grep-only: a preference write is reported but only fails when it holds a fixture phrase). `--home` overrides `~`.
`--own DIR` (diff / run): the run's own data folder under Application Support. Every *other* `AntiChat*` folder there
(the shared `AntiChat-Dev` with its dev model store, the Release container, other runs' dev containers) belongs to
other tracks working on this Mac at the same time: its changes are reported as `foreign` and grepped for the phrases
(a hit is still a LEAK), but a content-free write there is not this run's and does not fail (M8.T16: another track's
model download in `AntiChat-Dev/Models` failed PR3). The run must point the app away from those folders (a dev
container and its own dev model cache), so nothing of this run can land there except by a leak the grep catches.

  snapshot --out before.json                      record (size, mtime_ns, inode) of every file in scope
  diff --before before.json [--grep-fixture phrases.txt] [--out diff.json]
                                                  new / changed / removed files since the snapshot; exit 1 on any
                                                  violation
  run [--grep-fixture f] [--out diff.json] [--ready FILE --go FILE] [--timeout S] -- CMD...
                                                  snapshot → CMD → diff. With --ready/--go: start CMD, wait for it
                                                  to create READY (its own setup is done), snapshot, create GO, wait
                                                  for CMD to exit, diff (the in-process probe handshake).

Rules (M1.md T20 pass condition 2): zero new or changed files, except log files (`*.log`, `*.txt` under Logs) whose
added bytes contain no fixture phrase (content-free log lines are allowed); a removed file is reported and fails
too, except removed log files (rotation). Every new or changed file is grepped for every phrase (UTF-8, and
UTF-16LE for plists/SQLite pages); one hit is an S0 privacy failure. The test-build session ledger
(`Logs/AntiChat-Dev/sessions.jsonl`, Debug/perf builds only) is accepted only as appended ledger-schema lines. Allow-list entries need a justification
(`ALLOW` below; empty in M1).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOTS = ["Application Support", "Caches", "Logs", "Saved Application State"]
PREFIXES = ("antichat", "app.antichat")
# (path substring, justification) — content-free files the OS may touch during any session. Lead review required.
ALLOW: list[tuple[str, str]] = []


def scope(home: Path) -> list[Path]:
    out: list[Path] = []
    lib = home / "Library"
    for r in ROOTS:
        d = lib / r
        if not d.is_dir():
            continue
        for e in sorted(d.iterdir()):
            if e.name.lower().startswith(PREFIXES):
                out.append(e)
    prefs = lib / "Preferences"
    if prefs.is_dir():
        out += sorted(p for p in prefs.iterdir() if p.name.lower().startswith("app.antichat"))
    return out


def walk(home: Path) -> dict[str, list[int]]:
    files: dict[str, list[int]] = {}
    for top in scope(home):
        paths = [top] if top.is_file() else [Path(dp) / f for dp, _, fs in os.walk(top) for f in fs]
        for p in paths:
            try:
                st = p.lstat()
            except OSError:
                continue
            files[str(p)] = [st.st_size, st.st_mtime_ns, st.st_ino]
    return files


def snapshot(home: Path) -> dict:
    return {"home": str(home), "taken": time.time(), "files": walk(home)}


def load_phrases(path: str | None) -> list[str]:
    if not path:
        return []
    lines = Path(path).read_text(encoding="utf-8").splitlines()
    return [l.strip() for l in lines if l.strip() and not l.lstrip().startswith("#")]


def hits(data: bytes, phrases: list[str]) -> list[str]:
    found = []
    low = data.lower()
    for ph in phrases:
        for enc in ("utf-8", "utf-16-le"):
            if ph.lower().encode(enc) in low:
                found.append(ph)
                break
    return found


def is_log(path: str) -> bool:
    return "/Library/Logs/" in path and path.endswith((".log", ".txt"))


# The test-build session ledger (App/AntiChat/SessionLedger.swift, M9.T06, AT-NFR-S1): every Debug / perf-harness
# launch, the probe's own included, appends a `start` and an `end` line outside every container. Release builds never
# write it. It is accepted only as pure appends whose every line is a JSON object made of the ledger's own keys (pid,
# times, bundle path, container path, launch kind) — any other byte, a rewrite, or a phrase hit stays a violation.
LEDGER = "/Library/Logs/AntiChat-Dev/sessions.jsonl"
LEDGER_KEYS = {"event", "pid", "t", "kind", "bundle", "bundleID", "container", "uitest"}


def ledger_lines_ok(data: bytes) -> bool:
    if not data.endswith(b"\n"):
        return False
    for line in data.decode("utf-8", "replace").splitlines():
        try:
            obj = json.loads(line)
        except ValueError:
            return False
        if not isinstance(obj, dict) or not set(obj) <= LEDGER_KEYS or obj.get("event") not in ("start", "end"):
            return False
        if any(isinstance(v, (dict, list)) for v in obj.values()):
            return False
    return True


def read(path: str, start: int = 0) -> bytes:
    try:
        with open(path, "rb") as f:
            f.seek(start)
            return f.read()
    except OSError:
        return b""


def foreign_of(home: Path, own: str | None):
    """The `Application Support/AntiChat*` folders that are not `own` (None = no isolation)."""
    if not own:
        return lambda _p: False
    sup = str(home / "Library" / "Application Support") + "/"
    own_root = str(Path(own).resolve()).rstrip("/") + "/"

    def is_foreign(path: str) -> bool:
        return path.startswith(sup) and not (path + "/").startswith(own_root)
    return is_foreign


def diff(before: dict, home: Path, phrases: list[str], own: str | None = None) -> dict:
    is_foreign = foreign_of(home, own)
    old = before["files"]
    new = walk(home)
    entries, violations = [], []
    for path in sorted(set(old) | set(new)):
        a, b = old.get(path), new.get(path)
        if a == b:
            continue
        kind = "new" if a is None else "removed" if b is None else "changed"
        e: dict = {"path": path, "kind": kind}
        allowed = next((j for s, j in ALLOW if s in path), None)
        prefs = "/Library/Preferences/" in path
        if kind != "removed":
            ledger = path.endswith(LEDGER)
            appended = (is_log(path) or ledger) and a is not None and b[0] >= a[0] and b[2] == a[2]
            data = read(path, a[0] if appended else 0)
            e["bytes"] = len(data)
            e["phraseHits"] = hits(data, phrases)
            if e["phraseHits"]:
                e["verdict"] = "LEAK"
            elif is_log(path):
                e["verdict"] = "allowed: log lines without content"
            elif ledger and (appended or a is None) and ledger_lines_ok(data):
                e["verdict"] = "allowed: test-build session ledger lines (no content)"
            elif prefs:
                e["verdict"] = "reported: preferences (no content)"
            elif is_foreign(path):
                e["verdict"] = "foreign: another container (no content)"
            elif allowed:
                e["verdict"] = f"allowed: {allowed}"
            else:
                e["verdict"] = "violation: file written"
        else:
            e["verdict"] = ("allowed: log rotation" if is_log(path) else
                            "foreign: another container" if is_foreign(path) else "violation: file removed")
        if e["verdict"].startswith(("LEAK", "violation")):
            violations.append(path)
        entries.append(e)
    return {"home": str(home), "phrases": len(phrases), "scope": [str(p) for p in scope(home)], "own": own,
            "filesBefore": len(old), "filesAfter": len(new), "entries": entries,
            "violations": violations, "pass": not violations}


def write_out(result: dict, out: str | None) -> None:
    text = json.dumps(result, indent=2, sort_keys=True)
    if out:
        Path(out).parent.mkdir(parents=True, exist_ok=True)
        Path(out).write_text(text + "\n")
    for e in result["entries"]:
        print(f"{e['kind']:8} {e['verdict']:40} {e['path']}")
    print(f"disk-diff: {len(result['entries'])} entries, {len(result['violations'])} violations, "
          f"pass={result['pass']}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--home", default=str(Path.home()))
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("snapshot")
    s.add_argument("--out", required=True)
    d = sub.add_parser("diff")
    d.add_argument("--before", required=True)
    d.add_argument("--grep-fixture")
    d.add_argument("--out")
    d.add_argument("--own")
    r = sub.add_parser("run")
    r.add_argument("--own")
    r.add_argument("--grep-fixture")
    r.add_argument("--out")
    r.add_argument("--ready")
    r.add_argument("--go")
    r.add_argument("--timeout", type=float, default=900)
    r.add_argument("command", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    home = Path(a.home)
    if a.cmd == "snapshot":
        Path(a.out).write_text(json.dumps(snapshot(home)))
        return 0
    if a.cmd == "diff":
        result = diff(json.loads(Path(a.before).read_text()), home, load_phrases(a.grep_fixture), a.own)
        write_out(result, a.out)
        return 0 if result["pass"] else 1
    cmd = a.command[1:] if a.command[:1] == ["--"] else a.command
    if not cmd:
        ap.error("run needs -- CMD")
    if a.ready:
        for f in (a.ready, a.go):
            if f and os.path.exists(f):
                os.remove(f)
        proc = subprocess.Popen(cmd)
        deadline = time.time() + a.timeout
        while not os.path.exists(a.ready):
            if proc.poll() is not None or time.time() > deadline:
                print(f"disk-diff: command ended or timed out before {a.ready}", file=sys.stderr)
                proc.kill()
                return 2
            time.sleep(0.2)
        before = snapshot(home)
        if a.go:
            Path(a.go).touch()
        try:
            code = proc.wait(timeout=max(1, deadline - time.time()))
        except subprocess.TimeoutExpired:
            proc.kill()
            code = -9
    else:
        before = snapshot(home)
        code = subprocess.call(cmd)
    time.sleep(1.0)  # let the unified log / file loggers flush
    result = diff(before, home, load_phrases(a.grep_fixture), a.own)
    result["commandExit"] = code
    result["pass"] = result["pass"] and code == 0
    write_out(result, a.out)
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
