"""M1.T26a: perf tooling self-tests (tools/perf). Run: tools/.venv/bin/python -I -m pytest tools/ci/tests -q"""
from __future__ import annotations

import importlib.util
import json
import multiprocessing as mp
import os
import subprocess
import sys

import pytest
from conftest import ROOT

PERF = ROOT / "tools/perf"
sys.path.insert(0, str(PERF))
import reportio  # noqa: E402
import load as loadmod  # noqa: E402


def _mod(name, file):
    spec = importlib.util.spec_from_file_location(name, PERF / file)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


gen_targets = _mod("gen_targets", "gen-targets.py")
run_mod = _mod("perf_run", "run.py")
compare_mod = _mod("perf_compare", "compare.py")


def _run(args, tmp_path, **env):
    e = dict(os.environ, ANTICHAT_PERF_RUNS_DIR=str(tmp_path / "runs"), **env)
    return subprocess.run([sys.executable, "-I", str(PERF / "run.py"), *args], capture_output=True, text=True, env=e, cwd=ROOT)


# ---- reportio: CR-T-12 (append-only unless --replace) and CR-T-13 (temp + rename, locked)

def test_put_legacy_is_append_only(tmp_path):
    d = {"m0.C1.T1.x": {"p50": 1}}
    assert not reportio.put_legacy(d, "m0.C1.T1.x", {"p50": 2}, replace=False, log=lambda *_: None)
    assert d["m0.C1.T1.x"]["p50"] == 1
    assert reportio.put_legacy(d, "m0.C1.T1.x", {"p50": 2}, replace=True, log=lambda *_: None)
    assert d["m0.C1.T1.x"]["p50"] == 2


def test_save_is_atomic_and_leaves_no_temp(tmp_path):
    p = tmp_path / "report.json"
    reportio.save(str(p), {"a": 1})
    reportio.save(str(p), {"a": 2})
    assert json.loads(p.read_text()) == {"a": 2}
    assert [x.name for x in tmp_path.iterdir()] == ["report.json"]


def _writer(path, prefix, n):
    for i in range(n):
        with reportio.locked(path) as d:
            reportio.put_legacy(d, f"{prefix}.{i}", {"p50": i}, replace=False, log=lambda *_: None)


def test_concurrent_writers_keep_every_key(tmp_path):
    path = str(tmp_path / "report.json")
    ps = [mp.get_context("spawn").Process(target=_writer, args=(path, p, 15)) for p in ("a", "b", "c")]
    for p in ps:
        p.start()
    for p in ps:
        p.join(60)
    assert len(json.load(open(path))) == 45


def test_report_py_merge_does_not_overwrite_and_show_skips_reserved(tmp_path):
    out, src = tmp_path / "r.json", tmp_path / "s.json"
    reportio.save(str(out), {"m0.C1.T1.m": {"p50": 1, "p95": 1, "n": 1, "unit": "s", "target": 1.5, "label": "measured"},
                             "metrics": {"U2": {"T1": {"p50": 3}}}, "schema": reportio.SCHEMA_ID})
    reportio.save(str(src), {"m0.C1.T1.m": {"p50": 9, "p95": 9, "n": 1, "unit": "s", "target": 1.5, "label": "measured"},
                             "metrics": {"U2": {"T1": {"p50": 4}, "T0": {"p50": 5}}}})
    rp = PERF / "report.py"
    subprocess.run([sys.executable, "-I", str(rp), "merge", "--from", str(src), "--out", str(out)], check=True, capture_output=True)
    d = json.loads(out.read_text())
    assert d["m0.C1.T1.m"]["p50"] == 1 and d["metrics"]["U2"]["T1"]["p50"] == 3 and d["metrics"]["U2"]["T0"]["p50"] == 5
    show = subprocess.run([sys.executable, "-I", str(rp), "show", "--out", str(out)], check=True, capture_output=True, text=True)
    assert "m0.C1.T1.m" in show.stdout and "metrics" not in show.stdout


# ---- gen-targets: numbers come from nfr.md; drift fails loudly

