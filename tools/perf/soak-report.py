#!/usr/bin/env python3
"""M9.T06 AT-NFR-S3 verdict for one soak run (tools/perf/soak.sh). Stdlib; the plot uses Pillow when available
(tools/.venv), otherwise `memory.png` is skipped and the JSON says so.

  soak-report.py --run <build/soak/<stamp>> --out build/at/AT-NFR-S3/<date>.json [--png build/at/AT-NFR-S3/memory.png]

Inputs in the run dir: run.json (soak.sh: start epoch, bundle, app pid, exit code, hours, tier, dry), probe/ (the app's
SoakProbe: setup.json, samples.jsonl, events.jsonl, hangs.jsonl, saved.jsonl, result.json, metrickit/), sampler/
(soak-sampler.py: 1 s peaks + every pid seen), container/ (the dev container: antichat.sqlite, Diagnostics/).

Pass (docs/prd/M9.md §M9.T06 step 1):
  growth   (phys_footprint + Metal) at hour H vs hour 1, same loop phase (the `loop` samples, taken after 10 s idle at the
           start of every loop; loop 1 is the warm-up and is left out): median of hour H's samples vs median of hour
           1's, ≤ 10 %. phys_footprint alone is reported too (the PRD's fallback when the growth is OS file cache).
  crashes  0 .ips (bug_type 309) of the soak's own processes (pid seen by the sampler or executable inside the soak's
           app copy: AntiChat, AntiChatEngine, llama-server, sd-server), 0 MetricKit crash diagnostics, the app exited 0
           with result.json, no helper restart.
  hangs    0 main-thread stalls > 2 s (the probe's watchdog signposts + MetricKit hang diagnostics). Stalls ≥ 1 s are
           summarized by phase and by `where` (the probe's main-thread stack samples, probe/hang-stacks/).
  OOM      0 jetsam kills of the soak's pids (JetsamEvent .ips) and 0 kernel memorystatus kills naming them.
Also reported: the continuous peak phys_footprint of the engine helper + its children (1 s sampler: NFR-R1's quantity,
reusable by T05 r1.soak.T1 when the workload matches), swap-outs during the run, per-leg counts / failures, lost saved
messages after a crash (each `saved.jsonl` reply still in the database as `done`).
A run shorter than 2 h (`dry`) computes everything but is never a pass of the AT (`valid: false`).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sqlite3
import statistics
import subprocess
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import crashscan  # noqa: E402

GROWTH_MAX = 0.10
HANG_MAX_S = 2.0


def jsonl(path: str) -> list[dict]:
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        out.append(json.loads(line))
                    except ValueError:
                        pass
    except OSError:
        pass
    return out


def load(path: str, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def growth(samples: list[dict], key: str, soak_start: float) -> dict:
    """Same-phase growth: the `loop` samples (loop ≥ 2) bucketed by soak hour; last hour's median vs hour 1's."""
    rows = [s for s in samples if s.get("kind") == "loop" and s.get("loop", 0) >= 2 and key in s]
    if len(rows) < 2:
        return {"key": key, "n": len(rows), "growth": None, "note": "fewer than 2 loop samples"}
    hours: dict[int, list[float]] = {}
    for s in rows:
        h = int(max(0.0, s["t"] - soak_start) // 3600) + 1
        hours.setdefault(h, []).append(float(s[key]))
    first, last = min(hours), max(hours)
    if first == last:  # a short run: first vs last loop sample
        base, end = float(rows[0][key]), float(rows[-1][key])
        method = "first vs last loop sample (run < 1 h after warm-up)"
    else:
        base, end = statistics.median(hours[first]), statistics.median(hours[last])
        method = f"median of hour {last} vs hour {first} loop samples"
    return {"key": key, "n": len(rows), "hour_first": first, "hour_last": last, "base_bytes": base, "end_bytes": end,
            "growth": (end - base) / base if base else None, "method": method,
            "per_hour_median_bytes": {str(h): statistics.median(v) for h, v in sorted(hours.items())}}


def memorystatus_kills(start: str, pids: set[int]) -> tuple[list[str], str | None]:
    """Kernel memorystatus kill lines naming one of our pids (unified log; None error when it ran)."""
    try:
        out = subprocess.run(["log", "show", "--start", start, "--style", "compact", "--predicate",
                              'sender == "kernel" AND eventMessage CONTAINS "memorystatus"'],
                             capture_output=True, text=True, timeout=900).stdout
    except (OSError, subprocess.TimeoutExpired) as e:
        return [], f"log show: {e}"
    hits = []
    for line in out.splitlines():
        if "kill" not in line:
            continue
        if any(f"pid {p} " in line or f"pid {p}]" in line or f"[{p}]" in line for p in pids):
            hits.append(line.strip())
    return hits, None


def lost_saved(container: str, saved: list[dict]) -> dict:
    db = os.path.join(container, "antichat.sqlite")
    if not saved:
        return {"checked": 0, "lost": []}
    if not os.path.exists(db):
        return {"checked": 0, "lost": [], "error": f"no {db}"}
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        lost = []
        for s in saved:
            row = con.execute("SELECT status FROM message WHERE id = ?", (s["message"],)).fetchone()
            if not row or row[0] != "done":
                lost.append({"chat": s["chat"], "message": s["message"], "status": row[0] if row else None})
        con.close()
        return {"checked": len(saved), "lost": lost}
    except sqlite3.Error as e:
        return {"checked": 0, "lost": [], "error": str(e)}


def plot(png: str, sampler_csv: str, samples: list[dict], soak_start: float, title: str) -> str | None:
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return "Pillow not available (run with tools/.venv/bin/python)"
    pts_total, pts_engine = [], []
    try:
        with open(sampler_csv) as f:
            next(f)
            for i, line in enumerate(f):
                if i % 30:
                    continue  # 30 s resolution is plenty for an 8 h plot
                c = line.strip().split(",")
                t = (float(c[0])) / 3600
                pts_total.append((t, int(c[-1]) / 1e9))
                pts_engine.append((t, int(c[4]) / 1e9))
    except (OSError, StopIteration, ValueError, IndexError):
        pass
    # Both clocks start at the launch (the sampler's a moment before the probe's): plotted on one axis since launch.
    loops = [(s["t"] / 3600, s["footprint_plus_metal"] / 1e9) for s in samples
             if s.get("kind") == "loop" and "footprint_plus_metal" in s]
    series = [("App + engine footprint (1 s)", "#2a78d6", pts_total), ("Engine helper + children (1 s)", "#eb6834", pts_engine),
              ("Footprint + Metal at loop start", "#1baf7a", loops)]
    allp = [p for _, _, s in series for p in s]
    if not allp:
        return "no data to plot"
    W, H, L, R, T, B = 1200, 640, 90, 30, 70, 110
    xmax = max(1.0, max(p[0] for p in allp))
    ymax = max(1.0, max(p[1] for p in allp) * 1.1)
    img = Image.new("RGB", (W, H), "#fcfcfb")
    d = ImageDraw.Draw(img)
    X = lambda x: L + (W - L - R) * x / xmax  # noqa: E731
    Y = lambda y: H - B - (H - T - B) * y / ymax  # noqa: E731
    step = max(1, int(ymax / 6) or 1)
    for gy in range(0, int(ymax) + 1, step):
        d.line([(L, Y(gy)), (W - R, Y(gy))], fill="#e4e3df", width=1)
        d.text((L - 40, Y(gy) - 6), f"{gy} GB", fill="#52514e")
    hstep = max(1, int(xmax / 8) or 1)
    for gx in range(0, int(xmax) + 1, hstep):
        d.text((X(gx) - 6, H - B + 8), f"{gx} h", fill="#52514e")
    d.line([(L, H - B), (W - R, H - B)], fill="#52514e", width=1)
    for name, color, pts in series:
        if name.startswith("Footprint + Metal"):
            for x, y in pts:
                d.ellipse([X(x) - 4, Y(y) - 4, X(x) + 4, Y(y) + 4], fill=color, outline="#fcfcfb", width=2)
        elif len(pts) > 1:
            d.line([(X(x), Y(y)) for x, y in pts], fill=color, width=2)
    d.text((L, 24), title, fill="#0b0b0b")
    lx = L
    for name, color, _ in series:
        d.rectangle([lx, H - 44, lx + 14, H - 30], fill=color)
        d.text((lx + 20, H - 44), name, fill="#0b0b0b")
        lx += 20 + int(d.textlength(name)) + 30
    os.makedirs(os.path.dirname(os.path.abspath(png)), exist_ok=True)
    img.save(png)
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--png")
    ap.add_argument("--no-log", action="store_true", help="skip the unified-log memorystatus scan (tests)")
    a = ap.parse_args()
    run = load(os.path.join(a.run, "run.json"), {})
    probe = os.path.join(a.run, "probe")
    samples = jsonl(os.path.join(probe, "samples.jsonl"))
    setup = load(os.path.join(probe, "setup.json"), {})
    result = load(os.path.join(probe, "result.json"))
    sampler = load(os.path.join(a.run, "sampler", "sampler.json"), {})
    hangs = jsonl(os.path.join(probe, "hangs.jsonl"))
    events = jsonl(os.path.join(probe, "events.jsonl"))
    saved = jsonl(os.path.join(probe, "saved.jsonl"))
    soak_start = float(setup.get("setupS", 0.0))
    start_epoch = float(run.get("start_epoch", 0))
    bundle = run.get("bundle", "")

    g_fm = growth(samples, "footprint_plus_metal", soak_start)
    g_f = growth(samples, "footprint_total", soak_start)
    pids = {int(p) for p in (sampler.get("pids") or {})}
    pids |= {int(s["app_pid"]) for s in samples if s.get("app_pid")} | {int(s["helper_pid"]) for s in samples if s.get("helper_pid")}
    pids |= {int(c["pid"]) for s in samples for c in s.get("children", [])}
    if run.get("app_pid"):
        pids.add(int(run["app_pid"]))
    reps = crashscan.reports(start_epoch) if start_epoch else []
    ours = [r for r in crashscan.crashes(reps) if crashscan.is_ours(r, pids, bundle)]
    jetsam = crashscan.jetsam_kills(reps, pids)
    log_kills, log_err = ([], "skipped (--no-log)") if a.no_log or not start_epoch else memorystatus_kills(
        dt.datetime.fromtimestamp(start_epoch).strftime("%Y-%m-%d %H:%M:%S"), pids)
    mk_dirs = [os.path.join(probe, "metrickit"), os.path.join(a.run, "container", "Diagnostics")]
    mk_crash = []
    for d in mk_dirs:
        try:
            mk_crash += [os.path.join(d, n) for n in os.listdir(d) if n.startswith("crash-") and n.endswith(".json")]
        except OSError:
            pass
    mk_crash_count = len(mk_crash) + int((result or {}).get("metricKitCrashes", 0))
    hangs_over = [h for h in hangs if h.get("seconds", 0) > HANG_MAX_S]
    mk_hangs = int((result or {}).get("metricKitHangsOver2s", 0))
    exit_code = run.get("exit_code")
    completed = bool(result and result.get("completed")) and exit_code == 0
    helper_restarts = int((result or {}).get("helperRestarts", 0))
    crash_count = len(ours) + mk_crash_count + (0 if completed else 1) + helper_restarts
    lost = lost_saved(os.path.join(a.run, "container"), saved) if (ours or not completed or helper_restarts) else \
        {"checked": 0, "lost": [], "note": "no crash: not needed"}
    swap = [s.get("vm_swapouts") for s in samples if s.get("vm_swapouts") is not None]
    hours = float(run.get("hours", 0))
    dry = bool(run.get("dry")) or hours < 2
    growth_ok = g_fm["growth"] is not None and g_fm["growth"] <= GROWTH_MAX
    checks = {
        "growth_le_10pct": growth_ok,
        "zero_crashes": crash_count == 0,
        "zero_hangs_over_2s": not hangs_over and mk_hangs == 0,
        "zero_oom": not jetsam and not log_kills,
    }
    passed = all(checks.values())
    counts = (result or {}).get("counts", {})
    failures = (result or {}).get("failures", {})
    out = {
        "at": "AT-NFR-S3", "date": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "command": f"make soak HOURS={run.get('hours')} TIER={run.get('tier')}", "tier": run.get("tier"),
        "hours": hours, "dry": dry, "valid": not dry, "pass": passed and not dry, "checks": checks,
        "growth": g_fm, "growth_footprint_only": g_f, "growth_bar": GROWTH_MAX,
        "crashes": {"total": crash_count, "ips": [{"path": r["path"], "pid": r["pid"], "name": r["name"]} for r in ours],
                    "metrickit": mk_crash, "metrickit_reported": int((result or {}).get("metricKitCrashes", 0)),
                    "app_exit_code": exit_code, "completed": completed, "helper_restarts": helper_restarts},
        "hangs": {"over_2s": len(hangs_over), "max_s": max((h.get("seconds", 0) for h in hangs), default=0),
                  "over_250ms": len(hangs), "metrickit_over_2s": mk_hangs, "worst": sorted(hangs_over, key=lambda h: -h["seconds"])[:10],
                  "over_1s_by_phase": dict(Counter(h.get("phase", "?") for h in hangs if h.get("seconds", 0) >= 1).most_common()),
                  "over_1s_where": Counter(h["where"] for h in hangs if h.get("seconds", 0) >= 1 and h.get("where")).most_common(10),
                  "stacks": "probe/hang-stacks/ (main-thread call tree of each stall ≥ 1 s)"},
        "oom": {"jetsam": jetsam, "memorystatus_log": log_kills[:20], "log_error": log_err},
        "lost_saved_messages": lost,
        "peak_engine": {"bytes": sampler.get("peak_engine_bytes"), "t_s": sampler.get("peak_engine_t_s"),
                        "what": "phys_footprint(engine helper + its children), 1 s samples (NFR-R1's quantity)",
                        "budget_b_bytes": setup.get("budgetB"), "by_name": sampler.get("peak_by_name"),
                        "workload": {"chat": setup.get("slot"), "evil": setup.get("evilSlot"),
                                     "images": (result or {}).get("config", {}).get("image_mode"),
                                     "image_gb": (result or {}).get("config", {}).get("image_gb")}},
        "peak_app_bytes": sampler.get("peak_app_bytes"), "peak_total_bytes": sampler.get("peak_total_bytes"),
        "swapouts_delta_pages": (swap[-1] - swap[0]) if len(swap) >= 2 else None,
        "legs": {"counts": counts, "failures": failures, "loops": (result or {}).get("loops"),
                 "images": (result or {}).get("imagesDone"), "errors_tail": (result or {}).get("errors", [])[-20:]},
        "setup": setup, "run": run, "samples": len(samples), "events": len(events), "saved_messages": len(saved),
    }
    if a.png:
        title = f"AT-NFR-S3 soak {run.get('tier')} {hours:g} h, growth {g_fm['growth'] * 100:.1f} %" if g_fm["growth"] is not None \
            else f"AT-NFR-S3 soak {run.get('tier')} {hours:g} h"
        err = plot(a.png, os.path.join(a.run, "sampler", "sampler.csv"), samples, soak_start, title)
        out["plot"] = a.png if err is None else {"skipped": err}
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w") as f:
        json.dump(out, f, indent=1, sort_keys=True, default=str)
    gtxt = f"{g_fm['growth'] * 100:.1f} %" if g_fm["growth"] is not None else "n/a"
    peak = sampler.get("peak_engine_bytes") or 0
    print(f"{'PASS' if out['pass'] else ('DRY' if dry else 'FAIL')} AT-NFR-S3 {run.get('tier')} {hours:g} h: growth {gtxt} "
          f"(≤ 10 %), crashes {crash_count}, hangs > 2 s {len(hangs_over) + mk_hangs}, OOM {len(jetsam) + len(log_kills)}, "
          f"loops {(result or {}).get('loops')}, failures {sum(failures.values()) if failures else 0}, "
          f"engine peak {peak / 1e9:.2f} GB → {a.out}")
    return 0 if out["pass"] or dry else 1


if __name__ == "__main__":
    sys.exit(main())
