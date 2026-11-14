"""M9.T06: soak / swap / crash-free tooling self-tests (tools/perf/soak-report.py, crashscan.py, crash-free.py,
soak-sampler.py). Run: tools/.venv/bin/python -I -m pytest tools/ci/tests/test_soak.py -q"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import time

from conftest import ROOT

PERF = ROOT / "tools/perf"
sys.path.insert(0, str(PERF))
import crashscan  # noqa: E402


def _mod(name, file):
    spec = importlib.util.spec_from_file_location(name, PERF / file)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


report = _mod("soak_report", "soak-report.py")
crashfree = _mod("crash_free", "crash-free.py")


def _ips(path, header, body):
    path.write_text(json.dumps(header) + "\n" + json.dumps(body))
    return path


def _loop(t, loop, v):
    return {"kind": "loop", "t": t, "loop": loop, "footprint_plus_metal": v, "footprint_total": v * 0.9}


def test_growth_same_phase_hour_medians():
    # loop 1 (warm-up) is ignored; hour 1 median 10 GB, hour 8 median 10.5 GB → 5 %
    s = [_loop(30, 1, 2e9)] + [_loop(600 * i, i + 1, 10e9) for i in range(1, 6)]
    s += [_loop(7 * 3600 + 600 * i, 50 + i, 10.5e9) for i in range(5)]
    g = report.growth(s, "footprint_plus_metal", 0.0)
    assert g["hour_first"] == 1 and g["hour_last"] == 8
    assert abs(g["growth"] - 0.05) < 1e-9


def test_growth_short_run_first_vs_last():
    s = [_loop(60, 2, 10e9), _loop(600, 3, 12e9)]
    g = report.growth(s, "footprint_plus_metal", 0.0)
    assert abs(g["growth"] - 0.2) < 1e-9 and "first vs last" in g["method"]


def test_crashscan_matches_only_our_pids_and_bundle(tmp_path):
    now = time.time()
    ts = time.strftime("%Y-%m-%d %H:%M:%S.00 %z", time.localtime(now))
    _ips(tmp_path / "AntiChat-1.ips", {"bug_type": "309", "app_name": "AntiChat", "timestamp": ts},
         {"pid": 111, "procPath": "/x/other/AntiChat.app/Contents/MacOS/AntiChat"})
    _ips(tmp_path / "llama-server-2.ips", {"bug_type": "309", "name": "llama-server", "timestamp": ts},
         {"pid": 222, "procPath": "/soak/AntiChat.app/Contents/Helpers/llama-server"})
    _ips(tmp_path / "JetsamEvent-3.ips", {"bug_type": "298", "timestamp": ts},
         {"processes": [{"pid": 333, "name": "AntiChatEngine", "reason": "per-process-limit"}, {"pid": 111, "name": "AntiChat"}]})
    reps = crashscan.reports(now - 120, [str(tmp_path)])
    ours = [r for r in crashscan.crashes(reps) if crashscan.is_ours(r, {333}, "/soak/AntiChat.app")]
    assert [r["pid"] for r in ours] == [222]  # the other AntiChat (pid 111, another bundle) is not ours
    assert [k["pid"] for k in crashscan.jetsam_kills(reps, {333})] == [333]
    assert crashscan.jetsam_kills(reps, {111}) == []  # listed but not killed (no reason)


def _run_dir(tmp_path, *, exit_code=0, hangs=(), completed=True):
    run = tmp_path / "run"
    (run / "probe").mkdir(parents=True)
    (run / "sampler").mkdir()
    (run / "run.json").write_text(json.dumps({"start_epoch": time.time() + 3600, "bundle": "/soak/AntiChat.app", "app_pid": 9,
                                              "exit_code": exit_code, "hours": 8, "tier": "T1", "dry": False}))
    (run / "probe/setup.json").write_text(json.dumps({"setupS": 100, "budgetB": 9_500_000_000}))
    rows = [_loop(100 + 600 * i, i + 2, 10e9) for i in range(6)] + [_loop(100 + 7 * 3600 + 600 * i, 60 + i, 10.4e9) for i in range(5)]
    (run / "probe/samples.jsonl").write_text("\n".join(json.dumps(r | {"app_pid": 9, "helper_pid": 10}) for r in rows))
    (run / "probe/hangs.jsonl").write_text("\n".join(json.dumps({"seconds": h, "phase": "chat", "where": "AntiChat  f() + 4"} if h >= 1
                                                             else {"seconds": h}) for h in hangs))
    if completed:
        (run / "probe/result.json").write_text(json.dumps({"completed": True, "loops": 60, "counts": {"chat": 60}, "failures": {}}))
    (run / "sampler/sampler.json").write_text(json.dumps({"peak_engine_bytes": 9.1e9, "pids": {"9": {}, "10": {}}}))
    (run / "sampler/sampler.csv").write_text("t_s,app,helper,children,engine,other,total\n0.0,1,2,3,5,0,6\n")
    return run


def _report(run, tmp_path):
    out = tmp_path / "out.json"
    p = subprocess.run([sys.executable, "-I", str(PERF / "soak-report.py"), "--run", str(run), "--out", str(out), "--no-log"],
                       capture_output=True, text=True)
    return p.returncode, json.loads(out.read_text()), p.stdout


def test_report_pass(tmp_path):
    rc, r, out = _report(_run_dir(tmp_path, hangs=(0.4,)), tmp_path)
    assert rc == 0 and r["pass"] and r["checks"]["growth_le_10pct"], out
    assert abs(r["growth"]["growth"] - 0.04) < 1e-9
    assert r["peak_engine"]["bytes"] == 9.1e9


def test_report_fails_on_long_hang_and_crash(tmp_path):
    rc, r, _ = _report(_run_dir(tmp_path, hangs=(2.5,), exit_code=134, completed=False), tmp_path)
    assert rc == 1 and not r["pass"]
    assert not r["checks"]["zero_hangs_over_2s"] and not r["checks"]["zero_crashes"]
    assert r["hangs"]["over_1s_by_phase"] == {"chat": 1} and r["hangs"]["over_1s_where"] == [["AntiChat  f() + 4", 1]]


def test_crash_free_counts_ledger_and_attributes_helper_crash(tmp_path):
    t0 = time.time() - 600
    ledger = tmp_path / "sessions.jsonl"
    lines = []
    for pid in range(1000, 1400):  # 400 sessions, all ended normally
        lines += [{"event": "start", "pid": pid, "t": t0 + 1, "bundle": f"/b{pid}/AntiChat.app", "kind": "app"},
                  {"event": "end", "pid": pid, "t": t0 + 2}]
    lines.append({"event": "start", "pid": 1400, "t": t0 + 1, "bundle": "/soak/AntiChat.app", "kind": "SoakProbe"})
    ledger.write_text("\n".join(json.dumps(x) for x in lines))
    reps = tmp_path / "reports"
    reps.mkdir()
    ts = time.strftime("%Y-%m-%d %H:%M:%S.00 %z", time.localtime(t0 + 5))
    _ips(reps / "sd-server-1.ips", {"bug_type": "309", "name": "sd-server", "timestamp": ts},
         {"pid": 5555, "procPath": "/soak/AntiChat.app/Contents/Helpers/sd-server"})
    out = tmp_path / "s1.json"
    since = time.strftime("%Y-%m-%dT%H:%M", time.localtime(t0 - 60))
    p = subprocess.run([sys.executable, "-I", str(PERF / "crash-free.py"), "--since", since, "--ledger", str(ledger),
                        "--reports-dir", str(reps), "--metrickit-glob", str(tmp_path / "none-*.json"), "--out", str(out),
                        "--allow-unverified"], capture_output=True, text=True)
    r = json.loads(out.read_text())
    assert r["sessions"] == 401 and r["crashed_sessions"] == 1, p.stdout
    assert r["crashes"][0]["session"] == 1400  # the helper-side crash belongs to the soak session
    assert r["pass"] and p.returncode == 0  # 400/401 = 99.75 %


def test_sampler_tracks_bundle_processes(tmp_path):
    # Our own python interpreter stands in for the app: the bundle = its install prefix.
    exe = os.path.realpath(sys.executable)
    out = tmp_path / "s"
    p = subprocess.Popen([sys.executable, "-I", str(PERF / "soak-sampler.py"), "--bundle", os.path.dirname(exe),
                          "--app-pid", str(os.getpid()), "--out", str(out), "--interval", "0.2", "--scan", "0.5"])
    time.sleep(1.5)
    p.terminate()
    p.wait(timeout=10)
    d = json.loads((out / "sampler.json").read_text())
    assert d["samples"] >= 3 and d["peak_app_bytes"] > 0
    assert str(os.getpid()) in d["pids"]