def test_targets_are_current_and_parsed_from_nfr():
    p = subprocess.run([sys.executable, "-I", str(PERF / "gen-targets.py"), "--check"], capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    t = json.load(open(PERF / "nfr_targets.json"))["metrics"]
    for m in ("U1", "U2", "U4", "U5", "U6", "U7", "U8", "U10", "U11", "C1", "C1b", "C2", "C3", "C4", "C5", "C6", "S2", "S4",
              "R3", "B1", "sidebarUpdate", "composerDock"):
        assert m in t, m
    assert {c["stat"] for c in t["U2"]["tiers"]["default"]} == {"p99", "p50"}
    assert t["C3"]["tiers"]["T1"][0]["value"] == round(t["C2"]["tiers"]["T1"][0]["value"] * 0.6, 3)
    assert t["U1"]["star"] and not t["U6"]["star"]


def test_gen_targets_fails_on_drift():
    nfr = open(ROOT / "docs/research/02-target/nfr.md").read().replace("**p99 < 100 ms**", "p99 well under a tenth of a second")
    try:
        gen_targets.build(nfr, open(ROOT / "docs/research/02-target/hardware-tiers.md").read(), open(ROOT / "docs/prd/M1.md").read())
    except gen_targets.Drift as e:
        assert "U2" in str(e)
    else:
        raise AssertionError("drift not detected")


# ---- run.py: targets, schema, load gate

def _log(tmp_path, name, ms_values):
    p = tmp_path / "perf.jsonl"
    with open(p, "w") as f:
        for v in ms_values:
            f.write(json.dumps({"name": name, "kind": "interval", "dur_ns": int(v * 1e6), "end_ns": 1, "pid": 1, "proc": "AntiChat"}) + "\n")
        f.write("not json\n")
    return p


def test_from_log_ingest_passes_and_fails_against_nfr(tmp_path):
    out = tmp_path / "report.json"
    log = _log(tmp_path, "sendAck", [8.0] * 99 + [40.0])
    p = _run(["--metric", "U2", "--tier", "T1", "--from-log", str(log), "--out", str(out)], tmp_path)
    assert p.returncode == 0, p.stdout + p.stderr
    e = json.loads(out.read_text())["metrics"]["U2"]["T1"]
    assert e["pass"] is True and e["n"] == 100 and e["unit"] == "ms" and e["valid"] is True
    assert {c["stat"]: c["ok"] for c in e["target"]} == {"p99": True, "p50": True}
    log = _log(tmp_path, "sendAck", [20.0] * 50)  # p50 20 ms > one 60 Hz frame
    p = _run(["--metric", "U2", "--tier", "T0", "--from-log", str(log), "--out", str(out)], tmp_path)
    assert p.returncode == 1
    d = json.loads(out.read_text())
    assert d["metrics"]["U2"]["T0"]["pass"] is False
    assert run_mod.validate_report(d) == []


def test_busy_machine_is_refused_then_flagged(tmp_path):
    out = tmp_path / "selftest.json"
    busy = {"ANTICHAT_PERF_MAX_OTHER_CORES": "-1"}  # every sample is "busy"
    p = _run(["--metric", "SELFTEST", "--runs", "3", "--out", str(out)], tmp_path, **busy)
    assert p.returncode == 3 and "refused" in p.stderr and not out.exists()
    recs = list((tmp_path / "runs").iterdir())
    assert json.loads(recs[0].read_text())["result"] == "refused"
    p = _run(["--metric", "SELFTEST", "--runs", "3", "--out", str(out)], tmp_path, ALLOW_NOISY="1", **busy)
    assert p.returncode == 0, p.stderr
    e = json.loads(out.read_text())["metrics"]["SELFTEST"]["na"]
    assert e["quality"] == "noisy" and e["valid"] is False and e["load"]["allowed_noisy"] is True
    assert e["load"]["before"]["ncpu"] and "other_cores" in e["load"]["before"]


def test_noisy_run_never_replaces_a_clean_entry(tmp_path):
    out = tmp_path / "r.json"
    # A clean machine includes AC power (load.py reads `pmset -g batt`): a pmset on PATH that reports AC, so the clean
    # leg does not depend on whether this Mac is plugged in (q65: run on battery → refused).
    fake = tmp_path / "bin"
    fake.mkdir()
    (fake / "pmset").write_text('#!/bin/sh\nif [ "$2" = batt ]; then echo "Now drawing from \'AC Power\'"; exit 0; fi\n'
                                'exec /usr/bin/pmset "$@"\n')
    (fake / "pmset").chmod(0o755)
    quiet = {"ANTICHAT_PERF_MAX_OTHER_CORES": "1000", "ANTICHAT_PERF_MAX_LOAD1_PER_CPU": "1000", "ANTICHAT_PERF_ALLOW_LOW_POWER": "1",
             "PATH": f"{fake}:{os.environ.get('PATH', '')}"}
    p = _run(["--metric", "SELFTEST", "--runs", "2", "--out", str(out)], tmp_path, **quiet)
    assert p.returncode == 0, p.stderr
    clean = json.loads(out.read_text())["metrics"]["SELFTEST"]["na"]
    assert clean["valid"] is True
    p = _run(["--metric", "SELFTEST", "--runs", "2", "--out", str(out), "--replace", "--allow-noisy"], tmp_path,
             ANTICHAT_PERF_MAX_OTHER_CORES="-1")
    assert p.returncode == 0 and "never replaces" in p.stdout, p.stdout + p.stderr
    assert json.loads(out.read_text())["metrics"]["SELFTEST"]["na"]["p50"] == clean["p50"]


def test_forward_metric_exits_2_and_names_owner(tmp_path):
    p = _run(["--metric", "R3", "--tier", "na"], tmp_path)
    assert p.returncode == 2 and "T26b" in p.stderr


def test_checks_resolve_tier_family_and_speed_class():
    t = json.load(open(PERF / "nfr_targets.json"))
    m = {"speed_class": "S4"}
    assert run_mod.checks_for(t["metrics"]["C1"], "T3-48", None, m)[0]["value"] == t["metrics"]["C1"]["tiers"]["T3"][0]["value"]
    assert run_mod.checks_for(t["metrics"]["U1"], "na", None, m) == t["metrics"]["U1"]["tiers"]["S2+"]
    assert run_mod.checks_for(t["metrics"]["U1"], "na", None, {"speed_class": "S1"}) == t["metrics"]["U1"]["tiers"]["S1"]
    assert run_mod.speed_class("M5 Max", t) == "S4" and run_mod.speed_class("M1", t) == "S1"


# ---- compare.py

def _entry(v, valid=True, model=None):
    return {"p50": v, "p95": v, "p99": v, "unit": "ms", "valid": valid, "model": model}


def test_compare_severity_and_noisy_exclusion():
    t = json.load(open(PERF / "nfr_targets.json"))["metrics"]
    base = {"metrics": {"U2": {"T1": _entry(10)}, "U6": {"T1": _entry(100)}, "U10": {"na": _entry(100)},
                        "C2": {"T1": dict(_entry(100), model="chat-9b-q4")}}}
    cur = {"metrics": {"U2": {"T1": _entry(13)}, "U6": {"T1": _entry(106)}, "U10": {"na": _entry(300, valid=False)},
                       "C2": {"T1": dict(_entry(70), model="chat-9b-q4")}}}
    rows = {(r["metric"], r["tier"]): r for r in compare_mod.compare(cur, base, t)}
    assert rows[("U2", "T1")]["severity"] == "S1"           # ★, +30 % on p99
    assert rows[("U6", "T1")]["severity"] == "S2"           # +6 %
    assert rows[("U10", "na")]["severity"] is None and "noisy" in rows[("U10", "na")]["status"]
    assert rows[("C2", "T1")]["severity"] == "S1"           # higher is better: −30 % decode on ★ C2


def test_compare_maps_legacy_m0_keys_by_model():
    t = json.load(open(PERF / "nfr_targets.json"))["metrics"]
    base = {"m0.C1.T1.chat-9b-q4": {"p50": 1.0, "p95": 1.0}, "m0.C1.T1.chat-0.8b": {"p50": 0.1, "p95": 0.1}}
    cur = {"metrics": {"C1": {"T1": {"p50": 1.02, "valid": True, "model": "chat-9b-q4"}}}}
    rows = compare_mod.compare(cur, base, t)
    assert len(rows) == 1 and rows[0]["model"] == "chat-9b-q4" and rows[0]["status"] == "ok"


# ---- load.py parsers

def test_load_parsers():
    top = ("Processes: 1\nCPU usage: 50.0% user, 10.0% sys, 40.0% idle\n\nPID COMMAND %CPU\n1 x 1.0\n"
           "Processes: 2\nCPU usage: 5.0% user, 3.0% sys, 92.0% idle\n\nPID    COMMAND          %CPU \n344    fseventsd        103.0\n20718  clang  32.9\n")
    t = loadmod.parse_top(top)
    assert t["cpu_busy_pct"] == 8.0 and [p["command"] for p in t["top"]] == ["fseventsd", "clang"]
    assert loadmod.parse_gpu('"Device Utilization %"=7,"x"=1 "Device Utilization %"=12') == 12.0
    assert loadmod.parse_batt("Now drawing from 'AC Power'\n -InternalBattery") is True
    assert loadmod.parse_batt("Now drawing from 'Battery Power'\n") is False
    assert loadmod.parse_therm("Note: No thermal warning level has been recorded") == "nominal"
    assert loadmod.parse_therm("CPU_Speed_Limit = 70") == "speed_limit_70"
    v = loadmod.verdict([{"other_cores": 3.0, "load1": 1, "ncpu": 18, "ac_power": False}], gpu=False)
    assert v["quality"] == "noisy" and len(v["reasons"]) == 2


def test_legacy_writers_import_and_keep_keys_without_replace(tmp_path):
    rep = tmp_path / "report.json"
    reportio.save(str(rep), {"m0.C2.T1.chat-9b-q4": {"p50": 100.0, "p95": 101.0, "min": 99.0, "max": 102.0, "n": 20,
                                                     "unit": "tok/s", "target": 15, "label": "measured"},
                             "metrics": {"U2": {"T1": {"p50": 1}}}})
    for script in ("scale.py", "sd-scale.py", "vid-scale.py"):
        extra = [] if script == "scale.py" else ["--raw-dir", str(tmp_path)]
        p = subprocess.run([sys.executable, "-I", str(PERF / script), "--report", str(rep), *extra], capture_output=True, text=True)
        assert p.returncode == 0, script + p.stderr
    d = json.loads(rep.read_text())
    assert "m0.C2.T1.chat-9b-q4@M4" in d and d["metrics"] == {"U2": {"T1": {"p50": 1}}}
    d["m0.C2.T1.chat-9b-q4@M4"]["p50"] = -1
    reportio.save(str(rep), d)
    subprocess.run([sys.executable, "-I", str(PERF / "scale.py"), "--report", str(rep)], check=True, capture_output=True)
    assert json.loads(rep.read_text())["m0.C2.T1.chat-9b-q4@M4"]["p50"] == -1  # CR-T-12: kept without --replace
    subprocess.run([sys.executable, "-I", str(PERF / "scale.py"), "--report", str(rep), "--replace"], check=True, capture_output=True)
    assert json.loads(rep.read_text())["m0.C2.T1.chat-9b-q4@M4"]["p50"] > 0


def test_gpu_lock_probe_skipped_under_gpu_run_timing(monkeypatch, tmp_path):
    """M9.T05 (lead): gpu-run.sh timing holds /tmp/antichat-gpu.lock itself and exports ANTICHAT_GPU_LOCK_HELD=timing;
    load.py must not count its own wrapper's lock as another job, but still sees a lock held without the variable."""
    lock = tmp_path / "gpu.lock"
    lock.write_text("")
    monkeypatch.setattr(loadmod, "GPU_LOCK", str(lock))
    holder = subprocess.Popen(["lockf", "-k", str(lock), "sleep", "5"])
    try:
        import time
        for _ in range(50):
            if loadmod.gpu_lock_held():
                break
            time.sleep(0.05)
        monkeypatch.delenv("ANTICHAT_GPU_LOCK_HELD", raising=False)
        assert loadmod.gpu_lock_held() is True
        monkeypatch.setenv("ANTICHAT_GPU_LOCK_HELD", "timing")
        assert loadmod.gpu_lock_held() is False
        monkeypatch.setenv("ANTICHAT_GPU_LOCK_HELD", "shared")
        assert loadmod.gpu_lock_held() is True
    finally:
        holder.kill()
        holder.wait()


def test_low_power_mode_is_noisy():
    """M9.T05 prep: Low Power Mode (pmset powermode 1) throttles CPU/GPU, also on AC: every sample records it and the
    verdict calls the run noisy."""
    assert loadmod.parse_power_mode(" lowpowermode         0\n powermode            1\n") in (0, 1)
    assert loadmod.parse_power_mode("System-wide power settings:\n powermode            1\n") == 1
    assert loadmod.parse_power_mode(" powermode            0\n") == 0
    assert loadmod.parse_power_mode("sleep 1\n") is None
    base = {"other_cores": 0.0, "load1": 1, "ncpu": 18, "ac_power": True, "thermal": "nominal"}
    v = loadmod.verdict([dict(base, power_mode=1)], gpu=False, thresholds={"allow_low_power": False})
    assert v["quality"] == "noisy" and any("low power mode" in r for r in v["reasons"])
    assert loadmod.verdict([dict(base, power_mode=0)], gpu=False)["quality"] == "clean"
    assert loadmod.summarize([dict(base, power_mode=0), dict(base, power_mode=1)])["power_mode"] == 1


def test_gpu_prefix_modes(monkeypatch):
    """M9.T05 prep: GPU probes go through gpu-run.sh in ANTICHAT_GPU_MODE; inside gpu-run timing no second lock."""
    monkeypatch.setattr(run_mod, "GPU_RUN", "/bin/echo")  # executable stand-in
    monkeypatch.delenv("ANTICHAT_GPU_LOCK_HELD", raising=False)
    monkeypatch.delenv("ANTICHAT_GPU_MODE", raising=False)
    assert run_mod.gpu_prefix() == ["/bin/echo", "timing", "--"]
    monkeypatch.setenv("ANTICHAT_GPU_MODE", "shared")
    assert run_mod.gpu_prefix() == ["/bin/echo", "shared", "--"]
    monkeypatch.setenv("ANTICHAT_GPU_LOCK_HELD", "timing")
    assert run_mod.gpu_prefix() == []


def test_b1_top_parser():
    out = "PID    POWER\n101    3.0\n102    0.5\nPID    POWER\n101    0.4\n102    0.1\nPID    POWER\n101    0.2\n"
    assert run_mod.b1_parse_top(out) == [0.5, 0.2]


def test_t05_plan_is_complete():
    """Every step has a command or a stated owner/blocked reason; ids are unique; deferred items are in the plan."""
    t05 = _mod("perf_t05", "t05.py")
    plan = t05.steps()
    ids = [s.id for s in plan]
    assert len(ids) == len(set(ids))
    for s in plan:
        assert (s.real and s.dry) or (s.status in ("owner", "blocked") and s.why), s.id
    for must in ("chat.C1.T1", "chat.U3.T1", "ui.U1", "voice.V1.T1", "photo.handoff.T1", "video.T4", "video.VID3.i2v",
                 "search.e2e.T1", "m5.50mbps", "m5.10mbps", "pr1.tcpdump", "d3.real", "csc.F7", "csc.body-age", "r1.soak.T1"):
        assert must in ids, must


def test_t05_drivers_cover_every_nfr_step():
    """M9.T05 drivers: no step is blocked for want of a driver except B3 (no way to force .serious); the XCUITest
    legs, IMAGE_TURN_OVERHEAD, F7_VIDEO, V8/V11 per tier, R1 at T3 and M5 10 Mbps x 20 are planned with commands."""
    t05 = _mod("perf_t05", "t05.py")
    plan = {s.id: s for s in t05.steps()}
    assert [i for i, s in plan.items() if s.status == "blocked"] == ["video.B3"]
    assert [i for i, s in plan.items() if s.status == "owner"] == ["pr1.tcpdump"]
    for must in ("ui.U2-U6-U10-U11", "photo.P3", "video.B5", "pr1.capture", "photo.IMAGE_TURN_OVERHEAD", "video.F7_VIDEO.T4",
                 "video.F7_VIDEO.T3", "voice.V8.T0", "voice.V8.T1", "voice.V8.T3", "voice.V11.T0", "voice.V11.T1",
                 "voice.V11.T3", "r1.soak.T3-48"):
        assert must in plan and plan[must].real and not plan[must].status, must
    assert "--runs 20" in plan["m5.10mbps"].real
    assert "PR1JourneyLoopTests" in plan["pr1.capture"].real
    for t in ("T0", "T3"):  # each tier runs its own capped bench (not the T1 number filed again)
        assert f"--metric V8 --tier {t}" in plan[f"voice.V8.{t}"].real and f"--metric V11 --tier {t}" in plan[f"voice.V11.{t}"].real


def test_image_turn_pairs_and_video_gate_rows(tmp_path):
    log = tmp_path / "perf.jsonl"
    rows = [{"name": "imageGen", "kind": "interval", "dur_ns": 5e9, "end_ns": 100, "meta": {"source": "queue"}},
            {"name": "imageGen", "kind": "interval", "dur_ns": 9e9, "end_ns": 120},  # a helper-side record: ignored
            {"name": "imageTurn", "kind": "interval", "dur_ns": 6.5e9, "end_ns": 150},
            {"name": "imageGen", "kind": "interval", "dur_ns": 3e9, "end_ns": 200, "meta": {"source": "queue"}},
            {"name": "imageTurn", "kind": "interval", "dur_ns": 4.0e9, "end_ns": 250}]
    log.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
    assert run_mod.image_turn_pairs(str(log)) == ([6.5, 4.0], [5.0, 3.0])
    gate = {"action": "videoGate", "gate_s": "3.0", "preview_s": "1.0", "final_s": "2.0", "final_wall_s": "12.0",
            "preview_checks": "6", "streamed": "1"}
    s, notes = run_mod.video_rows_gate([{"run": 0, "status": "completed", "final_s": 60.0, "notes": [gate]},
                                        {"run": 1, "status": "blocked", "final_s": 30.0, "notes": []}])
    assert s[None] == [5.0] and s["previews"] == [100 / 60] and s["final_wall"] == [20.0]
    assert any("not counted" in n for n in notes)
    assert not any("previews shown" in n for n in notes), "rows from older apps carry no preview note"
    # fix/t05-video-t4 (VID2): the first allowed preview that reached the app, against the clip.
    _, notes = run_mod.video_rows_gate([{"run": 0, "status": "completed", "final_s": 70.0, "first_preview_s": 45.0,
                                         "first_preview_step": 2, "preview_events": 16,
                                         "notes": [dict(gate, preview_shown="16")]}])
    assert "previews shown 16 (app events 16), first 45.0 s (step 2), 25.0 s before the video" in notes[0]
    _, notes = run_mod.video_rows_gate([{"run": 0, "status": "completed", "final_s": 70.0, "first_preview_s": -1,
                                         "preview_events": 0, "notes": [dict(gate, preview_shown="0")]}])
    assert notes[0].endswith("previews shown 0 (app events 0), first none")
    # fix/t05-video: a T3/T4 row taken under the low-tier rule (no preload, no streamed check) is refused.
    assert "low_tier=False" in run_mod.video_tier_rule([{"run": 0, "low_tier": False}], "T3")[0]
    assert run_mod.video_tier_rule([{"run": 0, "low_tier": True}], "T2-24")
    with pytest.raises(RuntimeError, match="low_tier"):
        run_mod.video_tier_rule([{"run": 0, "low_tier": False}, {"run": 1, "low_tier": True}], "T3")
    with pytest.raises(RuntimeError):
        run_mod.video_tier_rule([{"run": 0, "low_tier": False}], "T1")
    assert "older" in run_mod.video_tier_rule([{"run": 0}], "T4")[0]


# ---- fix/t05-video (AT-290): the speed-table driver requests each preset explicitly and refuses rows that ran
# something else (the LTX preset ran vid-5b at 832x480 from `--res ltx`)

video_speed = _mod("video_speed", "video-speed.py")


def test_video_speed_presets_are_requested_explicitly():
    class A:
        bin, runtime, runs, init_image = "/app", "/rt", 3, "/img.jpg"
    for p in video_speed.PRESETS:
        cmd = video_speed.bench_cmd(A, p, "/raw.jsonl")
        assert "--res" not in cmd
        for flag, val in (("--model", p["model"]), ("--width", str(p["width"])), ("--height", str(p["height"])),
                          ("--frames", str(p["frames"])), ("--mode", p["mode"])):
            assert cmd[cmd.index(flag) + 1] == val, (p["key"], flag)
    ltx = next(p for p in video_speed.PRESETS if p["key"] == "t2v-ltx-512p-short")
    cmd = video_speed.bench_cmd(A, ltx, "/raw.jsonl")
    assert cmd[cmd.index("--model") + 1] == "vid-ltx" and cmd[cmd.index("--width") + 1] == "768"


def test_video_speed_refuses_rows_that_ran_another_model_or_size():
    ltx = next(p for p in video_speed.PRESETS if p["key"] == "t2v-ltx-512p-short")
    # The T05 row: asked for LTX, ran vid-5b at 832x480.
    t05 = {"run": 0, "status": "completed", "model": "", "model_dir": "/M/vid-5b", "meta_model": "vid-5b",
           "meta_width": "832", "meta_height": "480", "meta_frames": "97", "frames": 97, "width": 832, "height": 480}
    bad = video_speed.mismatches(ltx, [t05], strict=True)
    assert any("model 'vid-5b'" in b for b in bad) and any("width 832" in b for b in bad)
    with pytest.raises(SystemExit) as e:
        video_speed.check_rows(ltx, "video-speed-t2v-ltx-512p-short", [t05], strict=True)
    assert e.value.code == 3
    good = dict(t05, model_key="vid-ltx", meta_model="vid-ltx", meta_width="768", meta_height="512", width=768, height=512)
    assert video_speed.mismatches(ltx, [good], strict=True) == []
    # strict: a row that does not say its model fails; an older (M0) row may lack it
    anon = {"run": 0, "width": 768, "height": 512, "frames": 97}
    assert video_speed.mismatches(ltx, [anon], strict=True) and not video_speed.mismatches(ltx, [anon], strict=False)


def test_video_speed_ltx_generate_stage_stands_in_for_denoise():
    ltx = next(p for p in video_speed.PRESETS if p["key"] == "t2v-ltx-512p-short")
    r = {"run": 0, "status": "completed", "final_s": 160.0, "first_step_s": 5.0, "h_child_generate_s": 140.0,
         "h_child_decode_s": 10.0, "h_child_denoise_peak_gib": 14.6, "h_child_decode_peak_gib": 24.9}
    row = video_speed.s4_row(ltx, [r])
    assert row["note"] == ltx["note"] and row["t_step_s"] == round(140.0 / 11, 4) and row["encode_s"] == 10.0
    assert row["decode_s_per_frame"] == round(10.0 / 97, 5)


# ---- M9.T05: a measurement counts only from a confirmed perf build (make build-perf); Debug never does

def _fake_app(tmp_path, *, debug_dylib=False, marker=False, info=None):
    macos = tmp_path / "AntiChat.app/Contents/MacOS"
    macos.mkdir(parents=True)
    exe = macos / "AntiChat"
    body = "#!/bin/sh\n" + (f"echo '{json.dumps(info)}'\n" if info is not None else "exit 1\n")
    if marker:
        body += "# " + run_mod.PERF_MARKER.decode() + "\n"
    exe.write_text(body)
    exe.chmod(0o755)
    if debug_dylib:
        (macos / "AntiChat.debug.dylib").write_bytes(b"\0")
    return str(tmp_path / "AntiChat.app")


def test_debug_build_is_never_valid(tmp_path):
    b = run_mod.app_build(_fake_app(tmp_path, debug_dylib=True, marker=True,
                                    info={"debug": False, "perf_harness": True, "optimized": True}))
    assert b["config"] == "Debug" and run_mod.build_valid(b) is False


def test_confirmed_perf_build_is_valid(tmp_path):
    b = run_mod.app_build(_fake_app(tmp_path, marker=True, info={"debug": False, "perf_harness": True, "optimized": True}))
    assert b["config"] == "Perf" and run_mod.build_valid(b) is True


def test_perf_build_unoptimized_or_debug_or_silent_is_invalid(tmp_path):
    for i, info in enumerate([{"debug": False, "perf_harness": True, "optimized": False},
                              {"debug": True, "perf_harness": True, "optimized": True},
                              {"debug": False, "perf_harness": False, "optimized": True},
                              None]):
        b = run_mod.app_build(_fake_app(tmp_path / str(i), marker=True, info=info))
        assert run_mod.build_valid(b) is False, (info, b)
    # a record that claims Perf without a confirming buildinfo is not valid either
    assert run_mod.build_valid({"config": "Perf", "buildinfo": None}) is False


def test_plain_release_build_keeps_its_old_validity(tmp_path):
    b = run_mod.app_build(_fake_app(tmp_path))
    assert b["config"] == "Release" and "buildinfo" not in b and run_mod.build_valid(b) is True


def test_from_log_ingest_takes_the_validity_of_an_explicit_app(tmp_path):
    """M9.T05: XCUITest legs pass the app they drove; a Debug app's log is never valid, a confirmed perf build's is."""
    log = _log(tmp_path, "sendAck", [8.0] * 20)
    for name, kw, want in (("dbg", dict(debug_dylib=True), False),
                           ("perf", dict(marker=True, info={"debug": False, "perf_harness": True, "optimized": True}), True)):
        out = tmp_path / f"report-{name}.json"
        app = _fake_app(tmp_path / name, **kw)
        p = _run(["--metric", "U2", "--tier", "T1", "--app", app, "--from-log", str(log), "--out", str(out)], tmp_path)
        assert p.returncode == 0, p.stdout + p.stderr
        e = json.loads(out.read_text())["metrics"]["U2"]["T1"]
        assert e["valid"] is want, (name, e["build"])


# ---- M9.T05: NFR-V9 judges the A-M3-06 accepted languages at their accepted value, read from the amendment row

def test_v9_accepted_values_come_from_the_amendment():
    acc = run_mod.accepted_v9()
    assert acc == {"ar": 11.42, "zh": 10.6}, acc


def test_v9_accepted_parser_reads_only_the_a_m3_06_row(tmp_path):
    f = tmp_path / "amend.md"
    f.write_text("| A-M3-05 | x | accept the AT-284 / NFR-V9 misses for fr (9.0 %); |\n"
                 "| A-M3-06 | 2026-11-05 | M3.T05 | ... accept the AT-284 / NFR-V9 misses for ar (11.42 %) and zh (10.60 %); ... |\n")
    assert run_mod.accepted_v9(str(f)) == {"ar": 11.42, "zh": 10.6}
    assert run_mod.accepted_v9(str(tmp_path / "missing.md")) == {}


def _wer(tmp_path, rates):
    p = tmp_path / "wer.json"
    p.write_text(json.dumps({"scores": {"auto": {lang: {"rate": r / 100, "metric": "cer" if lang in ("ja", "zh") else "wer",
                                                       "n": 40, "engines": {}} for lang, r in rates.items()}}}))
    return p


def test_v9_passes_within_accepted_values_and_fails_above(tmp_path):
    base = {"en": 0.40, "de": 3.92, "ja": 4.92}
    for rates, want in (({**base, "ar": 10.18, "zh": 10.60}, True),   # T05 phase B: within A-M3-06
                        ({**base, "ar": 11.50, "zh": 10.60}, False),  # ar above its accepted value
                        ({**base, "de": 6.50, "ar": 10.0, "zh": 9.0}, False)):  # a non-accepted language above 6 %
        out = tmp_path / f"r-{len(str(rates))}-{want}.json"
        p = _run(["--metric", "V9", "--tier", "T1", "--out", str(out), "--runs", "1"], tmp_path, V9_WER=str(_wer(tmp_path, rates)))
        d = json.loads(out.read_text())["metrics"]["V9"]
        ok = all(e["pass"] for e in d.values())
        assert ok is want, (rates, {k: (e["pass"], e["target"]) for k, e in d.items()})
        assert p.returncode == (0 if want else 1), p.stdout + p.stderr
        assert set(d) == {"T1", "T1/ar", "T1/zh"}
