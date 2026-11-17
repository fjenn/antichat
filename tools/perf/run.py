#!/usr/bin/env python3
"""`make perf METRIC=<ID> TIER=<T0..T4|T2-24|T3-48|na> [RUNS=20]` (M1.T26a; test-strategy §6). Stdlib only.

Runs the probe of one metric, checks the machine is quiet enough, computes p50/p95/p99 and writes
`metrics.<ID>.<tier>[/<variant>]` into build/perf/report.json (schema tools/perf/report_schema.json; targets from
tools/perf/nfr_targets.json, generated from nfr.md). Every run — also a refused one — leaves a record in
build/perf/runs/<utc>-<ID>-<tier>.json with the machine load before, during and after.

  run.py --metric U1 --tier na --runs 20                 # probe + write the report
  run.py --metric U2 --tier T1 --from-log perf.jsonl     # ingest Signposts intervals recorded elsewhere (XCUITest, probe)
  run.py --metric C1 --tier T1 --runs 20 --allow-noisy   # measure on a busy machine: entry marked noisy / valid=false
  run.py --list                                          # metrics, probes and their owners

Options: --wait-quiet S (poll the load up to S seconds before giving up), --replace (overwrite an existing entry;
default append-only, CR-T-12), --out PATH, --app PATH (default build/AntiChat.app), --dry-run (no report write).
Env: ALLOW_NOISY=1, PERF_WAIT=<s>, PERF_REPLACE=1 (Makefile pass-through), ANTICHAT_FIXTURES, ANTICHAT_PERF_MAX_*
(tools/perf/load.py thresholds).

Exit codes: 0 every check passed · 1 measured, a check failed · 2 probe not available yet (forward leg, convention
9: the owner task is printed) · 3 refused: machine too busy (re-run later, or --allow-noisy) · 4 error ·
5 deferred: `gpu-run.sh timing` gave up waiting for load < 40 (exit 75).
GPU probes run through `gpu_prefix()`: ANTICHAT_GPU_MODE=timing (default) | shared (dry runs on a busy machine);
inside an outer `gpu-run.sh timing` (ANTICHAT_GPU_LOCK_HELD) they take no second lock.

Probes:
  log       ingest `ANTICHAT_PERF_LOG` JSONL (Packages/Foundation/.../Perf/PerfRecorder.swift); interval name per metric
  launch    U1: exec the app N times with ANTICHAT_PERF_QUIT_AFTER=launchToUsable; cold = `sudo -n purge` before each
            launch when sudo is available without a password, else labelled "warm-ish" (PRD §1.5: never wait for sudo)
  chat      C1/C1b/C2/C4: `antichat-bench chat --via xpc` through gpu_prefix() (gpu-run.sh, else lockf /tmp/antichat-gpu.lock)
  selftest  a fixed CPU loop (pipeline check; writes build/perf/selftest.json unless --out)
  M9.T05    IMAGE_TURN_OVERHEAD (`-Bench image-turn` + perf log: imageTurn − imageGen; --from-log re-reads one),
            F7_VIDEO (`-Bench video` rows' `videoGate` note ÷ final_s; VIDEO_RAW=<jsonl> re-reads video.T4 rows),
            V8 / V11 at the tier's cap (`-Bench read-aloud` / `-Bench transcribe-file`; V8_JSON / V11_JSON ingest the
            in-process tests), U2/U6/U10/U11 from App/UITests/Perf (make test-ui FILTER=…, then --from-log)
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import load as loadmod  # noqa: E402
import reportio  # noqa: E402
from stats import percentile  # noqa: E402

ROOT = reportio.ROOT
TARGETS = os.path.join(HERE, "nfr_targets.json")
SCHEMA = os.path.join(HERE, "report_schema.json")
RUNS_DIR = os.environ.get("ANTICHAT_PERF_RUNS_DIR") or os.path.join(ROOT, "build/perf/runs")
RAW_DIR = os.path.join(ROOT, "build/perf/raw/m1")
GPU_LOCK = loadmod.GPU_LOCK

EXIT_PASS, EXIT_FAIL, EXIT_FORWARD, EXIT_REFUSED, EXIT_ERROR, EXIT_DEFERRED = 0, 1, 2, 3, 4, 5


GPU_RUN = os.environ.get("ANTICHAT_GPU_RUN", os.path.expanduser("~/AntiChat-tools/gpu-run.sh"))


def gpu_prefix() -> list[str]:
    """Wrapper for every GPU probe (M9.T05 prep). `ANTICHAT_GPU_MODE=timing|shared` (default timing: exclusive, load
    < 40, exit 75 = DEFERRED); a dry run on a busy machine uses shared. Already inside `gpu-run.sh timing`
    (ANTICHAT_GPU_LOCK_HELD set) → no prefix: a nested `lockf /tmp/antichat-gpu.lock` would wait on our own lock forever.
    No gpu-run.sh on this machine → the bare one-GPU-job lock."""
    if os.environ.get("ANTICHAT_GPU_LOCK_HELD") == "timing":
        return []
    mode = os.environ.get("ANTICHAT_GPU_MODE", "timing")
    if mode not in ("timing", "shared"):
        raise RuntimeError(f"ANTICHAT_GPU_MODE={mode}: timing or shared")
    if os.access(GPU_RUN, os.X_OK):
        return [GPU_RUN, mode, "--"]
    return ["lockf", GPU_LOCK]


def run_gpu(cmd: list[str], what: str) -> subprocess.CompletedProcess:
    p = subprocess.run(gpu_prefix() + cmd, capture_output=True, text=True)
    if p.returncode == 75:
        raise Deferred(f"{what}: gpu-run.sh DEFERRED (load stayed >= its timing bar); record as deferred")
    return p

# Interval name in the perf log, unit conversion from ns, and the owner of the driver that produces the log.
LOG_METRICS = {
    "U1": ("launchToUsable", 1e9, "M1.T26a launch probe (this file)"),
    "U2": ("sendAck", 1e6, "M9.T05 App/UITests/Perf/SendAckPerfTests (make test-ui FILTER=SendAckPerfTests)"),
    "U6": ("stopToIdle", 1e6, "M9.T05 App/UITests/Perf/StopPerfTests (make test-ui FILTER=StopPerfTests)"),
    "U7": ("titleReady", 1e9, "M1.T19 TitleService signpost + M1.T26b TitlePerfTests"),
    "U10": ("paletteQuery", 1e6, "M9.T05 App/UITests/Perf/PalettePerfTests (make test-ui FILTER=PalettePerfTests)"),
    "U11": ("chatOpen", 1e6, "M9.T05 App/UITests/Perf/LongChatOpenPerfTests (make test-ui FILTER=LongChatOpenPerfTests)"),
    "U9": ("quickPanelOpen", 1e6, "M8.T13 probe_u9 (this file)"),
    "sidebarUpdate": ("sidebarUpdate", 1e6, "M1.T26b (AT-011 leg)"),
    "composerDock": ("composerDock", 1e6, "M1.T26b (AT-001 leg)"),
    "V283_EOS_FINAL": ("voice.turnEndedToFinal", 1e6, "M3.T09 TurnSplitFixtureTests/eagerSTTLatency"),
}
# Metrics whose probe lands later (exit 2 names the owner).
FORWARD = {
    "U4": "M1.T26b CadencePerfTests (ScriptedEngine 6 s TTFT)",
    "U5": "M1.T26b CadencePerfTests (meanwhile: --from-log with HitchCounter `hitchSession` records)",
    "U8": "M1.T26b App/UITests/Perf/ScrollPerfTests",
    "C3": "M1.T26b (long-context-needles at 75% context)",
    "C5": "M1.T26b CadencePerfTests/testPrefillProgress",
    "C6": "M1.T26b (regenerate/edit on a 2K history)",
    "S2": "M1.T26b (autosave interval probe)",
    "S4": "M1.T26b (helper kill -9 → restart; M0 value in m0.S4.*)",
    "R3": "M1.T26b `antichat-bench idle`",
    # M4.T06 (AT-NFR-M3, AT-236 AC3, AT-291 AC3): timing drivers over antichat-bench image (real klein set, gpu-run timing);
    # until then ImageHandoffTests records the T1 unload / peak / next-turn reload leg in build/at/AT-286/handoff-T1.json.
    "M3": "M9.T05 (image-turn swap timing: unload ≤ 1 s, reload ≤ NFR-M1; ImageHandoffTests T1 leg meanwhile)",
    "JOB_CANCEL_FREE": "M9.T05 (job.cancelRequested → gpu.freed vs NFR-VID3 with the real image engine, AT-291 AC3)",
}
CHAT_METRICS = {"C1": "ttft_app_ms", "C1b": "ttft_app_ms", "C2": "decode_tok_s", "C4": "prefill_tok_s"}
# M7.T03 step 10 (R-254 hypotheses, R-248 AC1): web search turns through `antichat-bench search-e2e` (live engines, real
# model, Web search chip on). Not NFRs, so their bars live here, not in nfr_targets.json (generated from nfr.md).
# `search`: primary = first answer token; variants activity / results / fetch_extract. `search_e2e` (`search-e2e`):
# send → answer complete; the ≥ 2 pills per run check is in the bench JSON (build/at/AT-248/<date>-c1.json).
def _le(v):
    return [{"op": "<=", "stat": "p50", "value": v}]
SEARCH_TARGETS = {
    "search": {"unit": "s", "nfr": None, "title": "Web search turn: first answer token p50 (R-254)", "direction": "lower",
               "gate_stat": "p50", "tiers": {"T1": _le(8.0), "T3": _le(5.0)},
               "variants": {"activity": {"default": _le(0.3)}, "results": {"default": _le(2.5)},
                            "fetch_extract": {"default": _le(4.0)}}},
    "search_e2e": {"unit": "s", "nfr": None, "title": "Web search answer complete p50 (R-248 AC1)", "direction": "lower",
                   "gate_stat": "p50", "tiers": {"T1": _le(12.0)}, "variants": {}},
}
SEARCH_ALIASES = {"search-e2e": "search_e2e"}
# M9.T05: NFR-U3 (message sent while the model loads). gen-targets.py does not parse its row (prose bar), so its bars
# live here, read off nfr.md NFR-U3: the "Loading model…" status at ≤ 2 s; the reply within NFR-M1 (band by weights)
# + NFR-C1 at the tier, checked as `reply_over_budget` = ttft − (M1 band + C1 p50 bar) ≤ 0 s.
EXTRA_TARGETS = {
    # M9.T05 (AT-236 AC3; no NFR row, so the bar is the AC's number, M4.md "Named test artefacts"): per image turn
    # imageTurn (send to reply written) minus imageGen (image.loadStart to image.final), p50 <= 2 s.
    "IMAGE_TURN_OVERHEAD": {"unit": "s", "nfr": None, "title": "Image turn overhead outside image load + generation (AT-236 AC3)",
                            "direction": "lower", "gate_stat": "p50", "tiers": {"default": [{"op": "<=", "stat": "p50", "value": 2.0}]},
                            "variants": {"turn": {}, "gen": {}}},
    # M9.T05 (NFR-F7 "video frame checks <= 10 % of generation time", M5.md AT-NFR-F7 video part): per video job the
    # ChildSafetyCheck gate's added time (preview checks + the final check after the last frame) over the job's wall
    # time (request to MP4), in %; gated on the worst job. Variants: the preview / final shares, the final check's wall.
    "F7_VIDEO": {"unit": "%", "nfr": "NFR-F7", "title": "Video frame checks: gate time / generation time per job",
                 "direction": "lower", "gate_stat": "max", "tiers": {"default": [{"op": "<=", "stat": "max", "value": 10.0}]},
                 "variants": {"previews": {}, "final": {}, "final_wall": {}}},
    "U3": {"unit": "s", "nfr": "NFR-U3", "title": "Message sent while the model is loading (status ≤ 2 s; reply ≤ M1 + C1)",
           "direction": "lower", "gate_stat": "p95", "tiers": {"default": [{"op": "<=", "stat": "p95", "value": 2.0}]},
           "variants": {"reply_over_budget": {"default": [{"op": "<=", "stat": "p50", "value": 0.0}]}, "ttft": {}, "accepted": {}}},
}
# Default model per tier cap (M1.md M1.T26 step 3; keys of catalog/dev.yaml / DevSlots).
TIER_MODEL = {"T0": "chat-2b", "T1": "chat-9b-q4", "T2": "chat-9b-q4", "T2-24": "chat-9b-q4", "T3": "chat-35b-q4", "T3-48": "chat-35b-q4"}
TIER_CAP = {"T2": "T2-24", "T3": "T3-48"}


# ---------------------------------------------------------------- helpers

def sh(cmd: list[str], **kw) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=kw.get("timeout", 15)).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def commit() -> str:
    head = sh(["git", "-C", ROOT, "rev-parse", "--short=12", "HEAD"]) or "unknown"
    dirty = sh(["git", "-C", ROOT, "status", "--porcelain", "--untracked-files=no"])
    return head + ("+dirty" if dirty else "")


def machine(targets: dict) -> dict:
    brand = sh(["sysctl", "-n", "machdep.cpu.brand_string"])
    chip = brand.replace("Apple ", "") if brand else platform.machine()
    mem = sh(["sysctl", "-n", "hw.memsize"])
    ram = f"{int(mem) // (1 << 30)} GB" if mem.isdigit() else "unknown"
    osv = f"macOS {sh(['sw_vers', '-productVersion'])} ({sh(['sw_vers', '-buildVersion'])})"
    return {"chip": chip, "ram": ram, "os": osv, "speed_class": speed_class(chip, targets), "ncpu": loadmod.ncpu(),
            "host": platform.node()}


def speed_class(chip: str, targets: dict) -> str | None:
    for cls in ("S4", "S3", "S2", "S1"):  # M5 is listed in S2 (pre-26.2) and S3: take the faster row
        if chip in targets.get("speed_classes", {}).get(cls, []):
            return cls
    return None


def app_build(app: str | None) -> dict:
    if not app or not os.path.isdir(app):
        return {"app": None, "config": "n/a", "version": None}
    macos = os.path.join(app, "Contents/MacOS")
    config = "Debug" if any(n.endswith(".debug.dylib") for n in os.listdir(macos)) else "Release"
    info = None
    if config == "Release" and perf_marker_in(app):
        # M9.T05 perf-harness build (make build-perf): ask the binary what it was compiled as.
        info = parse_buildinfo(sh([os.path.join(macos, "AntiChat"), "-Bench", "buildinfo"], timeout=60))
        config = "Perf" if build_info_ok(info) else "Perf-unconfirmed"
        if info and info.get("debug") is True:
            config = "Debug"
    ver = None
    plist = os.path.join(app, "Contents/Info.plist")
    if os.path.exists(plist):
        v = sh(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString", plist])
        b = sh(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleVersion", plist])
        ver = f"{v} ({b})" if v else None
    out = {"app": os.path.relpath(app, ROOT) if app.startswith(ROOT) else app, "config": config, "version": ver}
    if info is not None or config.startswith("Perf"):
        out["buildinfo"] = info
    return out


# M9.T05: the perf-harness marker (BuildFlavor.perfHarnessMarker; tools/ci/perfharness-guard.py keeps it out of releases).
PERF_MARKER = b"AntiChatPerfHarnessBuild-M9T05"


def perf_marker_in(app: str) -> bool:
    for sub in ("MacOS", "Frameworks"):
        d = os.path.join(app, "Contents", sub)
        for dirpath, _, names in os.walk(d):
            for n in names:
                f = os.path.join(dirpath, n)
                if os.path.islink(f) or not os.path.isfile(f):
                    continue
                try:
                    with open(f, "rb") as fh:
                        if PERF_MARKER in fh.read():
                            return True
                except OSError:
                    pass
    return False


def parse_buildinfo(out: str) -> dict | None:
    for line in reversed((out or "").splitlines()):
        line = line.strip()
        if line.startswith("{") and "perf_harness" in line:
            try:
                return json.loads(line)
            except ValueError:
                return None
    return None


def build_info_ok(info: dict | None) -> bool:
    """A perf-harness build counts only when its own `-Bench buildinfo` says: optimized, not DEBUG, perf flag on."""
    return bool(info) and info.get("perf_harness") is True and info.get("optimized") is True and info.get("debug") is False


def build_valid(build: dict) -> bool:
    """Debug numbers are never results (tools/bench.sh rule); a perf build only once its buildinfo confirms it; a
    plain Release build (or a probe with no app) as before."""
    cfg = build.get("config")
    if cfg == "Debug":
        return False
    if cfg == "Perf":
        return build_info_ok(build.get("buildinfo"))
    if cfg == "Perf-unconfirmed":
        return False
    return True


def stats(xs: list[float]) -> dict:
    xs = [x for x in xs if x is not None]
    if not xs:
        return {"p50": None, "p95": None, "p99": None, "mean": None, "min": None, "max": None, "n": 0}
    return {"p50": percentile(xs, 50), "p95": percentile(xs, 95), "p99": percentile(xs, 99),
            "mean": sum(xs) / len(xs), "min": min(xs), "max": max(xs), "n": len(xs)}


def tier_family(tier: str) -> str:
    return tier.split("-")[0]


def checks_for(t: dict, tier: str, variant: str | None, mach: dict, extra: dict | None = None) -> list[dict] | None:
    table = t["variants"].get(variant) if variant else t["tiers"]
    if table is None:
        return None
    sc = mach.get("speed_class")
    for key in (tier, tier_family(tier), ("S1" if sc == "S1" else "S2+") if sc else None, "default"):
        if key and key in table:
            cs = [dict(c) for c in table[key]]
            for c in cs:  # NFR-M1: the bound depends on the weights size
                if c.get("by_weights_gb") and extra and extra.get("weights_gb"):
                    c["value"] = next((b["value"] for b in c["by_weights_gb"] if extra["weights_gb"] <= b["max_weights_gb"]), None)
            return cs
    return None


def evaluate(st: dict, checks: list[dict] | None) -> tuple[list[dict] | None, bool | None]:
    if not checks or st["n"] == 0:
        return checks, None
    ok_all = True
    out = []
    for c in checks:
        c = dict(c)
        a = st["mean"] if c["stat"] == "mean" else st.get(c["stat"])
        v = c.get("value")
        if a is None or v is None:
            c["actual"], c["ok"] = a, None
            out.append(c)
            ok_all = False
            continue
        op = c["op"]
        ok = {"<=": a <= v, "<": a < v, ">=": a >= v, ">": a > v, "==": a == v,
              "within": v <= a <= c.get("hi", v)}[op]
        c["actual"], c["ok"] = a, ok
        ok_all = ok_all and ok
        out.append(c)
    return out, ok_all


# ---------------------------------------------------------------- mini JSON-Schema validator (subset used here)

def validate(inst, schema: dict, root: dict | None = None, path: str = "$") -> list[str]:
    root = root or schema
    if "$ref" in schema:
        node = root
        for part in schema["$ref"].lstrip("#/").split("/"):
            node = node[part]
        return validate(inst, node, root, path)
    errs: list[str] = []
    types = schema.get("type")
    if types:
        types = [types] if isinstance(types, str) else types
        py = {"object": dict, "array": list, "string": str, "boolean": bool, "null": type(None)}
        def is_t(t):
            if t == "integer":
                return isinstance(inst, int) and not isinstance(inst, bool)
            if t == "number":
                return isinstance(inst, (int, float)) and not isinstance(inst, bool)
            return isinstance(inst, py[t])
        if not any(is_t(t) for t in types):
            return [f"{path}: {type(inst).__name__} is not {types}"]
    if "const" in schema and inst != schema["const"]:
        errs.append(f"{path}: {inst!r} != {schema['const']!r}")
    if "enum" in schema and inst not in schema["enum"]:
        errs.append(f"{path}: {inst!r} not in {schema['enum']}")
    if "minimum" in schema and isinstance(inst, (int, float)) and inst < schema["minimum"]:
        errs.append(f"{path}: {inst} < {schema['minimum']}")
    if isinstance(inst, dict):
        for r in schema.get("required", []):
            if r not in inst:
                errs.append(f"{path}: missing {r}")
        props = schema.get("properties", {})
        for k, v in inst.items():
            if "propertyNames" in schema and not re.match(schema["propertyNames"]["pattern"], k):
                errs.append(f"{path}: key {k!r} does not match {schema['propertyNames']['pattern']}")
            if k in props:
                errs += validate(v, props[k], root, f"{path}.{k}")
            elif isinstance(schema.get("additionalProperties"), dict):
                errs += validate(v, schema["additionalProperties"], root, f"{path}.{k}")
    if isinstance(inst, list) and isinstance(schema.get("items"), dict):
        for i, v in enumerate(inst):
            errs += validate(v, schema["items"], root, f"{path}[{i}]")
    return errs


def validate_report(data: dict) -> list[str]:
    schema = json.load(open(SCHEMA))
    sub = {k: data[k] for k in reportio.RESERVED if k in data}
    return validate(sub, schema)


# ---------------------------------------------------------------- probes

class Forward(Exception):
    pass


class Deferred(RuntimeError):
    pass


class ProbeResult:
    def __init__(self, samples: dict[str | None, list[float]], method="measured", label=None, notes=None, raw=None,
                 model=None, extra=None):
        self.samples, self.method, self.label = samples, method, label
        self.notes, self.raw, self.model, self.extra = notes or [], raw, model, extra or {}


def read_log(path: str, name: str) -> list[dict]:
    rows = []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if r.get("name") == name and r.get("kind") == "interval":
            rows.append(r)
    return rows


def probe_log(a, metric: str) -> ProbeResult:
    if metric == "U5":  # HitchCounter: one `hitchSession` event per streamed reply; value = frames > 33 ms
        rows = [json.loads(l) for l in open(a.from_log) if l.strip().startswith("{")]
        rows = [r for r in rows if r.get("name") == "hitchSession"]
        if not rows:
            raise RuntimeError(f"{a.from_log}: no 'hitchSession' records")
        vals = [float(r["meta"]["hitches"]) for r in rows]
        longest = max(float(r["meta"].get("longest_ms", 0)) for r in rows)
        return ProbeResult({None: vals}, raw=os.path.relpath(os.path.abspath(a.from_log), ROOT),
                           notes=[f"{len(vals)} streaming sessions (HitchCounter); longest frame {longest:.1f} ms",
                                  "cadence / fade / jump variants come from the 120 fps recording (frametime.py, layout-jump.py)"])
    name, div, _owner = LOG_METRICS[metric]
    rows = read_log(a.from_log, name)
    if not rows:
        raise RuntimeError(f"{a.from_log}: no '{name}' intervals")
    vals = [r["dur_ns"] / div for r in rows]
    return ProbeResult({None: vals}, raw=os.path.relpath(os.path.abspath(a.from_log), ROOT),
                       notes=[f"ingested {len(vals)} '{name}' intervals from the perf log"])


def probe_selftest(a, metric: str) -> ProbeResult:
    vals = []
    for _ in range(a.runs):
        t0 = time.perf_counter()
        x = 0
        for i in range(300_000):
            x += i * i
        vals.append((time.perf_counter() - t0) * 1000)
    return ProbeResult({None: vals}, notes=["300k-iteration Python loop; pipeline self-test, not an NFR"])


def probe_launch(a, metric: str) -> ProbeResult:
    """U1 launch loop. Primary = cold (or warm-ish), variant 'warm' = back-to-back relaunch."""
    exe = os.path.join(a.app, "Contents/MacOS/AntiChat")
    if not os.access(exe, os.X_OK):
        raise RuntimeError(f"{exe} missing: run make build-perf first")
    # A release build carries no developer hooks (tools/ci/dev-modes-guard.py): it reads neither ANTICHAT_PERF_LOG nor
    # ANTICHAT_PERF_QUIT_AFTER, so it would never record launchToUsable and never quit. U1 is measured on the
    # perf-harness build (Release optimisation + the hooks; make build-perf), which never ships.
    if app_build(a.app).get("config") == "Release":
        raise RuntimeError(f"{a.app} is a release build (no perf hooks): measure U1 with the perf-harness app (make build-perf)")
    # M9.T05 prep: a dev-container launch is a BackgroundRun (LaunchOptions.isAutomationRun): the app never activates,
    # the composer never becomes first responder and no launchToUsable is ever recorded (n = 0 since BackgroundRun
    # landed). NFR-U1 is a foreground launch by definition, so it takes focus: only with ANTICHAT_PERF_FOREGROUND=1
    # (tools/perf/t05.py sets it for T05, which runs with the owner away; tests never take focus otherwise).
    if os.environ.get("ANTICHAT_PERF_FOREGROUND") != "1":
        raise RuntimeError("U1 is a foreground launch (takes focus): set ANTICHAT_PERF_FOREGROUND=1 with the owner away")
    os.makedirs(RAW_DIR, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    log = os.path.join(RAW_DIR, f"U1-{stamp}.jsonl")
    container = tempfile.mkdtemp(prefix="antichat-perf-")
    purge_ok = subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode == 0
    cold, warm, notes = [], [], []

    def launch(tag: str) -> float | None:
        before = len(read_log(log, "launchToUsable")) if os.path.exists(log) else 0
        env = dict(os.environ, ANTICHAT_PERF_LOG=log, ANTICHAT_PERF_QUIT_AFTER="launchToUsable", ANTICHAT_BACKGROUND="0")
        # Debug and perf-harness builds honour -ANTICHAT_DEV_CONTAINER (an empty temp container).
        # -ApplePersistenceIgnoreState: a killed or quit previous run must not restore its window state (without it
        # the restored window never focused the composer in the 2026-10-30 smoke run).
        p = subprocess.Popen([exe, "-ApplePersistenceIgnoreState", "YES", "-ANTICHAT_DEV_CONTAINER", container, "-SkipOnboarding", "YES"], env=env,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            p.wait(timeout=a.launch_timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            notes.append(f"{tag}: no launchToUsable within {a.launch_timeout} s (killed)")
            return None
        rows = read_log(log, "launchToUsable")
        if len(rows) <= before:
            notes.append(f"{tag}: exited {p.returncode} without a launchToUsable record")
            return None
        return rows[-1]["dur_ns"] / 1e9

    try:
        for i in range(a.runs):
            if purge_ok:
                subprocess.run(["sudo", "-n", "purge"], capture_output=True)
            v = launch(f"cold {i}")
            if v is not None:
                cold.append(v)
            time.sleep(0.5)
            v = launch(f"warm {i}")
            if v is not None:
                warm.append(v)
            time.sleep(0.5)
    finally:
        shutil.rmtree(container, ignore_errors=True)
    label = None if purge_ok else "warm-ish (no `sudo -n purge`: file cache not dropped, PRD §1.5)"
    if not purge_ok:
        notes.append("cold leg not run: permission (sudo purge); primary entry = first launch of each pair, warm-ish")
    notes.append("app exec'd directly (no LaunchServices/Dock click); end = first composer focus in a visible window")
    return ProbeResult({None: cold, "warm": warm}, label=label, notes=notes, raw=os.path.relpath(log, ROOT))


def probe_u9(a, metric: str) -> ProbeResult:
    """NFR-U9: quick panel open. Launches the Debug app (dev container, background run, `-QuickPanelHotkeyHook YES`),
    waits for the composer focus + 5 s idle (the panel is built hidden at first paint + 1 s), then runs
    tools/perf/hotkey-post (distributed notification carrying the poster's systemUptime; no CGEvent, A-M8-T13a) and
    reads the app's `quickPanelOpen` intervals (trigger → field first responder + panel displayed)."""
    exe = os.path.join(a.app, "Contents/MacOS/AntiChat")
    if not os.access(exe, os.X_OK):
        raise RuntimeError(f"{exe} missing: run make build first")
    os.makedirs(RAW_DIR, exist_ok=True)
    poster = os.path.join(ROOT, "build/perf/bin/hotkey-post")
    src = os.path.join(ROOT, "tools/perf/hotkey-post/main.swift")
    if not os.path.exists(poster) or os.path.getmtime(poster) < os.path.getmtime(src):
        os.makedirs(os.path.dirname(poster), exist_ok=True)
        subprocess.run(["xcrun", "swiftc", "-O", "-o", poster, src], check=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    log = os.path.join(RAW_DIR, f"U9-{stamp}.jsonl")
    container = tempfile.mkdtemp(prefix="antichat-perf-")
    notes = ["Debug build, background run (the panel is ordered in concealed: no focus taken from the owner); "
             "trigger = the hook's distributed notification with the poster's clock (method `posted`)"]
    env = dict(os.environ, ANTICHAT_PERF_LOG=log)
    p = subprocess.Popen([exe, "-ApplePersistenceIgnoreState", "YES", "-ANTICHAT_DEV_CONTAINER", container, "-SkipOnboarding", "YES",
                          "-QuickPanelHotkeyHook", "YES"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        # Readiness: the app runs in the background (never key), so `launchToUsable` never comes; the first perf-log
        # record (`migration`, the store opened) + 10 s covers first paint + the hidden panel build (+ 1 s).
        deadline = time.time() + a.launch_timeout
        def started() -> bool:
            return os.path.exists(log) and os.path.getsize(log) > 0
        while time.time() < deadline and not started():
            if p.poll() is not None:
                raise RuntimeError(f"app exited {p.returncode} before it opened its store")
            time.sleep(0.5)
        if not started():
            raise RuntimeError(f"no perf-log record within {a.launch_timeout} s")
        time.sleep(10)
        subprocess.run([poster, "--count", str(max(a.runs, 30)), "--interval", "1.2", "--key", "space", "--mods", "option"],
                       check=True, timeout=max(a.runs, 30) * 2 + 30)
        time.sleep(1.5)
    finally:
        p.terminate()
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
        shutil.rmtree(container, ignore_errors=True)
    rows = [r for r in read_log(log, "quickPanelOpen") if r.get("meta", {}).get("method") == "posted"]
    vals = [r["dur_ns"] / 1e6 for r in rows]
    unfocused = sum(1 for r in rows if r.get("meta", {}).get("focused") != "1")
    if unfocused:
        notes.append(f"{unfocused} open(s) ended without the field first responder")
    return ProbeResult({None: vals}, method="measured", label="posted (hook)", notes=notes, raw=os.path.relpath(log, ROOT))


def b1_parse_top(out: str) -> list[float]:
    """Sum of the `power` column per `top -l` sample (each sample starts at its `PID` header); the first sample is
    dropped (no interval yet)."""
    blocks: list[float] = []
    for line in out.splitlines():
        f = line.split()
        if f[:1] == ["PID"]:
            blocks.append(0.0)
        elif blocks and len(f) == 2 and f[0].isdigit():
            try:
                blocks[-1] += float(f[1])
            except ValueError:
                pass
    return blocks[1:]


def probe_b1(a, metric: str) -> ProbeResult:
    """NFR-B1 idle energy (M9.T05): the app with a window open and no generation, Activity Monitor's Energy Impact
    sampled 1 Hz by `top -stats pid,power` (no sudo; same column as Activity Monitor) for `--runs` × 15 s (20 → 5 min).
    Samples = per-second Energy Impact of the app + its helper; the bar is the mean. Timers ≤ 1 Hz: not measured
    here (needs powermetrics / sudo, PRD §1.5)."""
    exe = os.path.join(a.app, "Contents/MacOS/AntiChat")
    if not os.access(exe, os.X_OK):
        raise RuntimeError(f"{exe} missing: run make build (or a Release build) first")
    os.makedirs(RAW_DIR, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    log = os.path.join(RAW_DIR, f"B1-{stamp}.jsonl")
    raw = os.path.join(RAW_DIR, f"B1-{stamp}-top.txt")
    container = tempfile.mkdtemp(prefix="antichat-perf-")
    seconds = max(10, a.runs * 15)
    env = dict(os.environ, ANTICHAT_PERF_LOG=log)
    p = subprocess.Popen([exe, "-ApplePersistenceIgnoreState", "YES", "-ANTICHAT_DEV_CONTAINER", container, "-SkipOnboarding", "YES"],
                         env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.time() + a.launch_timeout
        while time.time() < deadline and not (os.path.exists(log) and read_log(log, "launchToUsable")):
            if p.poll() is not None:
                raise RuntimeError(f"app exited {p.returncode} before the composer was focused")
            time.sleep(0.5)
        time.sleep(10)  # settle: first-paint work, background index warm-up
        def kids(pid: int) -> list[int]:
            out = sh(["pgrep", "-P", str(pid)])
            return [int(x) for x in out.split() if x.isdigit()]
        pids = [p.pid] + kids(p.pid) + [k for c in kids(p.pid) for k in kids(c)]
        helper = sh(["pgrep", "-n", "AntiChatEngine"])
        if helper.isdigit():
            pids.append(int(helper))
        cmd = ["top", "-l", str(seconds + 1), "-s", "1", "-stats", "pid,power"]
        for pid in sorted(set(pids)):
            cmd += ["-pid", str(pid)]
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=seconds * 2 + 60).stdout
    finally:
        p.terminate()
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
        shutil.rmtree(container, ignore_errors=True)
    open(raw, "w").write(out)
    vals = b1_parse_top(out)
    notes = [f"top -stats pid,power, 1 Hz × {seconds} s over pids {sorted(set(pids))} (app + helper), window open, idle",
             "timers ≤ 1 Hz variant not measured (powermetrics needs sudo, PRD §1.5)"]
    return ProbeResult({None: vals}, label="Energy Impact (top power)", notes=notes, raw=os.path.relpath(raw, ROOT))


def bench_binary() -> str:
    for c in (os.path.join(ROOT, ".build/release/antichat-bench"), os.path.join(ROOT, ".build/arm64-apple-macosx/release/antichat-bench")):
        if os.access(c, os.X_OK):
            return c
    # M7.T03 fallback for old checkouts: the Release build failed in duckdb-swift's variant_shredding.cpp only when
    # built without NDEBUG (D_ASSERT → assert on DEBUG-only helpers); `make bench-release` defines it (M9.T05 prep).
    dbg = os.path.join(ROOT, ".build/out/Products/Debug/antichat-bench")
    if os.access(dbg, os.X_OK) and os.environ.get("ANTICHAT_BENCH_DEBUG_OK") == "1":
        return dbg
    raise RuntimeError("antichat-bench (release) missing: make bench-release")


def probe_chat(a, metric: str) -> ProbeResult:
    cap = TIER_CAP.get(a.tier, a.tier)
    model = a.model or TIER_MODEL.get(a.tier)
    if not model:
        raise RuntimeError(f"no default model for tier {a.tier}")
    fx = os.environ.get("ANTICHAT_FIXTURES", os.path.join(ROOT, "fixtures"))
    pfile = os.path.join(fx, "prompts", "bench-4k-doc.txt" if metric == "C4" else "bench-300tok.txt")
    prompt = open(pfile).read() if os.path.exists(pfile) else None
    os.makedirs(RAW_DIR, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    raw = os.path.join(RAW_DIR, f"{metric}-{a.tier}-{model}-{stamp}.json")
    cmd = [bench_binary(), "chat", "--model", model, "--cap", cap, "--via", "xpc", "--runs", str(a.runs),
           "--json", raw, "--app", a.app, "--max-tokens", "64" if metric == "C4" else "256"]
    if prompt:
        cmd += ["--prompt", prompt]
    t0 = time.time()
    p = run_gpu(cmd, f"{metric} chat")
    if p.returncode != 0 or not os.path.exists(raw):
        raise RuntimeError(f"antichat-bench exit {p.returncode}: {p.stderr[-400:]}")
    rows = json.load(open(raw))["rows"]
    field = CHAT_METRICS[metric]
    div = 1000 if field.endswith("_ms") else 1
    vals = [r[field] / div for r in rows if r.get(field, -1) > 0]
    notes = [f"antichat-bench chat via XPC, cap {cap} (B), warm (1 warmup + 1 discarded), prompt {os.path.basename(pfile) if prompt else 'default'}",
             f"wall {time.time() - t0:.0f} s incl. waiting for the GPU lock",
             "single user message, no system prompt (prefix-cache conditions: antichat-bench prefix, M1.T14)"]
    return ProbeResult({None: vals}, raw=os.path.relpath(raw, ROOT), model=model, notes=notes)


def probe_search(a, metric: str) -> ProbeResult:
    """M7.T03: `antichat-bench search-e2e` (R-254 points / R-248 AC1). Exclusive GPU run (gpu-run.sh timing)."""
    model = a.model or TIER_MODEL.get(a.tier)
    os.makedirs(RAW_DIR, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    raw = os.path.join(RAW_DIR, f"{metric}-{a.tier}-{model}-{stamp}.json")
    cmd = [bench_binary(), "search-e2e", "--tier", a.tier, "--model", model, "--runs", str(a.runs), "--out", raw]
    fx = os.environ.get("ANTICHAT_FIXTURES", os.path.join(ROOT, "fixtures"))
    qfile = os.path.join(fx, "prompts", "search-availability-100.jsonl")
    if metric == "search" and os.path.exists(qfile):
        cmd += ["--queries", qfile]  # AT-254: 20 queries of the availability set; AT-248 c1: the one macOS question
    cache_dir = None
    if metric == "search" and os.environ.get("ANTICHAT_SEARCH_SHARED_CACHE") != "1":
        # M9.T05 (AT-254 cold): every query gets a new empty private page cache; the shared ~/Library/Caches/AntiChat/web
        # (24 h TTL) made the 20 repeated availability queries mostly cache reads.
        cache_dir = tempfile.mkdtemp(prefix="antichat-search-cache-")
        cmd += ["--web-cache-per-run", cache_dir]
    t0 = time.time()
    p = run_gpu(cmd, f"{metric} search-e2e")
    if p.returncode != 0 or not os.path.exists(raw):
        raise RuntimeError(f"antichat-bench search-e2e exit {p.returncode}: {p.stderr[-600:]}")
    rows = json.load(open(raw))["rows"]
    def col(k):
        return [r[k] for r in rows if isinstance(r.get(k), (int, float)) and r[k] >= 0]
    if metric == "search":
        samples = {None: col("ttft_s"), "activity": col("activity_s"), "results": col("results_s"), "fetch_extract": col("fetch_extract_s")}
    else:
        samples = {None: col("complete_s")}
    if cache_dir:
        shutil.rmtree(cache_dir, ignore_errors=True)
    pills = sum(1 for r in rows if r.get("pills", 0) >= 2)
    cache = json.load(open(raw)).get("cache", "shared (bench older than the cache-state field)")
    overlap = sum(r.get("overlap_prev_urls", 0) for r in rows if isinstance(r.get("overlap_prev_urls"), int))
    cache_note = (f"cache state: store fresh per query y (new on-disk database each turn); page cache {cache}"
                  + (" (empty per query: no query can read another's pages)" if cache == "private-fresh-per-run" else
                     " (shared across queries and runs, 24 h TTL: warm hits possible)")
                  + f"; source URLs also cited by an earlier query: {overlap}; URLCache none (NetworkGate sessions); "
                  "DNS and remote CDN caches as for a real user")
    wr = sorted(r["web_results_tokens"] for r in rows if isinstance(r.get("web_results_tokens"), int))
    notes = [f"antichat-bench search-e2e, live engines, {model}, chip on; wall {time.time() - t0:.0f} s incl. the GPU lock",
             f"runs with >= 2 rendered pills: {pills}/{len(rows)}",
             (f"<web_results> prefill per turn (chat tokenizer): p50 {percentile(wr, 50):.0f} tokens, max {wr[-1]} (n {len(wr)}); "
              "a large block is fixed in search.evidence_tokens / EvidenceBudget, never by relaxing the bars")
             if wr else "<web_results> token count: not in this bench's rows (bench older than M9.T05 prep)",
             "activity = harness emission of the search line (the window draws it in that frame or the next: SearchProbe chip leg)",
             cache_note]
    return ProbeResult(samples, raw=os.path.relpath(raw, ROOT), model=model, notes=notes)


def probe_load(a, metric: str) -> ProbeResult:
    """M1 (M2.T12): antichat-bench load — Evict → Warmup → loadState(.ready) through ModelScheduler.ensureLoaded."""
    cap = TIER_CAP.get(a.tier, a.tier)
    model = a.model or TIER_MODEL.get(a.tier)
    if not model:
        raise RuntimeError(f"no default model for tier {a.tier}")
    os.makedirs(RAW_DIR, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    raw = os.path.join(RAW_DIR, f"M1-{a.tier}-{model}-{stamp}.json")
    cmd = [bench_binary(), "load", "--model", model, "--cap", cap, "--runs", str(a.runs), "--json", raw,
           "--app", a.app, "--purge"]
    p = run_gpu(cmd, "M1 load")
    if p.returncode != 0 or not os.path.exists(raw):
        raise RuntimeError(f"antichat-bench load exit {p.returncode}: {p.stderr[-400:]}")
    out = json.load(open(raw))
    vals = [r["ready_s"] for r in out["rows"] if not r["discarded"] and r["ready_s"] > 0]
    weights_gb = out["weights_bytes"] / 1.1 / 1e9  # DevSlots footprint = weights × 1.1
    notes = [f"antichat-bench load via XPC, cap {cap}: Evict all → Warmup → loadState(.ready); run 0 discarded (Metal cache)",
             f"weights {weights_gb:.2f} GB → NFR-M1 band by weights"]
    label = None
    if not out.get("purge"):
        label = "[WARM-CACHE] (no `sudo -n purge`, P-SUDO; 2x RAM read infeasible at 128 GB)"
        notes.append("cold-cache leg not run: permission (sudo purge); file cache warm, as m0.M1.*")
    return ProbeResult({None: vals}, raw=os.path.relpath(raw, ROOT), model=model, notes=notes, label=label,
                       extra={"weights_gb": weights_gb})


def probe_csc(a, metric: str) -> ProbeResult:
    """F7 (M4.T02 step 6): `csc-bench latency` on the 40 CC0 photos (content-free, no private data), full path forced
    (nudity + Vision + MiVOLO per face: the cost when an image is nude), CoreML EP, shipped thresholds."""
    pkg = os.path.join(ROOT, "Packages/ChildSafetyCheck")
    subprocess.run(["swift", "build", "-c", "release", "--package-path", pkg, "--disable-keychain", "--product", "csc-bench"],
                   check=True, stdout=subprocess.DEVNULL)
    bindir = subprocess.run(["swift", "build", "-c", "release", "--package-path", pkg, "--disable-keychain", "--show-bin-path"],
                            check=True, capture_output=True, text=True).stdout.strip()
    fixtures = os.environ.get("ANTICHAT_FIXTURES", os.path.join(ROOT, "fixtures"))
    os.makedirs(RAW_DIR, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    raw = os.path.join(RAW_DIR, f"F7-{a.tier}-{stamp}.json")
    cmd = [os.path.join(bindir, "csc-bench"), "latency", "--images", os.path.join(fixtures, "images/photos-cc0"),
                    "--limit", "40", "--runs", str(max(3, a.runs // 4)), "--ep", "coreml", "--out", raw]
    p = run_gpu(cmd, "F7 csc-bench")
    if p.returncode != 0 or not os.path.exists(raw):
        raise RuntimeError(f"csc-bench latency exit {p.returncode}: {p.stderr[-400:]}")
    out = json.load(open(raw))
    notes = [f"csc-bench latency: {out['images']} CC0 photos at {out['image_px']} × {out['runs_per_image']} runs, full path forced, "
             f"CoreML EP; as-used (SFW, nudity stage only) p95 {out['as_used_sfw_ms']['p95']} ms",
             f"process footprint after load {out['footprint_after_mb']:.0f} MB (peak {out['peak_footprint_mb']:.0f} MB); "
             f"no memory-limit API: the T1 cap is checked against B by footprint (S-8)",
             "measured on this Mac (S4); T1-chip latency is [SCALED] (S-8)"]
    return ProbeResult({None: out["full_path_samples_ms"]}, raw=os.path.relpath(raw, ROOT), notes=notes,
                       extra={"model_load_s": out["model_load_s"], "thresholds": out["thresholds"]})


def probe_u3(a, metric: str) -> ProbeResult:
    """NFR-U3 (M9.T05): `antichat-bench u3` — evict everything, send one turn through TurnController; status = the
    `modelLoading(true)` update (the status line's "Loading model…"), reply = first token vs NFR-M1 band + NFR-C1."""
    cap = TIER_CAP.get(a.tier, a.tier)
    model = a.model or TIER_MODEL.get(a.tier)
    if not model:
        raise RuntimeError(f"no default model for tier {a.tier}")
    os.makedirs(RAW_DIR, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    raw = os.path.join(RAW_DIR, f"U3-{a.tier}-{model}-{stamp}.json")
    p = run_gpu([bench_binary(), "u3", "--model", model, "--cap", cap, "--runs", str(a.runs), "--json", raw, "--purge"], "U3 u3")
    if p.returncode != 0 or not os.path.exists(raw):
        raise RuntimeError(f"antichat-bench u3 exit {p.returncode}: {p.stderr[-400:]}")
    out = json.load(open(raw))
    rows = [r for r in out["rows"] if not r["discarded"]]
    targets = json.load(open(TARGETS))["metrics"]
    weights_gb = out["weights_bytes"] / 1.1 / 1e9
    band = next((b["value"] for b in targets["M1"]["tiers"]["default"][0]["by_weights_gb"] if weights_gb <= b["max_weights_gb"]), None)
    c1 = next((c["value"] for c in (targets["C1"]["tiers"].get(tier_family(a.tier)) or []) if c["stat"] == "p50"), None)
    budget = (band or 0) + (c1 or 0) if band is not None and c1 is not None else None
    ok = [r for r in rows if r["status_s"] >= 0]
    samples = {None: [r["status_s"] for r in ok], "ttft": [r["ttft_s"] for r in rows if r["ttft_s"] >= 0],
               "accepted": [r["accepted_s"] for r in rows if r["accepted_s"] >= 0]}
    if budget is not None:
        samples["reply_over_budget"] = [r["ttft_s"] - budget for r in rows if r["ttft_s"] >= 0]
    notes = [f"antichat-bench u3 via XPC, cap {cap}: evict all → send → status / first token; run 0 discarded",
             f"weights {weights_gb:.2f} GB → NFR-M1 band {band} s; NFR-C1 p50 bar {c1} s at {tier_family(a.tier)} → reply budget {budget} s",
             f"{len(rows) - len(ok)} run(s) showed no loading status (model already resident?)",
             "the app's ReadinessQueue path (status before the engine reports) is unit-tested, not timed here"]
    label = None if out.get("purge") else "[WARM-CACHE] (no `sudo -n purge`, P-SUDO)"
    return ProbeResult(samples, raw=os.path.relpath(raw, ROOT), model=model, notes=notes, label=label, extra={"weights_gb": weights_gb})


# M2.T15 NFR-C7: (normal, evil, cap, warm) per tier. T3: the pair (2 × ~22 GB) fits warm only at the T3-64 cap
# (B 48 GB); at T3-48 (B 36 GB) it does not fit, so that switch is cold (E.2.7 "warm if fits").
C7_PAIRS = {"T1": ("chat-9b-q4", "llama:evil-9b", "T1", False), "T3": ("chat-35b-q4", "evil-35b-q4", "T3-64", True),
            "T3-48": ("chat-35b-q4", "evil-35b-q4", "T3-48", True), "T3-64": ("chat-35b-q4", "evil-35b-q4", "T3-64", True)}


def probe_modeswap(a, metric: str) -> ProbeResult:
    """C7 (M2.T15): antichat-bench modeswap — Normal turn, then a new Evil chat → first token."""
    if a.tier not in C7_PAIRS:
        raise RuntimeError(f"C7: no Normal/Evil pair for tier {a.tier} ({', '.join(C7_PAIRS)})")
    normal, evil, cap, warm = C7_PAIRS[a.tier]
    os.makedirs(RAW_DIR, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    raw = os.path.join(RAW_DIR, f"C7-{a.tier}-{stamp}.json")
    cmd = [bench_binary(), "modeswap", "--normal", normal, "--evil", evil, "--cap", cap, "--runs", str(a.runs),
           "--json", raw, "--app", a.app] + (["--warm"] if warm else [])
    p = run_gpu(cmd, "C7 modeswap")
    if p.returncode != 0 or not os.path.exists(raw):
        raise RuntimeError(f"antichat-bench modeswap exit {p.returncode}: {p.stderr[-400:]}")
    out = json.load(open(raw))
    rows = [r for r in out["rows"] if not r["discarded"] and r["switch_to_first_token_s"] > 0]
    vals = [r["switch_to_first_token_s"] for r in rows]
    cold = sum(1 for r in rows if r["cold"])
    weights_gb = out["evil_bytes"] / 1.1 / 1e9
    notes = [f"antichat-bench modeswap via XPC, cap {cap}, warmSecondVariant={warm}: Normal turn ({normal}) → new Evil chat "
             f"({out['evil']}) → first content delta; run 0 discarded; {cold}/{len(rows)} measured switches loaded a model",
             f"Evil weights {weights_gb:.2f} GB → NFR-M1 band by weights (cold bar = band + NFR-C1)",
             "file cache warm (no `sudo -n purge`, P-SUDO) [WARM-CACHE]"]
    return ProbeResult({None: vals}, raw=os.path.relpath(raw, ROOT), model=f"{normal}->{out['evil']}", notes=notes,
                       label="[WARM-CACHE]", extra={"weights_gb": weights_gb})


def probe_soak(a, metric: str) -> ProbeResult:
    """R1 (M2.T13): the mini-soak sampler (tools/soak/mini-soak.sh, 1 Hz phys_footprint of helper + children)."""
    path = os.path.join(ROOT, "build/at/AT-206", f"soak-{a.tier}.csv")
    meta = os.path.join(ROOT, "build/at/AT-206", f"soak-{a.tier}.json")
    if not os.path.exists(path):
        raise RuntimeError(f"{path} missing: run tools/soak/mini-soak.sh --tier {a.tier} first")
    vals = []
    for line in open(path).read().splitlines()[1:]:
        f = line.split(",")
        if len(f) >= 3 and f[2].isdigit():
            vals.append(int(f[2]) / 1e9)
    if not vals:
        raise RuntimeError(f"{path}: no samples")
    m = json.load(open(meta)) if os.path.exists(meta) else {}
    notes = [f"mini-soak {m.get('minutes', '?')} min at cap {a.tier}: {len(vals)} 1 Hz samples of phys_footprint(helper + children) "
             f"(unified memory: Metal allocations included); turns {m.get('turns')}, image jobs {m.get('image_jobs')}, "
             f"evil chats {m.get('evil_chats')}", "ScriptedImageEngine media (real footprint as MTLBuffers); re-run in M3/M4 with real voice/image"]
    return ProbeResult({None: vals}, raw=os.path.relpath(path, ROOT), model=m.get("chat"), notes=notes)


VOICE_BENCH = {"V6": ("dictation", "v6_s"), "V7": ("dictation", "v7_s"), "V10": ("dictation-warm", "v10_s")}


def probe_voice(a, metric: str) -> ProbeResult:
    """M3.T03 V6/V7/V10: the app's `-Bench dictation|dictation-warm` against its helper (ScriptedVoice input, mode
    inject [IN-PIPELINE]; ScriptedVoice exists in DEBUG builds only, so the app is the Debug build)."""
    cmd_name, field = VOICE_BENCH[metric]
    exe = os.path.join(a.app, "Contents/MacOS/AntiChat")
    if not os.access(exe, os.X_OK):
        raise RuntimeError(f"{exe} missing: make build")
    fx = os.environ.get("ANTICHAT_FIXTURES", os.path.join(ROOT, "fixtures"))
    os.makedirs(RAW_DIR, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    raw = os.path.join(RAW_DIR, f"{metric}-{a.tier}-{stamp}.jsonl")
    cmd = [exe, "-Bench", cmd_name, "--runs", str(a.runs), "--raw", raw, "--tier-cap", TIER_CAP.get(a.tier, a.tier),
                  "--input", os.path.join(fx, "audio/dictation")]
    t0 = time.time()
    reuse = os.environ.get("VOICE_RAW")  # V6 and V7 come from the same `-Bench dictation` run: VOICE_RAW=<raw.jsonl>
    if reuse:
        raw = os.path.abspath(reuse)
    else:
        p = run_gpu(cmd, f"-Bench {cmd_name}")
        if p.returncode != 0 or not os.path.exists(raw):
            raise RuntimeError(f"-Bench {cmd_name} exit {p.returncode}: {(p.stderr or p.stdout)[-400:]}")
    rows = [json.loads(l) for l in open(raw) if l.strip()]
    runs = [r for r in rows if r.get("kind") == "run"]
    errors = [r["error"] for r in runs if r.get("error")]
    vals = [r[field] * (1000 if metric == "V10" else 1) for r in runs if isinstance(r.get(field), (int, float)) and r[field] >= 0]
    notes = [f"mode inject [IN-PIPELINE]: ScriptedVoice (fixture WAVs at real-time pace) in the helper, no device/driver latency",
             f"wall {time.time() - t0:.0f} s incl. waiting for the GPU lock"]
    if metric in ("V6", "V7"):
        w = sum(r.get("word_errors", 0) for r in runs)
        n = sum(r.get("words", 0) for r in runs)
        notes.append(f"partials: {runs[0].get('partials') if runs else '-'} via {rows[0].get('partials', '?') if rows else '?'}; "
                     f"WER of the finals {100 * w / max(1, n):.2f} % over {n} words")
        if metric == "V6":
            notes.append("speech onset = capture start (first listening event) + 0.3 s script offset + the fixture's first frame ≥ −40 dBFS")
        else:
            notes.append("stop = the ■ DictationStop send, 0.3 s after the utterance ends; final = finalTranscript arrival in the app process")
    else:
        notes.append("hover hint + plain warm-up of `stt` after an evict: Core ML built inside the scheduler load; helper stays up (cold model)")
    if errors:
        notes.append(f"{len(errors)} run(s) with errors: {errors[:2]}")
    if reuse:
        notes.append(f"values read from the {cmd_name} run {os.path.basename(raw)} (same run as its sibling metric)")
    return ProbeResult({None: vals}, method="measured", label="inject [IN-PIPELINE]", raw=os.path.relpath(raw, ROOT),
                       model="stt (+stt-eou)" if metric != "V10" else "stt", notes=notes)


def probe_v5(a, metric: str) -> ProbeResult:
    """M3.T03 V5: mic click → DictationBar drawn, in-process (AntiChatUI DictationIndicatorProbeTests; swift test, Debug)."""
    os.makedirs(RAW_DIR, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    raw = os.path.join(RAW_DIR, f"V5-{a.tier}-{stamp}.json")
    env = dict(os.environ, ANTICHAT_V5_OUT=raw, ANTICHAT_V5_RUNS=str(a.runs))
    p = subprocess.run(["swift", "test", "--disable-keychain", "--force-resolved-versions", "--filter", "DictationIndicatorProbeTests"],
                       cwd=ROOT, env=env, capture_output=True, text=True)
    if p.returncode != 0 or not os.path.exists(raw):
        raise RuntimeError(f"DictationIndicatorProbeTests exit {p.returncode}: {(p.stdout + p.stderr)[-400:]}")
    vals = json.load(open(raw))["v5_ms"]
    return ProbeResult({None: vals}, method="measured", label="in-process", raw=os.path.relpath(raw, ROOT),
                       notes=["ComposerView hosted in a window: startDictation() → next layout + display pass with the DictationBar",
                              "Debug test build; the helper stand-in never answers (the bar does not wait for capture); vsync wait excluded"])


AMENDMENTS = os.path.join(ROOT, "docs/PRD-AMENDMENTS.md")


def accepted_v9(path: str = AMENDMENTS) -> dict[str, float]:
    """A-M3-06 (owner decision 2026-11-05): the per-language NFR-V9 misses accepted, read from the amendment row itself
    ("accept the AT-284 / NFR-V9 misses for ar (11.42 %) and zh (10.60 %)") so the gate never holds a drifting copy."""
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return {}
    row = next((l for l in text.splitlines() if l.startswith("| A-M3-06 |")), "")
    m = re.search(r"accept the AT-284 / NFR-V9 misses for (.*?);", row)
    return {lang: float(v) for lang, v in re.findall(r"\b([a-z]{2}) \(([\d.]+) ?%\)", m.group(1))} if m else {}


def probe_v9(a, metric: str) -> ProbeResult:
    """M3.T05 V9: per-language error rate of the routed recogniser (`auto`), from WERFixtureTests' wer.json scored by
    tools/voice/wer.py (WER; CER for ja / zh, A-M3-02). One sample per language; the gate is the worst language."""
    path = os.environ.get("V9_WER") or os.path.join(ROOT, "build/at/AT-284/wer.json")
    if not os.path.exists(path):
        raise RuntimeError(f"{path} missing: run WERFixtureTests (ANTICHAT_VOICE_IT=1)")
    subprocess.run(["python3", "-I", os.path.join(ROOT, "tools/voice/wer.py"), "--in", path], capture_output=True, text=True)
    scores = json.load(open(path))["scores"]["auto"]
    accepted = accepted_v9()
    # Primary entry: every language without an accepted miss, against the NFR-V9 bar. Each accepted language is its own
    # variant, judged against the value A-M3-06 accepted (never looser than the measured value the owner accepted).
    samples: dict[str | None, list[float]] = {None: [100 * s["rate"] for lang, s in sorted(scores.items()) if lang not in accepted]}
    for lang in sorted(accepted):
        if lang in scores:
            samples[lang] = [100 * scores[lang]["rate"]]
    notes = [f"{lang} {s['metric'].upper()} {100 * s['rate']:.2f} % (n {s['n']}; {s['engines']})"
             + (f" — accepted ≤ {accepted[lang]:.2f} % (A-M3-06)" if lang in accepted else "") for lang, s in sorted(scores.items())]
    return ProbeResult(samples, method="measured", label="routed auto", raw=os.path.relpath(path, ROOT), model="stt + stt-multi",
                       notes=notes + ["accuracy only (gpu-run shared); LibriSpeech test-clean (en) + FLEURS (de, ja, zh, ar)"],
                       extra={"accepted_max": {lang: v for lang, v in accepted.items() if lang in scores},
                              "accepted_by": "A-M3-06"})


def probe_v8(a, metric: str) -> ProbeResult:
    """M3.T07 V8: read aloud click → first audio (s) with the real Kokoro, warm, 20 runs × {1, 3 sentences}, from
    ReadAloudLatencyTests' v8.json (run under gpu-run timing; mode [IN-PIPELINE], silent output clock)."""
    path = os.environ.get("V8_JSON") or os.path.join(ROOT, "build/at/AT-054/v8.json")
    if not os.path.exists(path):
        raise RuntimeError(f"{path} missing: run ReadAloudLatencyTests (ANTICHAT_VOICE_IT=1 ANTICHAT_V8=1)")
    d = json.load(open(path))
    vals = [v for k in sorted(d["v8_s"]) for v in d["v8_s"][k]]
    notes = [f"{k} sentence(s): p50 {sorted(v)[len(v) // 2]:.3f} s over {len(v)} runs" for k, v in sorted(d["v8_s"].items())]
    return ProbeResult({None: vals}, method="measured", label="inject [IN-PIPELINE]", raw=os.path.relpath(path, ROOT), model="tts",
                       notes=notes + [f"load {d.get('load', '?'):.1f}" if isinstance(d.get("load"), (int, float)) else "load ?",
                                      "TTSService → SpeakableText → ClauseChunker → KokoroBackend; first chunk's PCM handed to the output"])


def probe_v11(a, metric: str) -> ProbeResult:
    """M3.T06 V11: audio-file transcription speed (× real time) of FileTranscriber on fixtures/audio/long-file (60 min),
    n = 3 (A-M3-03), from FileTranscriberRealTests/v11SixtyMinutes' v11.json (run under gpu-run timing)."""
    path = os.environ.get("V11_JSON") or os.path.join(ROOT, "build/at/AT-056/v11.json")
    if not os.path.exists(path):
        raise RuntimeError(f"{path} missing: run FileTranscriberRealTests/v11SixtyMinutes (ANTICHAT_VOICE_IT=1 ANTICHAT_V11=1)")
    d = json.load(open(path))
    vals = [r["realtime_x"] for r in d["runs"]]
    notes = [f"run {i + 1}: {r['seconds']:.1f} s for {r['audio_s']:.0f} s audio ({r['realtime_x']:.1f}×), load {r.get('load', '?')}"
             for i, r in enumerate(d["runs"])]
    return ProbeResult({None: vals}, method="measured", label="FileTranscriber (Parakeet disk-backed)", raw=os.path.relpath(path, ROOT),
                       model="stt", notes=notes + ["n = 3 for a 60-min file (A-M3-03); resample + route + transcribe, helper code in-process"])


def probe_turn(a, metric: str) -> ProbeResult:
    """M3.T09: ingest the real-model, in-pipeline fixture runs produced under gpu-run.sh."""
    base = os.path.join(ROOT, "build/at/AT-283")
    if metric == "V4":
        samples = {}
        notes = []
        for bed in ("clean", "cafe", "fan", "keyboard"):
            path = os.path.join(base, "turn-split.json" if bed == "clean" else f"turn-split-{bed}.json")
            if not os.path.exists(path):
                raise RuntimeError(f"{path} missing: run TurnSplitFixtureTests under gpu-run.sh shared")
            d = json.load(open(path))
            if d.get("n") != 50:
                raise RuntimeError(f"{path}: expected 50 utterances")
            variant = None if bed == "clean" else bed
            samples[variant] = [float(d["false_split_percent"])]
            notes.append(f"{bed}: {d['false_splits']}/50 false splits ({d['false_split_percent']:.2f}%), loadavg {d.get('loadavg')}")
        return ProbeResult(samples, method="measured", label="inject [IN-PIPELINE]",
                           raw=os.path.relpath(os.path.join(base, "turn-split.json"), ROOT),
                           model="vad + turn-coreml", notes=notes)
    path = os.path.join(base, "eos.json")
    if not os.path.exists(path):
        raise RuntimeError(f"{path} missing: run TurnSplitFixtureTests/eagerSTTLatency under gpu-run.sh timing")
    d = json.load(open(path))
    vals = d.get("turn_to_final_ms", [])
    if not vals:
        raise RuntimeError(f"{path}: no V283 samples")
    voiced = d.get("last_voiced_to_final_ms", [])
    notes = [f"turnEnded → final p50 {d.get('turn_to_final_p50_ms')} ms; n {len(vals)}",
             f"lastVoicedFrame → final p50 {percentile(sorted(voiced), 50) if voiced else None} ms",
             f"loadavg before {d.get('loadavg_before')}, after {d.get('loadavg_after')}",
             "A-M3-04: the ≤300 ms gate starts at voice.turnEnded; last-voiced latency is reported separately"]
    return ProbeResult({None: vals}, method="measured", label="inject [IN-PIPELINE]",
                       raw=os.path.relpath(path, ROOT), model="vad + turn-coreml + stt + stt-eou", notes=notes)


def probe_conversation(a, metric: str) -> ProbeResult:
    """M3.T11 V1 / V1b / V2 (and V283 from the same run): the app's `-Bench voice-session` against its helper — the
    VoiceSession with ScriptedVoice input (dictation/q01…q20), chat + STT + TTS resident, mode inject [IN-PIPELINE].
    `VOICE_RAW=<raw.jsonl>` re-reads an earlier run (V1, V1b and V2 come from one run). M3.T10 V3: ingests
    build/at/AT-282/v3.json (BargeInFixtureTests)."""
    if metric == "V3":
        path = os.path.join(ROOT, "build/at/AT-282/v3.json")
        if not os.path.exists(path):
            raise RuntimeError(f"{path} missing: run BargeInFixtureTests under gpu-run.sh timing")
        d = json.load(open(path))
        return ProbeResult({None: d["onset_to_silent_ms"], "cancel": d["onset_to_cancel_ms"]}, method="measured",
                           label="inject [IN-PIPELINE]", raw=os.path.relpath(path, ROOT), model="vad-files + tts + stt",
                           notes=[d.get("onset", ""), d.get("cancel", ""), f"loadavg {d.get('loadavg')}",
                                  "TTS silent = the output paused on the first voiced frame (BargeInDetector candidate)"])
    exe = os.path.join(a.app, "Contents/MacOS/AntiChat")
    reuse = os.environ.get("VOICE_RAW")
    if reuse:
        raw = os.path.abspath(reuse)
    else:
        if not os.access(exe, os.X_OK):
            raise RuntimeError(f"{exe} missing: make build")
        fx = os.environ.get("ANTICHAT_FIXTURES", os.path.join(ROOT, "fixtures"))
        os.makedirs(RAW_DIR, exist_ok=True)
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        raw = os.path.join(RAW_DIR, f"V1-{a.tier}-{stamp}.jsonl")
        # T3 / T3-48 → chat-35b-q4 at the T3-48 cap (the bench refuses a cap it does not know, e.g. bare "T3").
        chat = a.model or {"T0": "chat-2b", "T1": "chat-9b-q4", "T2": "chat-9b-q4", "T3": "chat-35b-q4"}.get(tier_family(a.tier), "chat-9b-q4")
        cmd = [exe, "-Bench", "voice-session", "--runs", str(a.runs), "--raw", raw, "--tier-cap", TIER_CAP.get(a.tier, a.tier),
                      "--model", chat, "--input", os.path.join(fx, "audio/dictation")]
        p = run_gpu(cmd, "-Bench voice-session")
        if p.returncode != 0 or not os.path.exists(raw):
            raise RuntimeError(f"-Bench voice-session exit {p.returncode}: {(p.stderr or p.stdout)[-400:]}")
    rows = [json.loads(l) for l in open(raw) if l.strip()]
    runs = [r for r in rows if r.get("kind") == "run"]
    errors = [r["error"] for r in runs if r.get("error")]
    notes = ["mode inject [IN-PIPELINE]: ScriptedVoice in the helper's VoiceSession, VPIO bypassed, silent output clock",
             f"chat {runs[0].get('chat') if runs else '?'}; loadavg first/last {runs[0].get('loadavg') if runs else '-'} / "
             f"{runs[-1].get('loadavg') if runs else '-'}"]
    if errors:
        notes.append(f"{len(errors)} run(s) with errors: {errors[:2]}")
    if metric in ("V1", "V1b"):
        vals = [r["v1_ms"] / 1000 for r in runs if isinstance(r.get("v1_ms"), (int, float))]
        samples = {None: vals}
    elif metric == "V283_EOS_FINAL":
        samples = {None: [r["turn_to_final_ms"] for r in runs if r.get("turn_to_final_ms", -1) >= 0]}
    else:  # V2: each stage as a variant
        samples = {}
        for st in ("endpointing", "stt_final", "llm_ttft", "first_clause", "tts_first_chunk", "audio_out"):
            samples[st] = [r["stages_ms"][st] for r in runs if isinstance(r.get("stages_ms", {}).get(st), (int, float))]
    return ProbeResult(samples, method="measured", label="inject [IN-PIPELINE]", raw=os.path.relpath(raw, ROOT),
                       model="chat + stt + stt-eou + vad-files + turn-coreml + tts", notes=notes)


def app_exe(a) -> str:
    exe = os.path.join(a.app, "Contents/MacOS/AntiChat")
    if not os.access(exe, os.X_OK):
        raise RuntimeError(f"{exe} missing: make build")
    return exe


def bench_rows(raw: str) -> list[dict]:
    return [json.loads(l) for l in open(raw) if l.strip().startswith("{")]


def image_turn_pairs(log: str) -> tuple[list[float], list[float]]:
    """M9.T05 (AT-236 AC3): per image turn, its `imageTurn` interval (TurnController, the app process) and the
    `imageGen` interval the app's MediaJobQueue marked for its job (meta source=queue; a helper-side `imageGen` record,
    if the helper ever logs, is ignored). Turns run one after another, so each turn pairs with the newest unused
    imageGen that ended before it. Returns (turn seconds, gen seconds) per pair, in order."""
    rows = [json.loads(l) for l in open(log) if l.strip().startswith("{")]
    gens = sorted((r for r in rows if r.get("name") == "imageGen" and r.get("kind") == "interval"
                   and (r.get("meta") or {}).get("source") == "queue"), key=lambda r: r["end_ns"])
    turns = sorted((r for r in rows if r.get("name") == "imageTurn" and r.get("kind") == "interval"), key=lambda r: r["end_ns"])
    out_t, out_g, used = [], [], set()
    for t in turns:
        cand = [i for i, g in enumerate(gens) if i not in used and g["end_ns"] <= t["end_ns"]]
        if not cand:
            continue
        i = cand[-1]
        used.add(i)
        out_t.append(t["dur_ns"] / 1e9)
        out_g.append(gens[i]["dur_ns"] / 1e9)
    return out_t, out_g


def probe_image_turn(a, metric: str) -> ProbeResult:
    """IMAGE_TURN_OVERHEAD (M9.T05, AT-236 AC3): `AntiChat -Bench image-turn` at the tier cap (TurnController + the
    app's MediaJobQueue / ImageTools over XPC, Image chip → create_image, real klein set, gate, artifact, templated
    caption) with ANTICHAT_PERF_LOG; overhead = imageTurn − imageGen per turn. `--from-log` re-reads such a log."""
    if a.from_log:
        log, discard, raw = a.from_log, 0, None
    else:
        os.makedirs(RAW_DIR, exist_ok=True)
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        log = os.path.join(RAW_DIR, f"IMAGE_TURN_OVERHEAD-{a.tier}-{stamp}-perf.jsonl")
        raw = os.path.join(RAW_DIR, f"IMAGE_TURN_OVERHEAD-{a.tier}-{stamp}.jsonl")
        fx = os.environ.get("ANTICHAT_FIXTURES", os.path.join(ROOT, "fixtures"))
        cmd = [app_exe(a), "-Bench", "image-turn", "--tier-cap", TIER_CAP.get(a.tier, a.tier), "--runs", str(a.runs),
               "--prompts", os.path.join(fx, "images/prompts-50.json"), "--raw", raw]
        if a.model:
            cmd += ["--model", a.model]
        os.environ["ANTICHAT_PERF_LOG"] = log  # inherited by the app (the helper is started by launchd: not by it)
        try:
            p = run_gpu(cmd, "-Bench image-turn")
        finally:
            os.environ.pop("ANTICHAT_PERF_LOG", None)
        if p.returncode != 0 or not os.path.exists(log):
            raise RuntimeError(f"-Bench image-turn exit {p.returncode}: {(p.stderr or p.stdout)[-600:]}")
        discard = 1  # run 0: Metal pipeline cache + first sd-server start
    turns, gens = image_turn_pairs(log)
    rows = bench_rows(raw) if raw and os.path.exists(raw) else []
    turns, gens = turns[discard:], gens[discard:]
    over = [t - g for t, g in zip(turns, gens)]
    done = sum(1 for r in rows if r.get("kind") == "run" and r.get("images_done", 0) > 0)
    notes = ["imageTurn = TurnController send → the reply written (templated caption on T0–T2); imageGen = the helper's "
             "image.loadStart (sd-server start or reuse) → image.final, marked by the app's MediaJobQueue",
             f"{len(over)} paired turns (run 0 discarded: Metal cache / first sd-server start)" if discard else f"{len(over)} paired turns",
             "overhead = chat model's tool call + step-aside unload + queue + gate + artifact save + caption"]
    if rows:
        notes.append(f"bench rows: {done}/{sum(1 for r in rows if r.get('kind') == 'run')} turns stored an image; "
                     f"caption {rows[-1].get('caption', '')!r}; chat {rows[-1].get('chat')}")
    return ProbeResult({None: over, "turn": turns, "gen": gens}, label="app path (TurnController + MediaJobQueue)",
                       raw=os.path.relpath(os.path.abspath(log), ROOT), model="chat + img-klein", notes=notes)


def video_rows_gate(rows: list[dict]) -> tuple[dict, list[str]]:
    """F7_VIDEO: per completed `-Bench video` row, the `videoGate` note (MediaJobOutputs.noteGateTiming) over final_s."""
    samples: dict = {None: [], "previews": [], "final": [], "final_wall": []}
    notes = []
    for r in rows:
        if r.get("status") != "completed" or not isinstance(r.get("final_s"), (int, float)) or r["final_s"] <= 0:
            notes.append(f"run {r.get('run')}: status {r.get('status')} (not counted)")
            continue
        gate = next((n for n in r.get("notes", []) if n.get("action") == "videoGate"), None)
        if gate is None:
            notes.append(f"run {r.get('run')}: no videoGate note (app/helper older than M9.T05)")
            continue
        job = r["final_s"]
        samples[None].append(100 * float(gate["gate_s"]) / job)
        samples["previews"].append(100 * float(gate["preview_s"]) / job)
        samples["final"].append(100 * float(gate["final_s"]) / job)
        samples["final_wall"].append(100 * float(gate["final_wall_s"]) / job)
        notes.append(f"run {r.get('run')}: {r.get('width')}x{r.get('height')} {r.get('frames')} f, job {job:.1f} s, gate "
                     f"{float(gate['gate_s']):.2f} s ({gate.get('preview_checks')} preview checks {float(gate['preview_s']):.2f} s, "
                     f"final {float(gate['final_s']):.2f} s after the last frame, {float(gate['final_wall_s']):.2f} s wall, "
                     f"streamed {gate.get('streamed')})" + video_preview_note(r, gate))
    return samples, notes


def video_preview_note(r: dict, gate: dict) -> str:
    """fix/t05-video-t4 (VID2): how many previews passed the gate and reached the app (`preview_shown`, `preview_events`)
    and when the first one did, against the clip (`first_preview_s` vs `final_s`). Empty for rows without the keys."""
    shown = gate.get("preview_shown")
    if shown is None and "preview_events" not in r:
        return ""
    first = r.get("first_preview_s")
    first_s = f"{float(first):.1f} s (step {r.get('first_preview_step', '?')}), {float(r['final_s']) - float(first):.1f} s before the video" \
        if isinstance(first, (int, float)) and first >= 0 else "none"
    return f"; previews shown {shown if shown is not None else '?'} (app events {r.get('preview_events', '?')}), first {first_s}"


def video_tier_rule(rows: list[dict], tier: str) -> list[str]:
    """fix/t05-video: `-Bench video` rows record the tier rule the helper ran under (`low_tier`, the app's rule for
    the cap: T0–T2 true). A T3/T4 measurement taken under the low-tier rule measures the T0–T2 gate path (no detector
    preload, no streamed final check), so it is refused, not reported. Rows without the key (older builds) pass with
    a note. Returns notes; raises RuntimeError on a mismatch."""
    want = tier_family(tier) in ("T0", "T1", "T2")
    bad = [r.get("run") for r in rows if "low_tier" in r and bool(r["low_tier"]) != want]
    if bad:
        raise RuntimeError(f"F7_VIDEO {tier}: rows {bad} ran with low_tier={not want}, the app runs {tier} with "
                           f"low_tier={want} (rebuild the perf app: -Bench video sets the tier rule since fix/t05-video)")
    if rows and any("low_tier" not in r for r in rows):
        return ["rows without low_tier (app older than fix/t05-video): the tier rule is unknown (bench default: low tier)"]
    return [f"tier rule: low_tier={want} (as the app at {tier})"] if rows else []


def probe_f7_video(a, metric: str) -> ProbeResult:
    """F7_VIDEO (M9.T05, NFR-F7 video leg): the gate's time per video job from `-Bench video` rows. `VIDEO_RAW=<jsonl>`
    reads rows written elsewhere (the T4 default job of video.T4); else runs the tier's job: T4 = the app's own
    `--installed` default (VIDEO_INSTALLED, default build/perf/t4models), T3 = 480p × 73 f vid-5b at the T3-48 cap."""
    reuse = os.environ.get("VIDEO_RAW")
    if reuse:
        raw = os.path.abspath(reuse)
    else:
        os.makedirs(RAW_DIR, exist_ok=True)
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        raw = os.path.join(RAW_DIR, f"F7_VIDEO-{a.tier}-{stamp}.jsonl")
        out = os.path.join(RAW_DIR, f"F7_VIDEO-{a.tier}-{stamp}-out")
        runtime = os.environ.get("RUNTIME") or os.path.join(ROOT, "build/runtimes/video-runtime")
        cmd = [app_exe(a), "-Bench", "video", "--runtime", runtime, "--runs", str(a.runs), "--out-dir", out, "--raw", raw]
        if tier_family(a.tier) == "T4":
            cmd += ["--installed", os.environ.get("VIDEO_INSTALLED") or os.path.join(ROOT, "build/perf/t4models")]
        else:
            cmd += ["--mode", "t2v", "--res", "480p", "--frames", "73", "--tier-cap", TIER_CAP.get(a.tier, a.tier)]
        p = run_gpu(cmd, "-Bench video")
        if p.returncode != 0 or not os.path.exists(raw):
            raise RuntimeError(f"-Bench video exit {p.returncode}: {(p.stderr or p.stdout)[-600:]}")
        shutil.rmtree(out, ignore_errors=True)  # benign clips, not needed after the row is written
    rows = bench_rows(raw)
    rule = video_tier_rule(rows, a.tier)
    samples, notes = video_rows_gate(rows)
    notes += rule
    notes.append("gate time = preview checks (inline, the step waits) + the final check after the last frame (streamed: "
                 "overlaps the decode); generation time = request → MP4 (final_s)")
    return ProbeResult(samples, label="app path (-Bench video, gate on)", raw=os.path.relpath(raw, ROOT), model="vid-5b", notes=notes)


VOICE_TIER_CHAT = {"T0": "chat-2b", "T1": "chat-9b-q4", "T2": "chat-9b-q4", "T3": "chat-35b-q4", "T4": "chat-35b-q4"}


def probe_v8_tier(a, metric: str) -> ProbeResult:
    """V8 (M9.T05): `AntiChat -Bench read-aloud --tier-cap <cap>`: the helper at the tier's budget B with the tier's chat
    model resident, Kokoro read aloud click → first audio (silent clock), 1- and 3-sentence replies, warm (run 0 of
    each discarded). `V8_JSON=<v8.json>` ingests ReadAloudLatencyTests instead (in-process, no cap)."""
    if os.environ.get("V8_JSON"):
        return probe_v8(a, metric)
    os.makedirs(RAW_DIR, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    raw = os.path.join(RAW_DIR, f"V8-{a.tier}-{stamp}.jsonl")
    cap = TIER_CAP.get(a.tier, a.tier)
    chat = a.model or VOICE_TIER_CHAT.get(tier_family(a.tier), "chat-9b-q4")
    p = run_gpu([app_exe(a), "-Bench", "read-aloud", "--tier-cap", cap, "--model", chat, "--runs", str(a.runs), "--raw", raw], "-Bench read-aloud")
    if p.returncode != 0 or not os.path.exists(raw):
        raise RuntimeError(f"-Bench read-aloud exit {p.returncode}: {(p.stderr or p.stdout)[-600:]}")
    runs = [r for r in bench_rows(raw) if r.get("kind") == "run"]
    vals = [r["v8_s"] for r in runs if isinstance(r.get("v8_s"), (int, float)) and r["v8_s"] >= 0]
    errors = [r["error"] for r in runs if r.get("error")]
    load_s = runs[0].get("chat_load_s") if runs else None
    notes = [f"cap {cap} (B {loadmod_b(cap)}), {chat} resident (warm-up {load_s if load_s is None else round(load_s, 2)} s); "
             "Kokoro `tts` through the helper's TTSService, silent clock [IN-PIPELINE]"]
    for t in ("one", "three"):
        xs = sorted(r["v8_s"] for r in runs if r.get("text") == t and r.get("v8_s", -1) >= 0)
        if xs:
            notes.append(f"{t} sentence(s): p50 {percentile(xs, 50):.3f} s over {len(xs)} runs")
    if errors:
        notes.append(f"{len(errors)} run(s) with errors: {errors[:2]}")
    return ProbeResult({None: vals}, method="measured", label="inject [IN-PIPELINE]", raw=os.path.relpath(raw, ROOT), model="tts",
                       notes=notes)


def probe_v11_tier(a, metric: str) -> ProbeResult:
    """V11 (M9.T05): `AntiChat -Bench transcribe-file --tier-cap <cap>`: the 60-min fixture through the helper's
    FileTranscriber at the tier's budget B with the tier's chat model resident, n = 3 (A-M3-03). `V11_JSON=<v11.json>`
    ingests FileTranscriberRealTests/v11SixtyMinutes instead (in-process, no cap)."""
    if os.environ.get("V11_JSON"):
        return probe_v11(a, metric)
    os.makedirs(RAW_DIR, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    raw = os.path.join(RAW_DIR, f"V11-{a.tier}-{stamp}.jsonl")
    cap = TIER_CAP.get(a.tier, a.tier)
    chat = a.model or VOICE_TIER_CHAT.get(tier_family(a.tier), "chat-9b-q4")
    fx = os.environ.get("ANTICHAT_FIXTURES", os.path.join(ROOT, "fixtures"))
    wav = os.environ.get("V11_INPUT") or os.path.join(fx, "audio/long-file/long-60min.wav")
    p = run_gpu([app_exe(a), "-Bench", "transcribe-file", "--tier-cap", cap, "--model", chat, "--runs", str(a.runs),
                 "--input", wav, "--raw", raw], "-Bench transcribe-file")
    if p.returncode != 0 or not os.path.exists(raw):
        raise RuntimeError(f"-Bench transcribe-file exit {p.returncode}: {(p.stderr or p.stdout)[-600:]}")
    runs = [r for r in bench_rows(raw) if r.get("kind") == "run"]
    vals = [r["realtime_x"] for r in runs if isinstance(r.get("realtime_x"), (int, float)) and r["realtime_x"] > 0]
    notes = [f"run {r['run']}: {r['seconds']:.1f} s for {r['audio_s']:.0f} s audio ({r['realtime_x']:.1f}×), load {r.get('load', '?')}"
             + (f", error {r['error']}" if r.get("error") else "") for r in runs]
    notes.append(f"cap {cap} (B {loadmod_b(cap)}), {chat} resident (warm-up {runs[0].get('chat_load_s') if runs else None} s); Parakeet `stt` + Silero `vad-files` through the helper (disk-backed)")
    return ProbeResult({None: vals}, method="measured", label="FileTranscriber via XPC at the tier cap", raw=os.path.relpath(raw, ROOT),
                       model="stt", notes=notes)


def loadmod_b(cap: str) -> str:
    b = {"T0": 4.0, "T1": 9.5, "T2-24": 16, "T2-32": 21, "T2-36": 24, "T3-48": 36, "T3-64": 48}.get(cap)
    return f"{b:g} GB" if b else "uncapped"


def probe_for(metric: str, a):
    if metric == "SELFTEST":
        return probe_selftest
    if a.from_log and metric == "IMAGE_TURN_OVERHEAD":
        return probe_image_turn
    if a.from_log:
        if metric not in LOG_METRICS and metric != "U5":
            raise RuntimeError(f"{metric}: no perf-log interval mapping (log metrics: {', '.join(LOG_METRICS)})")
        return probe_log
    if metric == "U1":
        return probe_launch
    if metric == "U9":
        return probe_u9
    if metric == "B1":
        return probe_b1
    if metric in CHAT_METRICS:
        return probe_chat
    if metric == "M1":
        return probe_load
    if metric == "U3":
        return probe_u3
    if metric == "C7":
        return probe_modeswap
    if metric == "R1":
        return probe_soak
    if metric in VOICE_BENCH:
        return probe_voice
    if metric == "V5":
        return probe_v5
    if metric == "V9":
        return probe_v9
    if metric == "V11":
        return probe_v11_tier
    if metric == "V8":
        return probe_v8_tier
    if metric == "IMAGE_TURN_OVERHEAD":
        return probe_image_turn
    if metric == "F7_VIDEO":
        return probe_f7_video
    if metric == "V4" or (metric == "V283_EOS_FINAL" and not os.environ.get("VOICE_RAW")):
        return probe_turn
    if metric in ("V1", "V1b", "V2", "V3", "V283_EOS_FINAL"):
        return probe_conversation
    if metric == "F7":
        return probe_csc
    if metric in SEARCH_TARGETS:
        return probe_search
    if metric in LOG_METRICS:
        raise Forward(f"{metric}: driver not built yet — {LOG_METRICS[metric][2]}; meanwhile ingest a perf log with --from-log")
    if metric in FORWARD:
        raise Forward(f"{metric}: probe lands in {FORWARD[metric]}")
    raise RuntimeError(f"{metric}: unknown metric (run.py --list)")


# ---------------------------------------------------------------- main flow

def gate_load(a, gpu: bool) -> tuple[list[dict], dict]:
    deadline = time.time() + a.wait_quiet
    while True:
        s = loadmod.sample()
        v = loadmod.verdict([s], gpu)
        if gpu and s.get("gpu_lock_held"):
            v["reasons"].append("another job holds the one-GPU-job lock (the probe would queue behind it)")
            v["quality"] = "noisy"
        if v["quality"] == "clean" or time.time() >= deadline:
            return [s], v
        print(f"[wait] machine busy ({'; '.join(v['reasons'])}); re-checking in 15 s", file=sys.stderr)
        time.sleep(min(15, max(1, deadline - time.time())))


def write_run_record(rec: dict) -> str:
    os.makedirs(RUNS_DIR, exist_ok=True)
    name = f"{dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{rec['metric']}-{rec['tier'].replace('/', '_')}.json"
    path = os.path.join(RUNS_DIR, name)
    reportio.save(path, rec)
    return path


def run(a) -> int:
    targets = json.load(open(TARGETS))
    targets["metrics"].update(SEARCH_TARGETS)  # M7.T03
    targets["metrics"].update(EXTRA_TARGETS)  # M9.T05
    a.metric = SEARCH_ALIASES.get(a.metric, a.metric)
    metric, tier = a.metric, a.tier
    is_self = metric == "SELFTEST"
    if not is_self and metric not in targets["metrics"]:
        print(f"[fail] unknown metric {metric}; known: {', '.join(sorted(targets['metrics']))}", file=sys.stderr)
        return EXIT_ERROR
    if not re.match(r"^(T[0-4](-[0-9]+)?|na)$", tier):
        print(f"[fail] --tier {tier}: T0…T4, T2-24, T3-48 or na", file=sys.stderr)
        return EXIT_ERROR
    try:
        probe = probe_for(metric, a)
    except Forward as e:
        print(f"[forward] {e}", file=sys.stderr)
        write_run_record({"metric": metric, "tier": tier, "date": utc_now(), "commit": commit(), "result": "forward", "message": str(e)})
        return EXIT_FORWARD
    except RuntimeError as e:
        print(f"[fail] {e}", file=sys.stderr)
        return EXIT_ERROR
    mach = machine(targets)
    gpu = probe in (probe_chat, probe_load, probe_modeswap, probe_csc, probe_search, probe_u3, probe_image_turn, probe_f7_video,
                    probe_v8_tier, probe_v11_tier)
    ingest = probe in (probe_log, probe_soak, probe_turn, probe_v9) or (probe is probe_image_turn and a.from_log) or (
        probe is probe_f7_video and os.environ.get("VIDEO_RAW")) or (probe is probe_v8_tier and os.environ.get("V8_JSON")) or (
        probe is probe_v11_tier and os.environ.get("V11_JSON")) or (probe is probe_conversation and (metric == "V3" or os.environ.get("VOICE_RAW")))  # measured elsewhere; the producer records its own load
    rec = {"metric": metric, "tier": tier, "date": utc_now(), "commit": commit(), "machine": mach, "runs": a.runs,
           "probe": probe.__name__.replace("probe_", "")}
    if ingest:
        # The measurement happened elsewhere; the current load says nothing about it. Recorded, never refused.
        before, v = [loadmod.sample()], {"quality": "clean", "reasons": [], "thresholds": loadmod.THRESHOLDS}
        v["reasons"].append("ingested log: load at measurement time unknown here (the producer records its own)")
    else:
        before, v = gate_load(a, gpu)
    rec["load_before"] = loadmod.summarize(before)
    if v["quality"] == "noisy" and not a.allow_noisy and not ingest:
        rec.update(result="refused", reasons=v["reasons"])
        path = write_run_record(rec)
        print(f"[refused] machine too busy for {metric}/{tier}: {'; '.join(v['reasons'])}\n"
              f"          run record {os.path.relpath(path, ROOT)}; re-run later, raise --wait-quiet, or ALLOW_NOISY=1", file=sys.stderr)
        return EXIT_REFUSED
    try:
        with loadmod.Sampler(interval=5.0) as smp:
            res = probe(a, metric)
    except Deferred as e:
        rec.update(result="deferred", error=str(e))
        write_run_record(rec)
        print(f"[deferred] {e}", file=sys.stderr)
        return EXIT_DEFERRED
    except RuntimeError as e:
        rec.update(result="error", error=str(e))
        write_run_record(rec)
        print(f"[fail] {e}", file=sys.stderr)
        return EXIT_ERROR
    after = [loadmod.sample()]
    during = smp.samples
    # CPU/battery/thermal over before+during+after; GPU only before (during a GPU probe the GPU is ours).
    v_all = loadmod.verdict(before + during + after, gpu=False)
    v_gpu = loadmod.verdict(before, gpu=gpu)
    reasons = sorted(set(v["reasons"] + v_all["reasons"] + v_gpu["reasons"])) if not ingest else v["reasons"]
    quality = "noisy" if (not ingest and (v["quality"] == "noisy" or v_all["quality"] == "noisy" or v_gpu["quality"] == "noisy")) else "clean"
    load = {"quality": quality, "reasons": reasons, "allowed_noisy": bool(a.allow_noisy and quality == "noisy"),
            "thresholds": v["thresholds"], "before": loadmod.summarize(before), "during": loadmod.summarize(during),
            "after": loadmod.summarize(after)}
    t = targets["metrics"].get(metric) if not is_self else {"unit": "ms", "nfr": None, "tiers": {}, "variants": {}}
    build = app_build(a.app if probe in (probe_launch, probe_u9, probe_b1, probe_chat, probe_load, probe_modeswap, probe_voice, probe_conversation,
                                probe_image_turn, probe_f7_video, probe_v8_tier, probe_v11_tier)
                      # M9.T05: a perf log from a known app (XCUITest legs driving --app) takes that app's validity
                      or ((a.from_log or ingest) and a.app_explicit) else None)
    now, head = utc_now(), commit()
    entries = {}
    worst = EXIT_PASS
    debug = not build_valid(build)
    if build.get("config") == "Debug":  # tools/bench.sh rule: Debug numbers are never reported
        res.notes = res.notes + ["Debug build: pipeline smoke only, never an NFR result (valid=false); use make build-perf"]
    elif debug:
        res.notes = res.notes + [f"perf build not confirmed by -Bench buildinfo ({build.get('buildinfo')}): valid=false"]
    for variant, xs in res.samples.items():
        st = stats(xs)
        checks = checks_for(t, tier, variant, mach, res.extra) if not is_self else None
        acc = (res.extra or {}).get("accepted_max") or {}
        if variant in acc:  # an owner-accepted per-variant miss (e.g. V9 ar / zh, A-M3-06): its own recorded limit
            checks = [{"op": "<=", "stat": "max", "value": acc[variant], "accepted_by": res.extra.get("accepted_by")}]
        checked, ok = evaluate(st, checks)
        key = tier + (f"/{variant}" if variant else "")
        e = dict(st)
        e.update({"unit": t["unit"], "nfr": t.get("nfr"), "target": checked, "pass": ok, "method": res.method,
                  "label": res.label, "quality": quality, "valid": quality == "clean" and not debug, "load": load, "date": now,
                  "commit": head, "build": build, "machine": mach, "model": res.model, "probe": rec["probe"],
                  "raw": res.raw, "scaled_from": None, "notes": res.notes})
        entries[key] = e
        if st["n"] < a.runs and not ingest:
            e["notes"] = e["notes"] + [f"only {st['n']} of {a.runs} runs produced a value"]
        if ok is False:
            worst = max(worst, EXIT_FAIL)
        print(f"[{'PASS' if ok else 'FAIL' if ok is False else 'n/a '}] {metric}.{key} p50={_fmt(st['p50'])} p95={_fmt(st['p95'])} "
              f"p99={_fmt(st['p99'])} n={st['n']} {t['unit']} quality={quality}"
              + (f" ({'; '.join(reasons)})" if quality == "noisy" else ""))
    rec.update(result="measured", quality=quality, load=load, entries=entries)
    path = write_run_record(rec)
    print(f"[ok] run record {os.path.relpath(path, ROOT)}")
    if a.dry_run:
        return worst
    out = a.out or (os.path.join(ROOT, "build/perf/selftest.json") if is_self else reportio.DEFAULT_REPORT)
    written: list[str] = []
    with reportio.locked(out) as data:
        for key, e in entries.items():
            cur = (data.get("metrics") or {}).get(metric, {}).get(key)
            if cur is not None and cur.get("valid", True) and not e["valid"]:
                print(f"[skip] metrics.{metric}.{key}: a clean entry exists; a noisy run never replaces it")
                continue
            if reportio.put_metric(data, metric, key, e, a.replace):
                written.append(key)
        data.update(schema=reportio.SCHEMA_ID, commit=head, date=now, machine=mach, build=build)
        errs = validate_report(data)
        if errs:
            raise SystemExit(f"[fail] report would not match report_schema.json: {errs[:5]}")
    if written:
        print(f"[ok] wrote metrics.{metric}.{{{','.join(written)}}} → {os.path.relpath(out, ROOT)}")
    return worst


def _fmt(x):
    return "—" if x is None else f"{x:.4g}"


def list_metrics() -> int:
    targets = json.load(open(TARGETS))
    for m in sorted(targets["metrics"]):
        if m == "U1":
            how = "launch probe (+ --from-log)"
        elif m == "U9":
            how = "quick panel probe (Debug app + tools/perf/hotkey-post)"
        elif m in CHAT_METRICS:
            how = "chat probe (antichat-bench, GPU lock)"
        elif m == "M1":
            how = "load probe (antichat-bench load, GPU lock)"
        elif m == "R1":
            how = "mini-soak sampler (tools/soak/mini-soak.sh → build/at/AT-206/soak-<tier>.csv)"
        elif m in LOG_METRICS:
            how = f"--from-log '{LOG_METRICS[m][0]}'; driver: {LOG_METRICS[m][2]}"
        else:
            how = f"forward: {FORWARD.get(m, '?')}"
        print(f"{m:14s} {targets['metrics'][m]['unit']:14s} {how}")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--metric")
    ap.add_argument("--tier", default="na")
    ap.add_argument("--runs", type=int, default=20)
    ap.add_argument("--out")
    ap.add_argument("--replace", action="store_true", default=os.environ.get("PERF_REPLACE") == "1")
    ap.add_argument("--allow-noisy", action="store_true", default=os.environ.get("ALLOW_NOISY") == "1")
    ap.add_argument("--wait-quiet", type=float, default=float(os.environ.get("PERF_WAIT") or 0))
    ap.add_argument("--from-log")
    ap.add_argument("--app", default=None)
    ap.add_argument("--model")
    ap.add_argument("--launch-timeout", type=float, default=30)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args(argv)
    a.app_explicit = a.app is not None
    a.app = a.app or os.path.join(ROOT, "build/AntiChat.app")
    if a.list:
        return list_metrics()
    if not a.metric:
        ap.error("--metric is required (or --list)")
    a.app = os.path.abspath(a.app)
    try:
        return run(a)
    except (OSError, ValueError) as e:
        print(f"[fail] {e}", file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    raise SystemExit(main())
