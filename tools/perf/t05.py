#!/usr/bin/env python3
"""M9.T05 single entry point: every NFR probe and every item deferred to M9.T05, in order. Stdlib only.

  python3 -I tools/perf/t05.py --list                     the plan (id, bar, tier, model, GPU mode, est. minutes, result)
  python3 -I tools/perf/t05.py run                         T05 proper: quiet machine (tools/perf/load.py bar), gpu-run
                                                           timing, full runs, results → build/perf/report.json + build/at
  python3 -I tools/perf/t05.py run --dry --allow-noisy     dry run: cheap settings, gpu-run shared, every result under
                                                           build/perf/t05-dry/<stamp>/ (labelled NOISY/DRY; never results)
  options: --only id,id|group  --from <id>  --skip id,…  --wait-quiet S (default 1800 per step)  --keep-going (default on)
  make perf-all [DRY=1] [STEPS=…]                          the same through make

Plan = docs/prd/M9-T05-runplan.md (the steps below are its source of truth; `--list --md` prints its table).
Per step: prerequisites (files that must exist), the quiet-machine gate (real mode: wait up to --wait-quiet for
load.py's verdict to be clean, else the step is `refused`; with --allow-noisy it runs and is labelled noisy), the
command (real or dry variant) with ANTICHAT_GPU_MODE=timing|shared for run.py's probes, or wrapped in
`gpu-run.sh <mode> --` for the other GPU steps, its log, and a check that the step's result file was written.
Status per step: ok · fail (ran, a bar or the command failed) · refused (busy machine) · deferred (gpu-run exit 75) ·
missing-prereq · owner (needs the owner: sudo; printed, never attempted) · blocked (no driver; reason
printed). Summary: <out>/summary.json + summary.md.

Dry runs never touch committed artefacts: run.py writes to the dry report/runs dir, and any tracked file under build/
that a step rewrites is copied into the dry dir and restored from git (new untracked files are moved there).
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import shlex
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import load as loadmod  # noqa: E402

GPU_RUN = os.environ.get("ANTICHAT_GPU_RUN", os.path.expanduser("~/AntiChat-tools/gpu-run.sh"))
DEV_MODELS = os.path.expanduser(os.environ.get("ANTICHAT_DEV_CACHE", "~/Library/Application Support/AntiChat-Dev") + "/Models")
APP = "build/AntiChat.app"  # Debug: XCUITest legs, test bundles, PR1/D3 (no timing bar)
# M9.T05 (lead, 2026-11-11): every timed app probe runs the optimized perf-harness build (`make build-perf`;
# run.py files it valid only when `-Bench buildinfo` confirms optimized, non-DEBUG, ANTICHAT_PERF_HARNESS).
PERF_APP = "build/perf-app/AntiChat.app"
# Timing ingested from an XCTest bundle (`make test-unit`: always a Debug build) is filed against the Debug app, so
# run.py marks it valid=false (the Debug rule) instead of borrowing the perf app's validity.
TEST_BUNDLE = f"--app {APP}"
BENCH = ".build/release/antichat-bench"
PERF = "python3 -I tools/perf/run.py"
# M9.T05 XCUITest perf legs (App/UITests/Perf): the 10,000-chat database (+ one 500-turn chat) they copy per launch.
BIG10K = ("test -f build/fixtures/big-10k.sqlite || python3 -I tools/fixtures/gen-chats.py --chats 10000 --long 1:1000 "
          "--out build/fixtures/big-10k.sqlite")
# XCUITest takes the foreground (accessibility + HID events): never in a dry run on the shared Mac; the drivers were
# smoke-run once on m9/t05-drivers (runplan §6) and run for real in T05 with the owner away.
UI_DRY = "echo 'dry: XCUITest takes the foreground; first run in T05 with the owner away (driver smoke-run on m9/t05-drivers)'"


class Step:
    def __init__(self, id, group, title, *, real=None, dry=None, gpu=None, bar="", tier="", model="", est=0, result=None,
                 needs=(), status=None, why="", nfr="", dry_est=None, hard=False):
        self.id, self.group, self.title, self.real, self.dry = id, group, title, real, dry if dry is not None else real
        self.gpu, self.bar, self.tier, self.model, self.est, self.result = gpu, bar, tier, model, est, result
        self.needs, self.status, self.why, self.nfr, self.hard = list(needs), status, why, nfr, hard
        self.dry_est = dry_est if dry_est is not None else (min(est, 5) if est else 0)


def perf(metric, tier, runs, dry_runs=1, model=None, extra=""):
    """A `tools/perf/run.py` step (GPU wrap inside run.py via ANTICHAT_GPU_MODE)."""
    m = f" --model {model}" if model else ""
    app = "" if "--app" in extra or "--from-log" in extra else " --app \"$T05_APP\""
    base = f"{PERF} --metric {metric} --tier {tier}{m}{app} --out \"$T05_REPORT\" $T05_PERF_FLAGS {extra}".rstrip()
    return f"{base} --runs {runs}", f"{base} --runs {dry_runs}"


def chat_steps():
    out = []
    models = {"T0": "chat-2b", "T1": "chat-9b-q4", "T2": "chat-9b-q4 @ T2-24", "T3": "chat-35b-q4 @ T3-48"}
    bars = {"C1": {"T0": "p50 ≤ 1.5 s", "T1": "p50 ≤ 1.5 s", "T2": "p50 ≤ 1.0 s", "T3": "p50 ≤ 0.8 s"},
            "C1b": {"T0": "TTFT p95 ≤ 3 s", "T1": "TTFT p95 ≤ 3 s", "T2": "TTFT p95 ≤ 2 s", "T3": "TTFT p95 ≤ 1.5 s"},
            "C2": {"T0": "decode p50 ≥ 20 tok/s", "T1": "decode p50 ≥ 15 tok/s", "T2": "decode p50 ≥ 20 tok/s", "T3": "decode p50 ≥ 30 tok/s"},
            "C4": {"T0": "prefill ≥ 150 tok/s (4K doc)", "T1": "prefill ≥ 150 tok/s", "T2": "prefill ≥ 300 tok/s", "T3": "prefill ≥ 400 tok/s"}}
    for metric in ("C1", "C1b", "C2", "C4"):
        for tier in ("T0", "T1", "T2", "T3"):
            r, d = perf(metric, tier, 20)
            out.append(Step(f"chat.{metric}.{tier}", "chat", f"NFR-{metric} {tier} (antichat-bench chat via XPC)", real=r, dry=d,
                            gpu="run.py", bar=bars[metric][tier], tier=tier, model=models[tier], est=4, dry_est=2,
                            result="$T05_RUNS/*-" + metric + "-" + tier + ".json", needs=[BENCH, PERF_APP], nfr=f"NFR-{metric}"))
    for tier, m in (("T0", "chat-2b"), ("T1", "chat-9b-q4"), ("T3", "chat-35b-q4")):
        r, d = perf("M1", tier, 20)
        out.append(Step(f"chat.M1.{tier}", "chat", f"NFR-M1 cold load {tier} (evict → ready; [WARM-CACHE] without sudo purge)",
                        real=r, dry=d, gpu="run.py", bar="≤ 3/8/12/25 s by weights", tier=tier, model=m, est=5, dry_est=2,
                        result=f"$T05_RUNS/*-M1-{tier}.json", needs=[BENCH, PERF_APP], nfr="NFR-M1"))
    for tier, m in (("T1", "chat-9b-q4 → evil-9b (cold)"), ("T3", "chat-35b-q4 → evil-35b-q4 (T3-64, warm)")):
        r, d = perf("C7", tier, 20)
        out.append(Step(f"chat.C7.{tier}", "chat", f"NFR-C7 Normal → Evil switch to first token {tier}", real=r, dry=d,
                        gpu="run.py", bar="cold: M1 band + C1; warm ≤ 1.5 s", tier=tier, model=m, est=18, dry_est=3,
                        result=f"$T05_RUNS/*-C7-{tier}.json", needs=[BENCH, PERF_APP], nfr="NFR-C7"))
    for tier, m in (("T1", "chat-9b-q4"), ("T3", "chat-35b-q4")):
        r, d = perf("U3", tier, 20)
        out.append(Step(f"chat.U3.{tier}", "chat", f"NFR-U3 send while loading {tier} (antichat-bench u3)", real=r, dry=d,
                        gpu="run.py", bar="status ≤ 2 s p95; reply ≤ M1 band + C1", tier=tier, model=m, est=6, dry_est=2,
                        result=f"$T05_RUNS/*-U3-{tier}.json", needs=[BENCH, PERF_APP], nfr="NFR-U3"))
    return out


def steps() -> list[Step]:
    fx = "$ANTICHAT_FIXTURES"
    S: list[Step] = []
    # ---------------------------------------------------------------- 0. prep (no timing numbers)
    S += [
        Step("prep.machine", "prep", "machine line + quiet check (AC power, thermal, Spotlight, load.py verdict)",
             real="pmset -g batt | head -2; pmset -g therm; mdutil -s / ; python3 -I tools/perf/load.py --gpu > \"$T05_OUT/load-start.json\"; cat \"$T05_OUT/load-start.json\"",
             result="$T05_OUT/load-start.json", est=1, dry_est=1),
        Step("prep.power", "prep", "HARD precondition: Low Power Mode off (pmset powermode 0); set by the owner, never by an agent",
             real="tools/perf/power-mode.sh --require-off", dry="tools/perf/power-mode.sh", est=0, hard=True),
        Step("prep.disk", "prep", "≥ 60 GB free before model work", real="df -g / | awk 'NR==2 {print $4\" GB free\"; exit ($4 < 60)}'", est=0),
        Step("prep.build-debug", "prep", "Debug app (ScriptedVoice, -Bench, probes): make build", real="make build", est=25, dry_est=25,
             result=APP + "/Contents/MacOS/AntiChat"),
        Step("prep.build-perf", "prep", "optimized perf-harness app (Release -O/NDEBUG + ANTICHAT_PERF_HARNESS): make build-perf",
             real="make build-perf", est=25, dry_est=25, result=PERF_APP + "/Contents/MacOS/AntiChat"),
        Step("prep.t4-install", "prep", "T4 video catalog install (vid-5b set, ~38 GB copied from the dev models): before any timed step",
             real="APP=\"$T05_APP\" tools/perf/t4-video-bench.sh install 0", dry="echo dry: the T4 install runs in T05 only", est=15, dry_est=0,
             result="build/perf/t4models/installs/vid-5b"),
        Step("prep.bench-release", "prep", "release antichat-bench (NDEBUG, DuckDB): make bench-release", real="make bench-release",
             est=20, dry_est=20, result=BENCH),
        Step("prep.binaries", "prep", "helper binaries (llama-server, sd-server, sd-cli) staged", real="make stage-binaries",
             est=1, result="build/binaries/sd-server"),
        Step("prep.runtime-video", "prep", "video runtime (vid-5b / I2V)", real="test -d build/runtimes/video-runtime || make runtime-video",
             est=10, result="build/runtimes/video-runtime"),
        Step("prep.gpu-burn", "prep", "gpu-burn helper (B5)", real="test -x build/tools/gpu-burn || tools/perf/gpu-burn/build.sh",
             est=1, result="build/tools/gpu-burn"),
        Step("prep.models", "prep", "dev models T0/T1/T3 + evil-T1/evil-T3 (make models-dev)",
             real="for t in T0 T1 T3 evil-T1 evil-T3; do make models-dev TIER=$t || exit 1; done",
             dry="for k in chat-2b chat-9b-q4 chat-35b-q4 evil-9b stt stt-eou tts vad-files embed img-klein vid-5b vid-i2v; do "
                 "test -e \"$DEV_MODELS/$k\" || { echo missing $k; exit 1; }; done; "
                 # the turn model the helper loads is turn-coreml (installs/turn is the ONNX packaging), or M0's turn/coreml
                 "test -e \"$DEV_MODELS/installs/turn-coreml/manifest.json\" || test -e \"$DEV_MODELS/turn/coreml\" "
                 "|| { echo missing turn-coreml; exit 1; }; echo dev models present",
             est=10, dry_est=0),
    ]
    # ---------------------------------------------------------------- 1. chat
    S += chat_steps()
    # ---------------------------------------------------------------- 2. UI / app-level
    r, d = perf("U1", "na", 20, extra="--app \"$T05_U1_APP\"")
    S += [
        Step("ui.U1", "ui", "NFR-U1 cold start (foreground launch → composer focus; takes focus; cold needs `sudo -n purge`)", real=r,
             dry="echo 'dry: U1 takes focus (foreground launch, ANTICHAT_PERF_FOREGROUND=1); first exercised in T05 with the owner away'",
             bar="p50 ≤ 1.0 s (S2+); warm ≤ 0.5 s", tier="na", est=4, dry_est=1, result="$T05_RUNS/*-U1-na.json", needs=[PERF_APP], nfr="NFR-U1"),
        Step("ui.U9", "ui", "NFR-U9 quick panel open (Debug app, hotkey-post)", real=perf("U9", "T1", 30)[0], dry=perf("U9", "T1", 30, 1)[1],
             bar="p95 ≤ 150 ms", tier="T1", est=3, dry_est=2, result="$T05_RUNS/*-U9-T1.json", needs=[PERF_APP], nfr="NFR-U9"),
        Step("ui.B1", "ui", "NFR-B1 idle energy (top power, window open, 5 min)", real=perf("B1", "na", 20, extra="--app \"$T05_U1_APP\"")[0],
             dry=perf("B1", "na", 20, 1, extra="--app \"$T05_U1_APP\"")[1], bar="mean Energy Impact ≤ 1", tier="na", est=6, dry_est=1,
             result="$T05_RUNS/*-B1-na.json", needs=[PERF_APP], nfr="NFR-B1"),
        Step("ui.U5", "ui", "NFR-U5 renderer cadence (A-M1-T09b; in-process renderer probe + frametime)",
             real="AT008_FRAMES=1 make test-unit FILTER=RendererLayoutFramesTests && AT008_APP=\"$T05_APP\" tools/at/at-008-probe.sh", gpu=None, bar="hitches per reply (nfr.md U5)", tier="S4", est=5, dry_est=5,
             result="build/at/AT-008/renderer*.json", needs=[PERF_APP], nfr="NFR-U5"),
        Step("ui.U5.S4", "ui", "NFR-U5 renderer cadence on this Mac's own class (S4: -RendererCPUScale 1.0; ui.U5 is the S1 stand-in)",
             real="AT008_APP=\"$T05_APP\" AT008_OUT=\"$T05_AT/AT-008-S4\" tools/at/at-008-probe.sh 1.0", gpu=None,
             bar="hitches per reply (nfr.md U5)", tier="S4", est=5, dry_est=5, result="$T05_AT/AT-008-S4/renderer*.json",
             needs=[PERF_APP], nfr="NFR-U5"),
        Step("ui.U2-U6-U10-U11", "ui", "NFR-U2/U6/U10/U11 XCUITest perf legs (App/UITests/Perf: send ack, Stop, ⌘K on 10,000 chats, "
             "open a 500-turn chat; takes the foreground) → perf log → run.py --from-log",
             real=f"{BIG10K}; TEST_RUNNER_ANTICHAT_PERF_APP=\"$T05_APP\" TEST_RUNNER_ANTICHAT_PERF_LOG=\"$T05_OUT/uitest-perf.jsonl\" TEST_RUNNER_ANTICHAT_PERF_RUNS=20 "
                  "make test-ui FILTER=SendAckPerfTests,StopPerfTests,PalettePerfTests,LongChatOpenPerfTests; rc=$?; "
                  "for m in U2 U6 U10 U11; do " + perf("$m", "na", 20, extra="--app \"$T05_APP\" --from-log \"$T05_OUT/uitest-perf.jsonl\"")[0]
                  + " || rc=1; done; exit $rc",
             dry=UI_DRY, bar="U2 p99 < 100 ms, p50 ≤ 16 ms · U6 p50 ≤ 300 ms, p95 ≤ 1 s · U10 p95 ≤ 200 ms · U11 p95 ≤ 500 ms",
             tier="na", model="ScriptedEngine", est=14, dry_est=0, result="$T05_RUNS/*-U11-na.json", needs=[APP, PERF_APP], nfr="NFR-U2/U6/U10/U11"),
    ]
    # ---------------------------------------------------------------- 3. voice
    S += [
        Step("voice.V7.T1", "voice", "NFR-V7/V6 dictation (stop → final; onset → first partial), T1", real=perf("V7", "T1", 20)[0],
             dry=perf("V7", "T1", 20, 1)[1], gpu="run.py", bar="V7 p50 ≤ 0.4 s; V6 ≤ 0.6 s", tier="T1", model="stt + stt-eou",
             est=4, dry_est=2, result="$T05_RUNS/*-V7-T1.json", needs=[PERF_APP], nfr="NFR-V6/V7"),
        Step("voice.V6.T1", "voice", "NFR-V6 from the same dictation run", real="VOICE_RAW=$(ls -t build/perf/raw/m1/V7-T1-*.jsonl | head -1) " + perf("V6", "T1", 20)[0],
             dry="VOICE_RAW=$(ls -t build/perf/raw/m1/V7-T1-*.jsonl | head -1) " + perf("V6", "T1", 20, 1)[1], bar="p50 ≤ 0.6 s", tier="T1",
             est=0, result="$T05_RUNS/*-V6-T1.json", nfr="NFR-V6"),
        Step("voice.V7.T3", "voice", "AT-050 AC2 V7 at T3 (T3-48 cap)", real=perf("V7", "T3", 20)[0], dry=perf("V7", "T3", 20, 1)[1],
             gpu="run.py", bar="p50 ≤ 0.3 s", tier="T3-48", model="stt + stt-eou", est=4, dry_est=2, result="$T05_RUNS/*-V7-T3.json",
             needs=[PERF_APP], nfr="NFR-V7"),
        Step("voice.V7.T0", "voice", "V7 at T0 (no stt-eou on T0)", real=perf("V7", "T0", 20)[0], dry=perf("V7", "T0", 20, 1)[1],
             gpu="run.py", bar="p50 ≤ 1.0 s", tier="T0", model="stt", est=4, dry_est=2, result="$T05_RUNS/*-V7-T0.json", needs=[PERF_APP], nfr="NFR-V7"),
        Step("voice.V10.T1", "voice", "NFR-V10 dictation warm-up after evict", real=perf("V10", "T1", 20)[0], dry=perf("V10", "T1", 20, 1)[1],
             gpu="run.py", bar="p50 ≤ 300 ms", tier="T1", model="stt", est=4, dry_est=2, result="$T05_RUNS/*-V10-T1.json", needs=[PERF_APP], nfr="NFR-V10"),
    ]
    for tier, m in (("T1", "chat-9b-q4"), ("T3", "chat-35b-q4"), ("T0", "chat-2b")):
        S.append(Step(f"voice.V1.{tier}", "voice", f"NFR-V1/V1b/V2/V283 voice session {tier} (-Bench voice-session, 20 questions)",
                      real=perf("V1", tier, 20)[0], dry=perf("V1", tier, 20, 1)[1], gpu="run.py", bar="V1 p50 T0 ≤ 2.5 · T1 ≤ 1.5 · T3 ≤ 1.0 s; V1b p95 (nfr.md)",
                      tier=tier if tier != "T3" else "T3-48", model=m + " + stt + stt-eou + vad + turn + tts", est=8, dry_est=3,
                      result=f"$T05_RUNS/*-V1-{tier}.json", needs=[PERF_APP], nfr="NFR-V1"))
        for met in ("V1b", "V2", "V283_EOS_FINAL"):
            S.append(Step(f"voice.{met}.{tier}", "voice", f"NFR-{met} {tier} from the same voice-session run",
                          real=f"VOICE_RAW=$(ls -t build/perf/raw/m1/V1-{tier}-*.jsonl | head -1) " + perf(met, tier, 20)[0],
                          dry=f"VOICE_RAW=$(ls -t build/perf/raw/m1/V1-{tier}-*.jsonl | head -1) " + perf(met, tier, 20, 1)[1],
                          bar="nfr.md " + met, tier=tier, est=0, result=f"$T05_RUNS/*-{met}-{tier}.json", nfr="NFR-" + met))
    voice_env = f"ANTICHAT_VOICE_IT=1 ANTICHAT_FIXTURES={fx}"
    S += [
        Step("voice.V283", "voice", "V283 eager STT turn end → final (TurnSplitFixtureTests/eagerSTTLatency)",
             real=f"{voice_env} ANTICHAT_V283=1 make test-unit FILTER=TurnSplitFixtureTests/eagerSTTLatency && " + perf("V283_EOS_FINAL", "T1", 20, extra=TEST_BUNDLE)[0],
             dry=f"{voice_env} ANTICHAT_V283=1 ANTICHAT_V283_RUNS=3 make test-unit FILTER=TurnSplitFixtureTests/eagerSTTLatency && " + perf("V283_EOS_FINAL", "T1", 20, 1, extra=TEST_BUNDLE)[1],
             gpu="wrap", bar="p50 ≤ 300 ms", tier="T1", model="vad + turn + stt + stt-eou", est=6, dry_est=4,
             result="build/at/AT-283/eos.json", nfr="NFR-V283"),
        Step("voice.V4", "voice", "NFR-V4 false splits, 50 utterances × 4 noise beds (accuracy, shared)",
             real=f"{voice_env} make test-unit FILTER=TurnSplitFixtureTests/fiftyUtterancesCleanAndNoise && " + perf("V4", "T1", 1)[0],
             gpu="wrap-shared", bar="≤ 2.0 % per bed", tier="T1", model="vad + turn", est=5, dry_est=5,
             result="build/at/AT-283/turn-split.json", nfr="NFR-V4"),
        Step("voice.V3", "voice", "NFR-V3 barge-in onset → TTS silent (BargeInFixtureTests)",
             real=f"{voice_env} make test-unit FILTER=BargeInFixtureTests && " + perf("V3", "T1", 1, extra=TEST_BUNDLE)[0], gpu="wrap",
             bar="p50 ≤ 200 ms", tier="T1", model="vad + tts + stt", est=7, dry_est=7, result="build/at/AT-282/v3.json", nfr="NFR-V3"),
        Step("voice.V5", "voice", "NFR-V5 mic click → dictation bar drawn (in-process, no model)", real=perf("V5", "T1", 20)[0],
             dry=perf("V5", "T1", 20, 3)[1], bar="≤ 150 ms", tier="T1", est=4, dry_est=4, result="$T05_RUNS/*-V5-T1.json", nfr="NFR-V5"),
    ]
    # M9.T05: V8 / V11 per tier through the helper at that tier's cap (budget B + the tier's chat model resident):
    # `-Bench read-aloud` / `-Bench transcribe-file` (the in-process tests take no cap; V8_JSON / V11_JSON ingest them).
    for tier, bar, chat in (("T1", "p50 ≤ 0.5 s", "chat-9b-q4"), ("T0", "p50 ≤ 1.0 s", "chat-2b"), ("T3", "p50 ≤ 0.4 s", "chat-35b-q4")):
        S.append(Step(f"voice.V8.{tier}", "voice", f"NFR-V8 read aloud → first audio, Kokoro warm, at the {TIER_CAPS.get(tier, tier)} cap "
                      "(-Bench read-aloud, 1- and 3-sentence replies, silent clock)", real=perf("V8", tier, 20)[0], dry=perf("V8", tier, 20, 2)[1],
                      gpu="run.py", bar=bar, tier=TIER_CAPS.get(tier, tier), model=f"tts + {chat} resident", est=4, dry_est=2,
                      result=f"$T05_RUNS/*-V8-{tier}.json", needs=[PERF_APP], nfr="NFR-V8"))
    for tier, bar, chat in (("T0", "≥ 4× real time", "chat-2b"), ("T1", "≥ 10× real time", "chat-9b-q4"), ("T3", "≥ 10× real time", "chat-35b-q4")):
        S.append(Step(f"voice.V11.{tier}", "voice", f"NFR-V11 60-min file transcription speed at the {TIER_CAPS.get(tier, tier)} cap "
                      "(-Bench transcribe-file, n 3)", real=perf("V11", tier, 3)[0], dry=perf("V11", tier, 3, 1)[1],
                      gpu="run.py", bar=bar, tier=TIER_CAPS.get(tier, tier), model=f"stt + vad-files + {chat} resident", est=4, dry_est=2,
                      result=f"$T05_RUNS/*-V11-{tier}.json", needs=[PERF_APP], nfr="NFR-V11"))
    S += [
        Step("voice.V9", "voice", "NFR-V9 / AT-284 WER per language (accuracy; ar/zh accepted A-M3-06)",
             real=f"{voice_env} make test-unit FILTER=WERFixtureTests && python3 -I tools/voice/wer.py --in build/at/AT-284/wer.json --budget NFR-V9 --tier T1; " + perf("V9", "T1", 1)[0],
             dry=f"{voice_env} ANTICHAT_WER_N=2 make test-unit FILTER=WERFixtureTests && " + perf("V9", "T1", 1)[1],
             gpu="wrap-shared", bar="worst language ≤ 6 % (ar 11.4 / zh 10.6 accepted)", tier="T0/T1", model="stt + stt-multi (m0 manifest)",
             est=25, dry_est=5, result="build/at/AT-284/wer.json", nfr="NFR-V9"),
    ]
    # ---------------------------------------------------------------- 4. photo + ChildSafetyCheck
    S += [
        Step("photo.handoff.T1", "photo", "NFR-P1 T1 + AT-NFR-M3 (unload ≤ 1 s, reload ≤ M1) + NFR-R1 T1 image peak (ImageHandoffTests)",
             real="make test-integration-real TIER=T1 FILTER=ImageHandoffTests", gpu="wrap",
             bar="P1 S4 ≤ 20 s (S1 150 / S2 60 / S3 45 scaled); unload ≤ 1 s; peak ≤ 9.5 GB", tier="T1",
             model="img-klein-q4 768² 4 steps + chat-9b-q4", est=12, dry_est=12, result="build/at/AT-286/handoff-T1.json", nfr="NFR-P1/M3/R1"),
        Step("photo.P1.bench", "photo", "NFR-P1 -Bench image (T3 default 1024², q4) → sd-scale.py per speed class (+ the "
             "request → first denoise step diagnostic m0.P2step1; NFR-P2 itself is photo.P2.visible, A-M4-R1b)",
             real=f"\"$T05_APP\"/Contents/MacOS/AntiChat -Bench image --quant q4 --res 1024 --runs 20 --tier-cap T3-48 --prompts {fx}/images/prompts-50.json --out-dir \"$T05_OUT/image-out\" --raw \"$T05_OUT/image-q4-1024.jsonl\" && python3 -I tools/perf/sd-scale.py --raw-dir \"$T05_OUT\" --report \"$T05_REPORT\" --replace",
             dry=f"\"$T05_APP\"/Contents/MacOS/AntiChat -Bench image --quant q4 --res 768 --runs 1 --tier-cap T3-48 --prompts {fx}/images/prompts-50.json --out-dir \"$T05_OUT/image-out\" --raw \"$T05_OUT/image-q4-768.jsonl\"",
             gpu="wrap", bar="P1 S4 ≤ 20 s", tier="T3-48",
             model="img-klein q4", est=15, dry_est=3, result="$T05_OUT/image-q4-*.jsonl", needs=[PERF_APP], nfr="NFR-P1"),
        Step("photo.M3.T2-24", "photo", "AT-NFR-M3 T2-24 / R-236 co-resident image + chat (-Bench coresident)",
             real=f"\"$T05_APP\"/Contents/MacOS/AntiChat -Bench coresident --tier-cap T2-24 --model chat-9b-q4 --quant q8 --res 1024 --runs 10 --prompts {fx}/images/prompts-50.json --out-dir \"$T05_OUT/image-out\" --raw \"$T05_OUT/coresident-T2-24.jsonl\"",
             dry=f"\"$T05_APP\"/Contents/MacOS/AntiChat -Bench coresident --tier-cap T2-24 --model chat-9b-q4 --quant q4 --res 768 --runs 1 --prompts {fx}/images/prompts-50.json --out-dir \"$T05_OUT/image-out\" --raw \"$T05_OUT/coresident-T2-24.jsonl\"",
             gpu="wrap", bar="no eviction; peak ≤ B 16 GB; reply ≤ M1", tier="T2-24", model="chat-9b-q4 + img-klein q8",
             est=8, dry_est=3, result="$T05_OUT/coresident-T2-24.jsonl", needs=[PERF_APP], nfr="NFR-M3/R1"),
        Step("photo.JOB_CANCEL_FREE", "photo", "AT-291 AC3 JOB_CANCEL_FREE proxy: cancel at step 2 → memory back (-Bench cancel)",
             real=f"\"$T05_APP\"/Contents/MacOS/AntiChat -Bench cancel --quant q4 --res 1024 --runs 10 --cancel-step 2 --tier-cap T1 --prompts {fx}/images/prompts-50.json --out-dir \"$T05_OUT/image-out\" --raw \"$T05_OUT/cancel-q4-1024.jsonl\" && python3 -I tools/perf/sd-scale.py --raw-dir \"$T05_OUT\" --report \"$T05_REPORT\" --replace",
             dry=f"\"$T05_APP\"/Contents/MacOS/AntiChat -Bench cancel --quant q4 --res 768 --runs 1 --cancel-step 2 --tier-cap T1 --prompts {fx}/images/prompts-50.json --out-dir \"$T05_OUT/image-out\" --raw \"$T05_OUT/cancel-q4-768.jsonl\"",
             gpu="wrap", bar="cancel → stopped and → GPU memory freed ≤ 2 s, max of 10 (NFR-VID3; m0.cancel-stop / m0.cancel-memrecover)", tier="T1", model="img-klein q4", est=6, dry_est=2,
             result="$T05_OUT/cancel-q4-*.jsonl", needs=[PERF_APP], nfr="AT-291 AC3"),
        Step("photo.IMAGE_TURN_OVERHEAD", "photo", "AT-236 AC3 IMAGE_TURN_OVERHEAD: imageTurn − imageGen per image turn (-Bench image-turn: "
             "TurnController + MediaJobQueue, Image chip → create_image, gate, artifact, templated caption; perf log)",
             real=perf("IMAGE_TURN_OVERHEAD", "T1", 20)[0], dry=perf("IMAGE_TURN_OVERHEAD", "T1", 20, 2)[1], gpu="run.py",
             bar="p50 ≤ 2 s", tier="T1", model="chat-9b-q4 + img-klein q4 768²", est=12, dry_est=4,
             result="$T05_RUNS/*-IMAGE_TURN_OVERHEAD-T1.json", needs=[PERF_APP], nfr="AT-236 AC3"),
        Step("photo.P4.T1", "photo", "NFR-P4 edit ≤ 1.5× create, T1 klein 768² (EditTimingTests)",
             real=f"ANTICHAT_REAL_SD=1 ANTICHAT_PERF=1 ANTICHAT_FIXTURES={fx} make test-unit FILTER=EditTimingTests", gpu="wrap",
             bar="edit ≤ 1.5 × P1", tier="T1", model="img-klein q4 768²", est=5, dry_est=5, result="build/at/AT-033/real-legs.log", nfr="NFR-P4"),  # EditTimingTests appends its P4 line there
        # A-M9-T05-P4: the T3 default edit is img-klein (model-matrix §2.2; M4.md M4.T13 "Models" and its P4 fallback),
        # img-edit (qwen) is the "best edit" choice — P4 T3 is judged on the default; the qwen ratio is recorded only.
        Step("photo.P4.T3", "photo", "NFR-P4 T3 default edit (img-klein 1024², EditTimingTests)",
             real=f"ANTICHAT_REAL_SD=1 ANTICHAT_PERF=1 ANTICHAT_REAL_EDIT=klein ANTICHAT_EDIT_SIDE=1024 ANTICHAT_FIXTURES={fx} make test-unit FILTER=EditTimingTests",
             dry="echo 'dry: P4 T3 skipped; the T1 leg covers the same test path'", gpu="wrap", bar="edit ≤ 1.5 × P1", tier="T3",
             model="img-klein q4 1024²", est=8, dry_est=0, result="build/at/AT-033/real-legs.log", nfr="NFR-P4"),
        Step("photo.P4.T3-best", "photo", "img-edit (qwen) 'best edit' at 1024², edit vs create (recorded, not judged: A-M9-T05-P4; ~47 min)",
             real=f"ANTICHAT_REAL_SD=1 ANTICHAT_PERF=1 ANTICHAT_REAL_EDIT=qwen ANTICHAT_EDIT_SIDE=1024 ANTICHAT_FIXTURES={fx} make test-unit FILTER=EditTimingTests || true",
             dry="echo 'dry: qwen best-edit timing skipped (47 min)'", gpu="wrap", bar="recorded (no bar: best-edit choice)", tier="T3",
             model="img-edit (qwen) 1024²", est=50, dry_est=0, nfr="NFR-P4 (info)"),
        Step("photo.P5", "photo", "NFR-P5 remove background 1024² (Vision, 20 runs)",
             real=f"ANTICHAT_PERF=1 ANTICHAT_FIXTURES={fx} make test-unit FILTER=RemoveBackgroundTimingTests", gpu="wrap",
             bar="≤ 1.5 s S1, ≤ 1 s S2+", tier="na", est=3, dry_est=3, nfr="NFR-P5"),
        Step("photo.P3", "photo", "NFR-P3 progress never stale > 3 s (XCUITest Perf/ImageProgressPerfTests: the job card sampled every "
             "250 ms, 4 s steps; takes the foreground)",
             real="TEST_RUNNER_ANTICHAT_PERF_APP=\"$T05_APP\" TEST_RUNNER_ANTICHAT_PERF_AT_DIR=\"$T05_AT\" make test-ui FILTER=ImageProgressPerfTests", dry=UI_DRY,
             bar="max unchanged ≤ 3 s", tier="na", model="ScriptedImageEngine", est=4, dry_est=0,
             result="$T05_AT/AT-NFR-P3/perf-uitest.json", needs=[APP, PERF_APP], nfr="NFR-P3"),
        Step("photo.P2.visible", "photo", "NFR-P2 first visible preview under A-M4-R1b = the card's first visible progress "
             "state (XCUITest Perf/ImageFirstVisiblePerfTests: create_image call → dot matrix + % pill on screen, perf log "
             "`imageFirstVisible`, 10 fresh launches; takes the foreground)",
             real="TEST_RUNNER_ANTICHAT_PERF_APP=\"$T05_APP\" TEST_RUNNER_ANTICHAT_PERF_AT_DIR=\"$T05_AT\" TEST_RUNNER_ANTICHAT_PERF_RUNS=10 make test-ui FILTER=ImageFirstVisiblePerfTests",
             dry=UI_DRY, bar="p50 ≤ 1 s (S4, strictest class)", tier="na", model="ScriptedImageEngine", est=4, dry_est=0,
             result="$T05_AT/AT-NFR-P2/perf-uitest.json", needs=[APP, PERF_APP], nfr="NFR-P2"),
        Step("photo.R4-R5", "photo", "NFR-R4 resident set (ResidentSetTests) + NFR-R5 lighter fallback / refusal",
             real="make test-integration-real TIER=T1 FILTER=ResidentSetTests && make test-unit FILTER=LighterFallbackTests,OverBudgetRefusalTests",
             gpu="wrap", bar="only chat (+embed, +voice) resident; refuse before load", tier="T1", est=10, dry_est=10,
             result="build/at/AT-NFR-R4/resident-set.json", nfr="NFR-R4/R5"),
        Step("csc.F7", "csc", "NFR-F7 per-image check, full path forced (csc-bench latency, 40 CC0 photos, CoreML)",
             real=perf("F7", "T1", 20)[0], dry=perf("F7", "T1", 20, 4)[1], gpu="run.py", bar="p95 ≤ 300 ms", tier="T1",
             model="csc-nudity + Vision + MiVOLO + csc-age-bins", est=6, dry_est=4, result="$T05_RUNS/*-F7-T1.json", nfr="NFR-F7"),
        Step("csc.body-age", "csc", "A-M4-T02b body-only age model re-check (lawful proxies only; aggregates only)",
             real="python3 -I tools/csc/calibrate.py run --legs age --ep coreml && python3 -I tools/csc/calibrate.py eval --at F2 && python3 -I tools/csc/calibrate.py tables",
             # calibrate.py wraps csc-bench itself (CSC_GPU_RUN, gpu-run.sh shared): t05 adds no second wrapper (a nested
             # `gpu-run.sh shared` waits on a slot its own parent holds). The dry run checks the proxy sets exist (never
             # reads them) and that csc-bench builds.
             dry="test -d \"${CSC_PRIVATE:-$HOME/AntiChatPrivateFixtures/csc}/age\" && swift build -c release --disable-keychain "
                 "--package-path Packages/ChildSafetyCheck --product csc-bench && python3 -I tools/csc/calibrate.py tables",
             gpu=None,
             bar="adopt only if recall ≥ NFR-F2 bars AND adult ≥ 30 y false flag < 12.5 % (v1)", tier="T1", model="MiVOLO + csc-age-bins",
             est=30, dry_est=1, result="build/at/AT-NFR-F2/*.json", nfr="NFR-F2 (A-M4-T02b)"),
    ]
    # ---------------------------------------------------------------- 5. video
    S += [
        Step("video.T4", "video", "NFR-VID1/VID2 T4 default: vid-5b 1280×704 × 121 f through the app path (A-M5-13)",
             real="APP=\"$T05_APP\" tools/perf/t4-video-bench.sh t05-t4-default 3", dry="APP=\"$T05_APP\" tools/perf/t4-video-bench.sh t05-dry-t4 1",
             gpu="wrap", bar="VID1 S4 720p ≤ 90 s p50; VID2 S4 ≤ 5 s (open, A-M0-T07c)", tier="T4", model="vid-5b + vid-taehv",
             est=12, dry_est=5, result="$T05_AT/T4-video/t05-*t4*.jsonl", needs=[PERF_APP, "build/runtimes/video-runtime"], nfr="NFR-VID1/VID2"),
        # M9.T05 F7_VIDEO: the gate's time per job (the `videoGate` note of MediaJobOutputs) ÷ the job's wall time.
        Step("video.F7_VIDEO.T4", "video", "NFR-F7 video frame checks ≤ 10 % of generation time, T4 default job (the video.T4 rows)",
             real="VIDEO_RAW=$(ls -t \"$T05_AT\"/T4-video/t05-*t4*.jsonl | head -1) " + perf("F7_VIDEO", "T4", 3)[0],
             dry="VIDEO_RAW=$(ls -t \"$T05_AT\"/T4-video/t05-*t4*.jsonl | head -1) " + perf("F7_VIDEO", "T4", 3, 1)[1],
             bar="gate time ≤ 10 % per job (max)", tier="T4", model="vid-5b + csc detectors", est=0, dry_est=0,
             result="$T05_RUNS/*-F7_VIDEO-T4.json", nfr="NFR-F7"),
        Step("video.F7_VIDEO.T3", "video", "NFR-F7 video frame checks ≤ 10 % of generation time, T3-48 480p × 73 f (-Bench video, gate on)",
             real=perf("F7_VIDEO", "T3", 3)[0], dry=perf("F7_VIDEO", "T3", 3, 1)[1], gpu="run.py", bar="gate time ≤ 10 % per job (max)",
             tier="T3-48", model="vid-5b + vid-taehv + csc detectors", est=10, dry_est=4, result="$T05_RUNS/*-F7_VIDEO-T3.json",
             needs=[PERF_APP, "build/runtimes/video-runtime"], nfr="NFR-F7"),
        Step("video.T3-480p", "video", "NFR-VID1 T3/S4 480p (VideoBenignGateTests real path; S1–S3 via vid-scale.py)",
             real="ANTICHAT_REAL_VIDEO=1 ANTICHAT_VIDEO_BENIGN=1 make test-unit FILTER=VideoBenignGateTests",
             dry="ANTICHAT_REAL_VIDEO=1 ANTICHAT_VIDEO_BENIGN=1 ANTICHAT_TRACE_N=1 make test-unit FILTER=VideoBenignGateTests",
             gpu="wrap", bar="S1/S2 480p ≤ 480 s · S3 ≤ 210 s · S4 ≤ 90 s", tier="T3", model="vid-ltx / vid-5b (plan default)", est=15, dry_est=5,
             result="build/at/AT-M5-preview-fp/*.json", nfr="NFR-VID1"),
        Step("video.speed-table", "video", "AT-290 VIDEO_ESTIMATE / A-M5-10: speed table re-run (video-speed.py --run)",
             real="python3 -I tools/perf/video-speed.py --run --bin \"$T05_APP\"/Contents/MacOS/AntiChat --runtime build/runtimes/video-runtime --runs 3",
             dry="python3 -I tools/perf/video-speed.py --check", gpu="wrap", bar="estimate p80 |err| ≤ 25 %", tier="S4", est=40, dry_est=1,
             nfr="AT-290"),
        Step("video.VID3.t2v", "video", "NFR-VID3 cancel frees GPU ≤ 2 s, T2V (VideoCancelTests, 21 cancels)",
             real="ANTICHAT_REAL_VIDEO=1 ANTICHAT_VID3_N=7 make test-unit FILTER=VideoCancelTests",
             dry="ANTICHAT_REAL_VIDEO=1 ANTICHAT_VID3_N=1 make test-unit FILTER=VideoCancelTests", gpu="wrap",
             bar="p95 ≤ 2 s", tier="T3", model="vid-5b", est=20, dry_est=6, result="build/at/AT-NFR-VID3/cancel-T3.json", nfr="NFR-VID3"),
        Step("video.VID3.i2v", "video", "NFR-VID3 I2V cancel mid-denoise (cancelMidDenoiseFreesTheServerWithinTwoSeconds; never run before)",
             real="ANTICHAT_REAL_VIDEO=1 ANTICHAT_I2V=1 ANTICHAT_I2V_CANCEL=1 make test-unit FILTER=I2VRealTests/cancelMidDenoiseFreesTheServerWithinTwoSeconds",
             gpu="wrap", bar="≤ 2 s at step 2 and step 4", tier="T3", model="vid-i2v + vid-te (sd-server)", est=10, dry_est=10,
             result="build/at/AT-NFR-VID3/cancel-i2v-T3.json", needs=["build/binaries/sd-server"], nfr="NFR-VID3"),
        Step("video.B5", "video", "NFR-B5 paused for another app (XCUITest Perf/VideoPausedPerfTests: a running job + gpu-burn 30 s; "
             "takes the foreground)", real="TEST_RUNNER_ANTICHAT_PERF_APP=\"$T05_APP\" TEST_RUNNER_ANTICHAT_PERF_AT_DIR=\"$T05_AT\" make test-ui FILTER=VideoPausedPerfTests",
             dry=UI_DRY, gpu="wrap", bar="paused ≤ 12 s after the other app's GPU load; resumes after it", tier="T3",
             model="ScriptedVideoEngine + gpu-burn", est=5, dry_est=0, result="$T05_AT/AT-NFR-B5/perf-uitest.json",
             needs=[APP, PERF_APP, "build/tools/gpu-burn"], nfr="NFR-B5"),
        Step("video.B3", "video", "NFR-B3 thermal .serious throughput drop ≤ 30 %", status="blocked",
             why="no way to put the SoC in .serious on purpose; covered in-process (ThermalPolicyTests, -FakeThermal serious, build/at/AT-041)"),
    ]
    # ---------------------------------------------------------------- 6. search
    S += [
        Step("search.e2e.T1", "search", "AT-248 c1 search answer complete + <web_results> prefill tokens (search-e2e, live engines)",
             real=perf("search-e2e", "T1", 20)[0], dry=perf("search-e2e", "T1", 20, 1)[1], gpu="run.py", bar="p50 ≤ 12 s; ≥ 2 pills",
             tier="T1", model="chat-9b-q4 + embed", est=22, dry_est=3, result="$T05_RUNS/*-search_e2e-T1.json", needs=[BENCH, PERF_APP], nfr="R-248 AC1"),
        Step("search.ttft.T1", "search", "AT-254 first answer token after search, 20 availability queries", real=perf("search", "T1", 20)[0],
             dry=perf("search", "T1", 20, 1)[1], gpu="run.py", bar="p50 ≤ 8 s", tier="T1", model="chat-9b-q4", est=22, dry_est=3,
             result="$T05_RUNS/*-search-T1.json", needs=[BENCH, PERF_APP], nfr="R-254"),
        Step("search.ttft.T3", "search", "AT-254 at T3", real=perf("search", "T3", 20)[0], dry=perf("search", "T3", 20, 1)[1], gpu="run.py",
             bar="p50 ≤ 5 s", tier="T3", model="chat-35b-q4", est=18, dry_est=3, result="$T05_RUNS/*-search-T3.json", needs=[BENCH, PERF_APP], nfr="R-254"),
        Step("search.AT-266", "search", "AT-266 tool selection T2 / T0 (embed only)",
             real=f"for t in T2 T0; do {BENCH} tool-select --tools {fx}/tools/forty-tools.json --fixture {fx}/prompts/tool-select-200.jsonl --tier $t --out \"$T05_AT/AT-266/t05-$t.json\" || exit 1; done",
             gpu="wrap-shared", bar="T2 ≥ 0.85", tier="T2/T0", model="embed", est=2, dry_est=2, result="$T05_AT/AT-266/t05-T2.json", needs=[BENCH], nfr="AT-266"),
    ]
    # ---------------------------------------------------------------- 7. downloads / install / privacy
    S += [
        # gpu="self": `-Bench firstchat` takes the GPU lock itself (BenchMode.gpuLock, flock on /tmp/antichat-gpu.lock);
        # under gpu-run.sh timing, which already holds that lock, it waited on itself forever (T05 A8, 2026-11-12).
        Step("m5.50mbps", "install", "NFR-M5 fast first chat at 50 Mbps, 20 runs (-Bench firstchat)",
             real="\"$T05_APP\"/Contents/MacOS/AntiChat -Bench firstchat --rate 50 --runs 20 --raw \"$T05_OUT/firstchat-50.jsonl\"",
             dry="\"$T05_APP\"/Contents/MacOS/AntiChat -Bench firstchat --rate 50 --runs 1 --raw \"$T05_OUT/firstchat-50.jsonl\"",
             gpu="self", bar="p50 ≤ 120 s", tier="T1", model="starter chat-0.8b (real HF download)", est=45, dry_est=3,
             result="$T05_OUT/firstchat-50.jsonl", needs=[PERF_APP], nfr="NFR-M5"),
        # M9.T05: the bar's full run count (20, as at 50 Mbps), not 5: ≈ 9 min per run → ≈ 3 h; run it on its own day slot.
        Step("m5.10mbps", "install", "NFR-M5 at 10 Mbps [EMULATED] (in-app token bucket), 20 runs",
             real="\"$T05_APP\"/Contents/MacOS/AntiChat -Bench firstchat --rate 10 --runs 20 --raw \"$T05_OUT/firstchat-10.jsonl\"",
             dry="echo 'dry: 10 Mbps leg skipped (9 min per run); same code path as m5.50mbps'", gpu="self", bar="p50 ≤ 600 s", tier="T1",
             est=185, dry_est=0, result="$T05_OUT/firstchat-10.jsonl", needs=[PERF_APP], nfr="NFR-M5"),
        Step("d3.real", "install", "NFR-D3 real bytes, default install (all eligible packs) on a fresh dev container, T1",
             real="ONB_PROBE_ALL_PACKS=1 TIER=T1 IDLE_MIN=0 tools/at/at-209-destinations.sh && D3=1 tools/at/at-nfr-d3d4-real.sh $(ls -td /tmp/antichat-dest.* | head -1) T1 > \"$T05_OUT/d3-T1.json\"",
             dry="echo 'dry: D3 needs ~12 GB of real downloads; probe option ONB_PROBE_ALL_PACKS=1 + D3=1 added (M9.T05 prep)'",
             gpu="wrap", bar="T1 ≤ 15 GB; store within 1 % of the catalog", tier="T1", est=40, dry_est=0, result="$T05_OUT/d3-T1.json", needs=[APP], nfr="NFR-D3"),
        # M9.T05: the 30-min capture with journeys 2/7/8 looped by XCUITest (Perf/PR1JourneyLoopTests, attach mode) on the
        # app run-offline.sh starts under the deny-outbound sandbox. The app runs from a copy (make test-ui rebuilds
        # build/AntiChat.app), in the foreground (ANTICHAT_BACKGROUND=0) with the journeys' arguments after `--`.
        Step("pr1.capture", "install", "NFR-PR1 30-min Offline-only capture (nettop + lsof leg) with journeys 2/7/8 looped (XCUITest "
             "attach; takes the foreground)",
             real="rm -rf \"$T05_OUT/pr1-app\" && mkdir -p \"$T05_OUT/pr1-app\" && cp -R build/AntiChat.app \"$T05_OUT/pr1-app/\" && "
                  "(pr1_end=$(( $(date +%s) + 30 * 60 - 120 )); APP=\"$T05_OUT/pr1-app/AntiChat.app\" ANTICHAT_BACKGROUND=0 MINUTES=30 tools/offline/capture-30min.sh -- -SkipOnboarding YES "
                  f"-UseScriptedEngine {fx}/scripts/regen.jsonl -FakeEvilEnabled YES & cap=$!; sleep 25; "
                  "TEST_RUNNER_ANTICHAT_ATTACH=1 TEST_RUNNER_ANTICHAT_ATTACH_APP=\"$T05_OUT/pr1-app/AntiChat.app\" TEST_RUNNER_ANTICHAT_PR1_MINUTES=27 TEST_RUNNER_ANTICHAT_PR1_DEADLINE=$pr1_end TEST_RUNNER_ANTICHAT_PERF_AT_DIR=\"$T05_AT\" "
                  "make test-ui FILTER=PR1JourneyLoopTests; ui=$?; wait $cap; c=$?; echo \"capture rc $c, journeys rc $ui\"; "
                  "rm -rf \"$T05_OUT/pr1-app\"; [ $c -eq 0 ] && [ $ui -eq 0 ])",
             dry="MINUTES=1 make test-offline FILTER=capture", bar="zero outbound connections; every journey ran", tier="T1", est=36, dry_est=3,
             result="build/at/AT-NFR-PR1/*", needs=[APP], nfr="NFR-PR1"),
        Step("pr1.tcpdump", "install", "NFR-PR1 tcpdump leg", status="owner",
             why="tcpdump needs root (/dev/bpf*, Q-028): capture-30min.sh records the pcap when `sudo -n` works, else "
                 "\"not run: permission\" (the nettop + lsof leg and the journeys run in pr1.capture)"),
    ]
    # ---------------------------------------------------------------- 8. memory / stability / files
    S += [
        Step("r1.soak.T1", "memory", "NFR-R1 mini-soak T1 60 min (real chat + Evil + image jobs)", real="tools/soak/mini-soak.sh --tier T1 --minutes 60 && " + perf("R1", "T1", 1)[0],
             dry="tools/soak/mini-soak.sh --tier T1 --minutes 2", gpu="soak", bar="peak ≤ 9.5 GB; 0 crashes / jetsam", tier="T1",
             model="chat-9b-q4 + evil-9b", est=62, dry_est=4, result="build/at/AT-206/soak-T1.json", needs=[BENCH, PERF_APP], nfr="NFR-R1"),
        Step("r1.soak.T2-24", "memory", "NFR-R1 mini-soak T2-24 60 min", real="tools/soak/mini-soak.sh --tier T2-24 --minutes 60 && " + perf("R1", "T2-24", 1)[0],
             dry="echo 'dry: same driver as r1.soak.T1'", gpu="soak", bar="peak ≤ 16 GB", tier="T2-24", est=62, dry_est=0,
             result="build/at/AT-206/soak-T2-24.json", needs=[BENCH, PERF_APP], nfr="NFR-R1"),
        Step("r1.soak.T0", "memory", "NFR-R1 mini-soak T0 30 min", real="tools/soak/mini-soak.sh --tier T0 --minutes 30 && " + perf("R1", "T0", 1)[0],
             dry="echo 'dry: same driver as r1.soak.T1'", gpu="soak", bar="peak ≤ 4.0 GB", tier="T0", est=32, dry_est=0,
             result="build/at/AT-206/soak-T0.json", needs=[BENCH, PERF_APP], nfr="NFR-R1"),
        Step("r1.soak.T3-48", "memory", "NFR-R1 mini-soak T3-48 60 min (chat-35b-q4 + evil-35b-q4 + 6.0 GB image jobs; chat co-resides)",
             real="tools/soak/mini-soak.sh --tier T3-48 --minutes 60 && " + perf("R1", "T3-48", 1)[0],
             dry="tools/soak/mini-soak.sh --tier T3-48 --minutes 2 --no-evil", gpu="soak", bar="peak ≤ 36 GB; 0 crashes / jetsam",
             tier="T3-48", model="chat-35b-q4 + evil-35b-q4", est=62, dry_est=4, result="build/at/AT-206/soak-T3-48.json",
             needs=[BENCH, PERF_APP], nfr="NFR-R1"),
        Step("stepaside", "memory", "Scheduler StepAside ≤ 1 s unload with the real model", real="make test-integration-real TIER=T1 FILTER=StepAsideRealTests",
             gpu="wrap", bar="unload ≤ 1 s", tier="T1", est=8, dry_est=8, result="build/at/AT-206/step-aside-real.json", nfr="NFR-M3/StepAside"),
        Step("files.warm", "memory", "Warm document: pressure release ≤ 2 s (antichat-bench files-warm; real memory_pressure needs root)",
             real=f"{BENCH} files-warm --doc {fx}/docs/warm-10k.pdf --followups {fx}/docs/warm-10k-followups.jsonl --tier T2 --runs 20 --out \"$T05_AT/AT-279/t05-files-warm.json\"",
             dry=f"{BENCH} files-warm --doc {fx}/docs/warm-10k.pdf --followups {fx}/docs/warm-10k-followups.jsonl --tier T2 --runs 1 --out \"$T05_AT/AT-279/t05-files-warm.json\"",
             gpu="wrap", bar="release ≤ 2 s; peak ≤ B", tier="T2", model="chat-9b-q4", est=8, dry_est=3,
             result="$T05_AT/AT-279/t05-files-warm.json", needs=[BENCH, PERF_APP], nfr="NFR-M4 / AT-279"),
        Step("files.spreadsheet", "files", "AT-273 full 150-prompt create_spreadsheet model run (5 files × 30)",
             real=f"{BENCH} fileout-golden --set {fx}/prompts/fileout-golden --tier T1 --model chat-9b-q4 --out \"$T05_AT/AT-273/t05/model\"",
             dry=f"{BENCH} fileout-golden --set {fx}/prompts/fileout-golden --tier T1 --model chat-9b-q4 --limit 1 --out \"$T05_AT/AT-273/t05/model\"",
             gpu="wrap-shared", bar="AT-273 check 5", tier="T1", model="chat-9b-q4", est=60, dry_est=3,
             result="$T05_AT/AT-273/t05/model/*", needs=[BENCH, PERF_APP], nfr="AT-273"),
        Step("files.presentation", "files", "AT-275 full 20 create_presentation run",
             real=f"{BENCH} fileout-golden --set {fx}/prompts/pptx-golden-20.jsonl --tier T1 --model chat-9b-q4 --out \"$T05_AT/AT-275/t05/model\"",
             dry=f"{BENCH} fileout-golden --set {fx}/prompts/pptx-golden-20.jsonl --tier T1 --model chat-9b-q4 --limit 1 --out \"$T05_AT/AT-275/t05/model\"",
             gpu="wrap-shared", bar="AT-275 1c", tier="T1", model="chat-9b-q4", est=20, dry_est=3,
             result="$T05_AT/AT-275/t05/model/*", needs=[BENCH, PERF_APP], nfr="AT-275"),
    ]
    # ---------------------------------------------------------------- 9. report
    S += [
        Step("report.compare", "report", "compare vs main (informational: every baseline before 2026-11-09 20:00 was measured in Low Power Mode)",
             real="python3 -I tools/perf/compare.py --baseline-ref main --json \"$T05_OUT/compare.json\" || true",
             dry="python3 -I tools/perf/compare.py --baseline-ref main --json \"$T05_OUT/compare.json\" || true", est=1, dry_est=1),
    ]
    return S


TIER_CAPS = {"T2": "T2-24", "T3": "T3-48"}
# Steps whose dry variant runs no model (structural check only): never queued on the GPU in a dry run.
DRY_CPU_ONLY = {"csc.body-age", "video.speed-table"}
# M9.T05 prep (lead, 2026-11-09): the reduced dry run — every step that needs no GPU, plus the cheapest GPU probe per
# family (chat C1 T0 was proven in the first dry run). `t05.py run --dry --reduced`.
# M9.T05 phase B (lead, 2026-11-11): steps whose pass criteria are not timing (bytes, crashes/jetsam/peak memory,
# accuracy, zero network bytes) may run beside the M9.T06 soak: `t05.py run --overlap` (OVERLAP=1). No quiet gate; GPU
# work queues as `gpu-run.sh shared` (as the soak does); every record labelled `overlapped`. Timing steps are refused.
OVERLAP_OK = {"d3.real", "voice.V9", "r1.soak.T1", "r1.soak.T2-24", "r1.soak.T0", "r1.soak.T3-48", "files.spreadsheet",
              "files.presentation", "pr1.capture"}
REDUCED_GPU = ["chat.U3.T1", "voice.V7.T1", "photo.P1.bench", "video.T4", "search.e2e.T1"]


def needs_gpu(st: "Step") -> bool:
    return bool(st.gpu) and not (st.id in DRY_CPU_ONLY or (st.dry or "").startswith("echo "))


# ---------------------------------------------------------------- runner

def sh_out(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def tracked_dirty() -> set[str]:
    out = sh_out(["git", "-C", ROOT, "status", "--porcelain", "--untracked-files=all", "--", "build"])
    return {l[3:] for l in out.splitlines() if l.strip() and not l[3:].startswith(("build/perf/t05-dry/", "build/perf/t05/"))}


def quiet_gate(wait: float, allow_noisy: bool, gpu: bool) -> tuple[bool, dict]:
    deadline = time.time() + wait
    while True:
        s = loadmod.sample()
        v = loadmod.verdict([s], gpu)
        if v["quality"] == "clean" or allow_noisy:
            return True, {"load1": s.get("load1"), "quality": v["quality"], "reasons": v["reasons"]}
        if time.time() >= deadline:
            return False, {"load1": s.get("load1"), "quality": v["quality"], "reasons": v["reasons"]}
        print(f"  [wait] busy: {'; '.join(v['reasons'])}", flush=True)
        time.sleep(30)


def expand(path: str, env: dict) -> list[str]:
    p = path
    for k in ("T05_RUNS", "T05_OUT", "T05_AT", "ANTICHAT_FIXTURES"):
        p = p.replace("$" + k, env[k])
    p = p if os.path.isabs(p) else os.path.join(ROOT, p)
    return glob.glob(p)


def run_plan(a) -> int:
    plan = steps()
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = os.path.join(ROOT, "build/perf", ("t05-dry/" if a.dry else "t05/") + stamp)
    os.makedirs(out, exist_ok=True)
    env = dict(os.environ)
    env.setdefault("ANTICHAT_FIXTURES", os.path.join(ROOT, "fixtures"))
    env["DEV_MODELS"] = DEV_MODELS
    env["T05_OUT"] = out
    env["T05_REPORT"] = os.path.join(out, "report.json") if a.dry else os.path.join(ROOT, "build/perf/report.json")
    env["T05_RUNS"] = os.path.join(out, "runs") if a.dry else os.path.join(ROOT, "build/perf/runs")
    env["ANTICHAT_PERF_RUNS_DIR"] = env["T05_RUNS"]
    env["T05_AT"] = os.path.join(out, "at") if a.dry else os.path.join(ROOT, "build/at")
    env["T05_APP"] = os.path.abspath(a.app)
    env["SOAK_APP"] = env["T05_APP"]  # mini-soak.sh
    env["T05_U1_APP"] = os.path.abspath(a.u1_app or a.app)
    env["ANTICHAT_GPU_MODE"] = "shared" if a.dry else "timing"
    if a.overlap:
        env["ANTICHAT_GPU_MODE"] = "shared"  # mini-soak / run.py probes queue as shared GPU jobs beside the soak
    if not a.dry:
        env["ANTICHAT_PERF_FOREGROUND"] = "1"  # U1: a real foreground launch (takes focus; the owner is away for T05)
    flags = []
    if a.allow_noisy:
        flags.append("--allow-noisy")
    if not a.dry:
        # T05 re-measures every pre-2026-11-09 (Low Power Mode) entry: its result replaces the old key. run.py still
        # never lets a noisy/invalid entry replace a valid one.
        flags += ["--wait-quiet", str(int(a.wait_quiet)), "--replace"]
    env["T05_PERF_FLAGS"] = " ".join(flags)
    if a.dry:
        env.setdefault("VIDEO_INSTALLED", env.get("VIDEO_INSTALLED", os.path.join(ROOT, "build/perf/t4models")))
        env["OUT"] = os.path.join(out, "at/T4-video")
    os.makedirs(env["T05_RUNS"], exist_ok=True)
    sel = select(plan, a)
    print(f"T05 {'DRY (NOISY/DRY numbers are not results)' if a.dry else 'RUN'}: {len(sel)} steps → {os.path.relpath(out, ROOT)}")
    baseline_dirty = tracked_dirty()
    results = []
    for st in sel:
        rec = {"id": st.id, "group": st.group, "title": st.title, "nfr": st.nfr, "bar": st.bar, "tier": st.tier, "model": st.model,
               "gpu": st.gpu, "est_min": st.dry_est if a.dry else st.est}
        t0 = time.time()
        print(f"\n== {st.id}: {st.title}", flush=True)
        if st.status in ("owner", "blocked"):
            rec.update(status=st.status, why=st.why)
            print(f"  [{st.status}] {st.why}")
            results.append(rec)
            continue
        missing = [n for n in st.needs if not os.path.exists(os.path.join(ROOT, n))]
        if missing:
            rec.update(status="missing-prereq", why="missing " + ", ".join(missing))
            print(f"  [missing-prereq] {rec['why']}")
            results.append(rec)
            continue
        cmd = st.dry if a.dry else st.real
        gpu = st.gpu or ""
        if a.dry and (st.id in DRY_CPU_ONLY or cmd.startswith("echo ")):
            gpu = ""  # the dry variant touches no model: no GPU queue
        if a.overlap:
            if st.id not in OVERLAP_OK:
                rec.update(status="refused", why="timing step: never run beside the soak (--overlap)")
                print(f"  [refused] {rec['why']}")
                results.append(rec)
                continue
            rec["overlapped"] = True  # beside the M9.T06 soak: non-timing criteria only
            if gpu.startswith("wrap"):  # shared GPU slot beside the soak (gpu-run.sh shared), never the timing lock
                cmd = f"{shlex.quote(GPU_RUN)} shared -- /bin/bash -c {shlex.quote(cmd)}"
        elif gpu.startswith("wrap"):
            mode = "shared" if (a.dry or gpu == "wrap-shared") else "timing"
            cmd = f"{shlex.quote(GPU_RUN)} {mode} -- /bin/bash -c {shlex.quote(cmd)}"
        if gpu not in ("run.py",) and st.group != "prep" and not a.overlap:  # run.py gates itself (and records the load per metric)
            ok, load = quiet_gate(0 if a.dry else a.wait_quiet, a.allow_noisy, gpu != "")
            rec["load_before"] = load
            if not ok:
                rec.update(status="refused", why="machine not quiet: " + "; ".join(load["reasons"]))
                print(f"  [refused] {rec['why']}")
                results.append(rec)
                continue
        log = os.path.join(out, "logs", st.id + ".log")
        os.makedirs(os.path.dirname(log), exist_ok=True)
        print(f"  $ {cmd}", flush=True)
        with open(log, "w") as fh:
            fh.write(f"# {st.id} {dt.datetime.now(dt.timezone.utc).isoformat()} load {os.getloadavg()}\n# $ {cmd}\n")
            fh.flush()
            p = subprocess.run(["/bin/bash", "-c", cmd], cwd=ROOT, env=env, stdout=fh, stderr=subprocess.STDOUT)
        rc = p.returncode
        # A measurement must write its result now; a prep step is idempotent (an existing artefact counts).
        check = st.result and not (a.dry and (st.id in DRY_CPU_ONLY or cmd.startswith("echo ")))  # a structural dry check writes no result
        files = [f for f in expand(st.result, env) if st.group == "prep" or os.path.getmtime(f) >= t0 - 1] if check else []
        rec.update(rc=rc, minutes=round((time.time() - t0) / 60, 2), log=os.path.relpath(log, ROOT),
                   results=[os.path.relpath(f, ROOT) for f in files][:10], load_after=os.getloadavg()[0])
        if rc == 75 or rc == 5:
            rec["status"] = "deferred"
        elif rc == 3:
            rec["status"] = "refused"
        elif rc == 2 and "run.py" in (st.gpu or "") and "[forward]" in open(log).read():
            rec["status"] = "blocked"
        elif rc in (0, 1) and files and empty_samples(files):
            rec["status"] = "error"
            rec["why"] = "the probe ran but produced no samples (n = 0 in every entry)"
        elif rc in (0, 1) and (files or not check):
            rec["status"] = "ok" if rc == 0 else "fail"
            if rc == 1:
                rec["why"] = "measured; a bar failed (see log / report)"
        else:
            rec["status"] = "error"
            tail = open(log).read().splitlines()[-6:]
            rec["why"] = (f"exit {rc}" + ("" if files or not check else "; no result file") + " | " + " / ".join(tail))[-600:]
        print(f"  [{rec['status']}] {rec.get('minutes')} min; results {rec['results'] or '-'}" + (f"; {rec.get('why')}" if rec.get("why") else ""))
        results.append(rec)
        save_summary(out, a, results, plan)
        if st.hard and rec["status"] != "ok" and not a.dry:
            print(f"\n[abort] hard precondition {st.id} not met; nothing else runs (see {rec['log']})")
            break
    if a.dry:
        quarantine(out, baseline_dirty)
    save_summary(out, a, results, plan)
    bad = [r for r in results if r["status"] in ("error", "missing-prereq")]
    print(f"\nsummary → {os.path.relpath(out, ROOT)}/summary.md; " + ", ".join(f"{k} {sum(1 for r in results if r['status'] == k)}"
          for k in ("ok", "fail", "error", "refused", "deferred", "missing-prereq", "owner", "blocked")))
    return 1 if bad else 0


def empty_samples(files: list[str]) -> bool:
    """True when every run.py run record among `files` measured nothing (a probe that runs but never samples)."""
    seen = False
    for f in files:
        try:
            d = json.load(open(f))
        except (OSError, ValueError):
            continue
        if isinstance(d, dict) and isinstance(d.get("entries"), dict):
            seen = True
            if any(e.get("n", 0) > 0 for e in d["entries"].values()):
                return False
    return seen


def quarantine(out: str, before: set[str]):
    """Dry run: every build/ file a step rewrote or created moves into the dry dir; tracked ones are restored."""
    after = tracked_dirty()
    changed = sorted(after - before)
    if not changed:
        return
    tracked = set(sh_out(["git", "-C", ROOT, "ls-files", "--", *changed]).split())
    dest = os.path.join(out, "quarantine")
    for rel in changed:
        src = os.path.join(ROOT, rel)
        if os.path.isfile(src):
            os.makedirs(os.path.dirname(os.path.join(dest, rel)), exist_ok=True)
            shutil.copy2(src, os.path.join(dest, rel))
            if rel not in tracked:
                os.remove(src)
    if tracked:
        subprocess.run(["git", "-C", ROOT, "checkout", "--", *sorted(tracked)], check=False)
    print(f"[dry] {len(changed)} build/ file(s) written by steps → {os.path.relpath(dest, ROOT)} ({len(tracked)} tracked restored)")


def save_summary(out: str, a, results: list[dict], plan: list[Step]):
    data = {"mode": "dry" if a.dry else "run", "label": "NOISY/DRY — not results" if a.dry else "T05",
            "date": dt.datetime.now(dt.timezone.utc).isoformat(), "commit": sh_out(["git", "-C", ROOT, "rev-parse", "--short=12", "HEAD"]).strip(),
            "steps": results}
    with open(os.path.join(out, "summary.json"), "w") as fh:
        json.dump(data, fh, indent=1)
    lines = [f"# T05 {'DRY RUN — NOISY/DRY, not results' if a.dry else 'run'} ({data['date'][:19]}Z, {data['commit']})", "",
             "| step | status | min | load before → after | results / why |", "|---|---|---|---|---|"]
    for r in results:
        lb = r.get("load_before", {}).get("load1") if isinstance(r.get("load_before"), dict) else None
        la = r.get("load_after")
        load = f"{lb:.0f} → {la:.0f}" if isinstance(lb, (int, float)) and la else (f"→ {la:.0f}" if la else "")
        what = ", ".join(r.get("results") or []) or r.get("why", "")
        lines.append(f"| {r['id']} | {r['status']} | {r.get('minutes', '')} | {load} | {what.replace('|', '/')[:300]} |")
    with open(os.path.join(out, "summary.md"), "w") as fh:
        fh.write("\n".join(lines) + "\n")


def reduced(plan: list[Step]) -> list[Step]:
    """Every step that needs no GPU (owner/blocked rows print their reason), plus REDUCED_GPU; an ingest step runs
    only when its producer is in the selection (V6 reads V7's raw; V1b/V2/V283 read V1's)."""
    keep = {s.id for s in plan if s.status or not needs_gpu(s)} | set(REDUCED_GPU)
    keep.discard("prep.build-debug")  # built separately; a full Debug build is not a probe
    for s in plan:
        for met in ("V1b", "V2", "V283_EOS_FINAL"):
            if s.id.startswith(f"voice.{met}.") and f"voice.V1.{s.id.rsplit('.', 1)[1]}" not in keep:
                keep.discard(s.id)
        if s.id.startswith("voice.V6.") and s.id.replace("V6", "V7") not in keep:
            keep.discard(s.id)
    return [s for s in plan if s.id in keep]


def select(plan: list[Step], a) -> list[Step]:
    sel = reduced(plan) if getattr(a, "reduced", False) else plan
    if a.only:
        keys = set(a.only.split(","))
        sel = [s for s in sel if s.id in keys or s.group in keys or any(s.id.startswith(k + ".") for k in keys)]
    if a.skip:
        keys = set(a.skip.split(","))
        sel = [s for s in sel if s.id not in keys and s.group not in keys]
    if a.from_:
        ids = [s.id for s in sel]
        if a.from_ not in ids:
            raise SystemExit(f"--from {a.from_}: not in the selection")
        sel = sel[ids.index(a.from_):]
    return sel


def list_plan(a) -> int:
    if a.pending:
        done = {s.id for s in reduced(steps())} | {"chat.C1.T0"}
        print("| step | GPU | exact T05 command |")
        print("|---|---|---|")
        for s in steps():
            if s.id not in done and not s.status and s.group != "prep":
                print(f"| `{s.id}` | {s.gpu or '—'} | `{s.real.replace('|', '¦')}` |")
        return 0
    plan = select(steps(), a)
    if a.md:
        print("| # | step | what | bar | tier | model | GPU | est. min | result |")
        print("|---|---|---|---|---|---|---|---|---|")
        for i, s in enumerate(plan, 1):
            gpu = {"run.py": "timing (run.py)", "wrap": "timing", "wrap-shared": "shared", "soak": "timing (mini-soak)"}.get(s.gpu or "", "—")
            what = s.title + (f" **[{s.status}]** {s.why}" if s.status else "")
            print(f"| {i} | `{s.id}` | {what.replace('|', '/')} | {s.bar.replace('|', '/')} | {s.tier} | {s.model} | {gpu} | "
                  f"{s.est if not s.status else '—'} | {('`' + s.result + '`') if s.result else ''} |")
    else:
        for s in plan:
            print(f"{s.id:28s} {s.status or s.gpu or '-':12s} {s.est:4d} min  {s.title}")
    run_est = sum(s.est for s in plan if not s.status)
    dry_est = sum(s.dry_est for s in plan if not s.status)
    print(f"\n{len(plan)} steps; estimated wall time T05 {run_est} min ≈ {run_est / 60:.1f} h (plus quiet-gate waits); dry run ≈ {dry_est} min")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", nargs="?", default="list", choices=["list", "run"])
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--md", action="store_true")
    ap.add_argument("--dry", action="store_true", default=os.environ.get("DRY") == "1")
    ap.add_argument("--allow-noisy", action="store_true", default=os.environ.get("ALLOW_NOISY") == "1")
    ap.add_argument("--only", default=os.environ.get("T05_ONLY"))
    ap.add_argument("--skip", default=os.environ.get("T05_SKIP"))
    ap.add_argument("--from", dest="from_", default=os.environ.get("T05_FROM"))
    ap.add_argument("--overlap", action="store_true", default=os.environ.get("OVERLAP") == "1",
                    help="phase B: only the non-timing steps (OVERLAP_OK), beside the soak: no quiet gate, no GPU lock")
    ap.add_argument("--reduced", action="store_true", help="dry run: non-GPU steps + one cheap GPU probe per family")
    ap.add_argument("--pending", action="store_true", help="list: GPU steps not exercised by --reduced (markdown)")
    ap.add_argument("--wait-quiet", type=float, default=float(os.environ.get("PERF_WAIT") or 1800))
    ap.add_argument("--app", default=os.environ.get("T05_APP", os.path.join(ROOT, PERF_APP)),
                    help="the app every timed probe measures (default the perf-harness build, make build-perf)")
    ap.add_argument("--u1-app", default=os.environ.get("U1_APP"),
                    help="app for U1/B1 (default --app, the perf-harness build)")
    a = ap.parse_args(argv)
    if a.list or a.cmd == "list":
        return list_plan(a)
    return run_plan(a)


if __name__ == "__main__":
    raise SystemExit(main())
