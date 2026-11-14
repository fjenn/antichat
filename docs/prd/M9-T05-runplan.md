# M9.T05 run plan: quiet-machine re-measure of every NFR and every deferred item

**Status:** ready (prepared 2026-11-09 on `m9/t05-prep`; drivers for every NFR step added 2026-11-10 on `m9/t05-drivers`, §5b; dry-run and smoke results below are NOISY/DRY, never results).
**Entry point:** `make perf-all` = `python3 -I tools/perf/t05.py run`. The step list in `tools/perf/t05.py` is the
source of truth; the table below is its output (`make perf-all LIST=1`, regenerate after editing the steps).
**Inputs:** M9.md T05, M9-card "Deferred to M9.T05", HANDOFF "Deferred to M9.T05", the 2026-11-09 audit (REMAINING.md).

## 1. Before you start (hard preconditions)

1. **No other tracks running.** T05 is the only agent on the Mac (M9-card "T05 load rule").
2. **Low Power Mode off — the owner does this, never an agent.** This Mac had `powermode 1` on AC *and* battery
   until 2026-11-09 ≈ 20:00 (`pmset -g custom`), which throttles CPU/GPU (≈ 5× on the GPU per the lead; ≈ 2.7× slower
   timing seen by another track). The owner turned it off then (`powermode 0`, verified). **Every timing number
   recorded before 2026-11-09 ≈ 20:00 (all of `build/perf/report.json`, `build/perf/runs/`, `build/at/*` timing legs,
   the M0–M8 reports and amendments) was taken under Low Power Mode and is re-measured here;** none of them is a
   baseline for `compare.py` regressions (compare against bars only, or against a T05 run). If it is ever on again:
   `sudo pmset -c powermode 0` (or System Settings › Battery › Low Power Mode: *Only on Battery* / *Never*).
   `prep.power` (`tools/perf/power-mode.sh --require-off`) aborts the whole run while it is on, and `tools/perf/load.py`
   now records `power_mode` in every sample and marks any measurement taken in Low Power Mode **noisy**.
3. AC power, `pmset -g therm` nominal, Spotlight idle (`mdutil -s /`), no other GPU apps, a reboot before the run
   (M9.md T05 step 1). `prep.machine` records all of it in `build/perf/t05/<stamp>/load-start.json`.
4. ≥ 60 GB free disk (`prep.disk`); T4 video install adds ≈ 38 GB (`build/perf/t4models`), D3 real bytes ≈ 12 GB in
   `/tmp/antichat-dest.*` (delete it by its literal path afterwards).
5. Owner grants that unlock the `owner` rows (optional for T05 itself, required before M9.T10): Q-015 XCUITest
   automation (`sudo DevToolsSecurity -enable` + automationmodetool), sudo for tcpdump / `purge` / fs_usage (Q-028).
   Without `sudo -n purge`, U1 / M1 / U3 are labelled warm-ish / `[WARM-CACHE]` (PRD §1.5: never wait for sudo).

## 2. How it runs

```
make perf-all LIST=1                     # the plan with estimates
make perf-all                            # T05 proper → build/perf/report.json, build/at/…, build/perf/t05/<stamp>/summary.md
make perf-all FROM_STEP=voice.V7.T1        # resume after an interruption (steps are idempotent; run.py is append-only)
make perf-all STEPS=video SKIP_STEPS=video.speed-table
make perf-all DRY=1 REDUCED=1 ALLOW_NOISY=1  # dry run (cheap settings; everything under build/perf/t05-dry/<stamp>/)
```

- **Quiet gate.** `tools/perf/run.py` steps gate themselves (`load.py`: 1-min load ≤ 1.0/CPU, other processes
  ≤ 2 cores, GPU ≤ 10 % busy, AC, nominal thermal, **no Low Power Mode**), waiting up to `PERF_WAIT` (default
  1800 s) and then refusing (exit 3 → status `refused`). Other GPU steps are gated by `t05.py` with the same verdict.
  A refused step is re-run later with `STEPS=<id>`; a bar is never relaxed for load.
- **GPU.** Real mode: every GPU step runs under `~/AntiChat-tools/gpu-run.sh timing` (exclusive, waits for
  load < 40, exit 75 → status `deferred`). `run.py` probes wrap themselves (`ANTICHAT_GPU_MODE`, `gpu_prefix()`),
  other steps are wrapped by `t05.py`; accuracy-only steps (V4, V9, AT-266, file-tool model runs, body-age) use
  `shared`. Inside an outer `gpu-run.sh timing`, probes take no second lock (a nested `lockf` on the same lock waited
  forever before this prep).
- **Where results go.** `run.py` metrics → `build/perf/report.json` (`metrics.<ID>.<tier>`, append-only; a noisy
  entry never replaces a clean one) + one run record per attempt in `build/perf/runs/`; raw rows in
  `build/perf/raw/m1/`; test-driven legs write their usual `build/at/<AT>/` artefacts; per-step logs and the summary
  in `build/perf/t05/<stamp>/{logs/,summary.md,summary.json}`. After the run: `report.compare` (vs main), then the
  AT-221 compare (M9.md T05 "Acceptance tests") and the M9 report.
- **Builds.** Debug app (`make build`, needed by ScriptedVoice / `-Bench` / probes; numbers from it are
  `valid=false` where the probe checks the build), release `antichat-bench` (`make bench-release`, NDEBUG), staged
  helper binaries, the video runtime, `gpu-burn`, dev models (`make models-dev TIER=T0|T1|T3|evil-T1|evil-T3`; V9
  also needs `stt-multi` from the m0 manifest).

## 3. Order and estimated wall time

Groups run in this order (cheap/independent first, long soaks and downloads last so an interruption costs least):
prep → chat (C1/C1b/C2/C4 × T0–T3, M1, C7, U3) → UI (U1, U9, B1, U5) → voice (V1–V11, V283) → photo + CSC
(P1/P2/P4/P5, M3, JOB_CANCEL_FREE proxy, R4/R5, F7, body-age) → video (T4 default, T3 480p, speed table, VID3 T2V +
I2V) → search (AT-248 c1 + `<web_results>` tokens, AT-254 T1/T3, AT-266) → install/privacy (M5 50/10 Mbps, D3 real
bytes, PR1 capture) → memory/files (R1 soaks T1/T2-24/T0, StepAside, warm-document, AT-273/AT-275 model runs) →
compare.

| group | est. min |
|---|---|
| prep (builds, models, checks) | 68 |
| chat | 127 |
| UI (incl. the XCUITest perf legs) | 32 |
| voice (V8 / V11 now per tier) | 111 |
| photo + CSC (incl. IMAGE_TURN_OVERHEAD, P3) | 161 |
| video (incl. F7_VIDEO T4/T3, B5) | 112 |
| search | 64 |
| install / privacy (M5 50 Mbps + **10 Mbps × 20 ≈ 3 h**, D3, PR1 with journeys) | 306 |
| memory / files (soaks T1/T2-24/T0/**T3-48**, StepAside, file tools) | 314 |
| **total** | **≈ 1296 min ≈ 21.6 h** + quiet-gate waits |

Recommended split (m9/t05-drivers): **day 1** prep → search (≈ 11.5 h), **day 2** install/privacy (≈ 5 h, M5 10 Mbps
alone ≈ 3 h) **day 3** memory/files → compare (≈ 5.5 h), each after a reboot. Expect re-runs of single
refused/deferred steps on top. The XCUITest steps (`ui.U2-U6-U10-U11`, `photo.P3`, `video.B5`, `pr1.capture`) and
`ui.U1` take the foreground: the owner is away for them (they are skipped in a dry run).

## 4. The plan (generated: `make perf-all LIST=1`)

Status words in the table: **[owner]** needs the owner (never attempted by the runner), **[blocked]** no driver yet
(reason given). GPU column: `timing (run.py)` = run.py wraps itself; `timing`/`shared` = t05.py wraps the step.
Result paths: `$T05_RUNS` = `build/perf/runs`, `$T05_AT` = `build/at`, `$T05_OUT` = `build/perf/t05/<stamp>` (dry run:
all three under `build/perf/t05-dry/<stamp>/`).

| # | step | what | bar | tier | model | GPU | est. min | result |
|---|---|---|---|---|---|---|---|---|
| 1 | `prep.machine` | machine line + quiet check (AC power, thermal, Spotlight, load.py verdict) |  |  |  | — | 1 | `$T05_OUT/load-start.json` |
| 2 | `prep.power` | HARD precondition: Low Power Mode off (pmset powermode 0); set by the owner, never by an agent |  |  |  | — | 0 |  |
| 3 | `prep.disk` | ≥ 60 GB free before model work |  |  |  | — | 0 |  |
| 4 | `prep.build-debug` | Debug app (ScriptedVoice, -Bench, probes): make build |  |  |  | — | 25 | `build/AntiChat.app/Contents/MacOS/AntiChat` |
| 5 | `prep.bench-release` | release antichat-bench (NDEBUG, DuckDB): make bench-release |  |  |  | — | 20 | `.build/release/antichat-bench` |
| 6 | `prep.binaries` | helper binaries (llama-server, sd-server, sd-cli) staged |  |  |  | — | 1 | `build/binaries/sd-server` |
| 7 | `prep.runtime-video` | video runtime (vid-5b / I2V) |  |  |  | — | 10 | `build/runtimes/video-runtime` |
| 8 | `prep.gpu-burn` | gpu-burn helper (B5) |  |  |  | — | 1 | `build/tools/gpu-burn` |
| 9 | `prep.models` | dev models T0/T1/T3 + evil-T1/evil-T3 (make models-dev) |  |  |  | — | 10 |  |
| 10 | `chat.C1.T0` | NFR-C1 T0 (antichat-bench chat via XPC) | p50 ≤ 1.5 s | T0 | chat-2b | timing (run.py) | 4 | `$T05_RUNS/*-C1-T0.json` |
| 11 | `chat.C1.T1` | NFR-C1 T1 (antichat-bench chat via XPC) | p50 ≤ 1.5 s | T1 | chat-9b-q4 | timing (run.py) | 4 | `$T05_RUNS/*-C1-T1.json` |
| 12 | `chat.C1.T2` | NFR-C1 T2 (antichat-bench chat via XPC) | p50 ≤ 1.0 s | T2 | chat-9b-q4 @ T2-24 | timing (run.py) | 4 | `$T05_RUNS/*-C1-T2.json` |
| 13 | `chat.C1.T3` | NFR-C1 T3 (antichat-bench chat via XPC) | p50 ≤ 0.8 s | T3 | chat-35b-q4 @ T3-48 | timing (run.py) | 4 | `$T05_RUNS/*-C1-T3.json` |
| 14 | `chat.C1b.T0` | NFR-C1b T0 (antichat-bench chat via XPC) | TTFT p95 ≤ 3 s | T0 | chat-2b | timing (run.py) | 4 | `$T05_RUNS/*-C1b-T0.json` |
| 15 | `chat.C1b.T1` | NFR-C1b T1 (antichat-bench chat via XPC) | TTFT p95 ≤ 3 s | T1 | chat-9b-q4 | timing (run.py) | 4 | `$T05_RUNS/*-C1b-T1.json` |
| 16 | `chat.C1b.T2` | NFR-C1b T2 (antichat-bench chat via XPC) | TTFT p95 ≤ 2 s | T2 | chat-9b-q4 @ T2-24 | timing (run.py) | 4 | `$T05_RUNS/*-C1b-T2.json` |
| 17 | `chat.C1b.T3` | NFR-C1b T3 (antichat-bench chat via XPC) | TTFT p95 ≤ 1.5 s | T3 | chat-35b-q4 @ T3-48 | timing (run.py) | 4 | `$T05_RUNS/*-C1b-T3.json` |
| 18 | `chat.C2.T0` | NFR-C2 T0 (antichat-bench chat via XPC) | decode p50 ≥ 20 tok/s | T0 | chat-2b | timing (run.py) | 4 | `$T05_RUNS/*-C2-T0.json` |
| 19 | `chat.C2.T1` | NFR-C2 T1 (antichat-bench chat via XPC) | decode p50 ≥ 15 tok/s | T1 | chat-9b-q4 | timing (run.py) | 4 | `$T05_RUNS/*-C2-T1.json` |
| 20 | `chat.C2.T2` | NFR-C2 T2 (antichat-bench chat via XPC) | decode p50 ≥ 20 tok/s | T2 | chat-9b-q4 @ T2-24 | timing (run.py) | 4 | `$T05_RUNS/*-C2-T2.json` |
| 21 | `chat.C2.T3` | NFR-C2 T3 (antichat-bench chat via XPC) | decode p50 ≥ 30 tok/s | T3 | chat-35b-q4 @ T3-48 | timing (run.py) | 4 | `$T05_RUNS/*-C2-T3.json` |
| 22 | `chat.C4.T0` | NFR-C4 T0 (antichat-bench chat via XPC) | prefill ≥ 150 tok/s (4K doc) | T0 | chat-2b | timing (run.py) | 4 | `$T05_RUNS/*-C4-T0.json` |
| 23 | `chat.C4.T1` | NFR-C4 T1 (antichat-bench chat via XPC) | prefill ≥ 150 tok/s | T1 | chat-9b-q4 | timing (run.py) | 4 | `$T05_RUNS/*-C4-T1.json` |
| 24 | `chat.C4.T2` | NFR-C4 T2 (antichat-bench chat via XPC) | prefill ≥ 300 tok/s | T2 | chat-9b-q4 @ T2-24 | timing (run.py) | 4 | `$T05_RUNS/*-C4-T2.json` |
| 25 | `chat.C4.T3` | NFR-C4 T3 (antichat-bench chat via XPC) | prefill ≥ 400 tok/s | T3 | chat-35b-q4 @ T3-48 | timing (run.py) | 4 | `$T05_RUNS/*-C4-T3.json` |
| 26 | `chat.M1.T0` | NFR-M1 cold load T0 (evict → ready; [WARM-CACHE] without sudo purge) | ≤ 3/8/12/25 s by weights | T0 | chat-2b | timing (run.py) | 5 | `$T05_RUNS/*-M1-T0.json` |
| 27 | `chat.M1.T1` | NFR-M1 cold load T1 (evict → ready; [WARM-CACHE] without sudo purge) | ≤ 3/8/12/25 s by weights | T1 | chat-9b-q4 | timing (run.py) | 5 | `$T05_RUNS/*-M1-T1.json` |
| 28 | `chat.M1.T3` | NFR-M1 cold load T3 (evict → ready; [WARM-CACHE] without sudo purge) | ≤ 3/8/12/25 s by weights | T3 | chat-35b-q4 | timing (run.py) | 5 | `$T05_RUNS/*-M1-T3.json` |
| 29 | `chat.C7.T1` | NFR-C7 Normal → Evil switch to first token T1 | cold: M1 band + C1; warm ≤ 1.5 s | T1 | chat-9b-q4 → evil-9b (cold) | timing (run.py) | 18 | `$T05_RUNS/*-C7-T1.json` |
| 30 | `chat.C7.T3` | NFR-C7 Normal → Evil switch to first token T3 | cold: M1 band + C1; warm ≤ 1.5 s | T3 | chat-35b-q4 → evil-35b-q4 (T3-64, warm) | timing (run.py) | 18 | `$T05_RUNS/*-C7-T3.json` |
| 31 | `chat.U3.T1` | NFR-U3 send while loading T1 (antichat-bench u3) | status ≤ 2 s p95; reply ≤ M1 band + C1 | T1 | chat-9b-q4 | timing (run.py) | 6 | `$T05_RUNS/*-U3-T1.json` |
| 32 | `chat.U3.T3` | NFR-U3 send while loading T3 (antichat-bench u3) | status ≤ 2 s p95; reply ≤ M1 band + C1 | T3 | chat-35b-q4 | timing (run.py) | 6 | `$T05_RUNS/*-U3-T3.json` |
| 33 | `ui.U1` | NFR-U1 cold start (foreground launch → composer focus; takes focus; cold needs `sudo -n purge`) | p50 ≤ 1.0 s (S2+); warm ≤ 0.5 s | na |  | — | 4 | `$T05_RUNS/*-U1-na.json` |
| 34 | `ui.U9` | NFR-U9 quick panel open (Debug app, hotkey-post) | p95 ≤ 150 ms | T1 |  | — | 3 | `$T05_RUNS/*-U9-T1.json` |
| 35 | `ui.B1` | NFR-B1 idle energy (top power, window open, 5 min) | mean Energy Impact ≤ 1 | na |  | — | 6 | `$T05_RUNS/*-B1-na.json` |
| 36 | `ui.U5` | NFR-U5 renderer cadence (A-M1-T09b; in-process renderer probe + frametime) | hitches per reply (nfr.md U5) | S4 |  | — | 5 | `build/at/AT-008/renderer*.json` |
| 37 | `ui.U2-U6-U10-U11` | NFR-U2/U6/U10/U11 XCUITest perf legs (App/UITests/Perf: send ack, Stop, ⌘K on 10,000 chats, open a 500-turn chat; takes the foreground) → perf log → run.py --from-log | U2 p99 < 100 ms, p50 ≤ 16 ms · U6 p50 ≤ 300 ms, p95 ≤ 1 s · U10 p95 ≤ 200 ms · U11 p95 ≤ 500 ms | na | ScriptedEngine | — | 14 | `$T05_RUNS/*-U11-na.json` |
| 38 | `voice.V7.T1` | NFR-V7/V6 dictation (stop → final; onset → first partial), T1 | V7 p50 ≤ 0.4 s; V6 ≤ 0.6 s | T1 | stt + stt-eou | timing (run.py) | 4 | `$T05_RUNS/*-V7-T1.json` |
| 39 | `voice.V6.T1` | NFR-V6 from the same dictation run | p50 ≤ 0.6 s | T1 |  | — | 0 | `$T05_RUNS/*-V6-T1.json` |
| 40 | `voice.V7.T3` | AT-050 AC2 V7 at T3 (T3-48 cap) | p50 ≤ 0.3 s | T3-48 | stt + stt-eou | timing (run.py) | 4 | `$T05_RUNS/*-V7-T3.json` |
| 41 | `voice.V7.T0` | V7 at T0 (no stt-eou on T0) | p50 ≤ 1.0 s | T0 | stt | timing (run.py) | 4 | `$T05_RUNS/*-V7-T0.json` |
| 42 | `voice.V10.T1` | NFR-V10 dictation warm-up after evict | p50 ≤ 300 ms | T1 | stt | timing (run.py) | 4 | `$T05_RUNS/*-V10-T1.json` |
| 43 | `voice.V1.T1` | NFR-V1/V1b/V2/V283 voice session T1 (-Bench voice-session, 20 questions) | V1 p50 T0 ≤ 2.5 · T1 ≤ 1.5 · T3 ≤ 1.0 s; V1b p95 (nfr.md) | T1 | chat-9b-q4 + stt + stt-eou + vad + turn + tts | timing (run.py) | 8 | `$T05_RUNS/*-V1-T1.json` |
| 44 | `voice.V1b.T1` | NFR-V1b T1 from the same voice-session run | nfr.md V1b | T1 |  | — | 0 | `$T05_RUNS/*-V1b-T1.json` |
| 45 | `voice.V2.T1` | NFR-V2 T1 from the same voice-session run | nfr.md V2 | T1 |  | — | 0 | `$T05_RUNS/*-V2-T1.json` |
| 46 | `voice.V283_EOS_FINAL.T1` | NFR-V283_EOS_FINAL T1 from the same voice-session run | nfr.md V283_EOS_FINAL | T1 |  | — | 0 | `$T05_RUNS/*-V283_EOS_FINAL-T1.json` |
| 47 | `voice.V1.T3` | NFR-V1/V1b/V2/V283 voice session T3 (-Bench voice-session, 20 questions) | V1 p50 T0 ≤ 2.5 · T1 ≤ 1.5 · T3 ≤ 1.0 s; V1b p95 (nfr.md) | T3-48 | chat-35b-q4 + stt + stt-eou + vad + turn + tts | timing (run.py) | 8 | `$T05_RUNS/*-V1-T3.json` |
| 48 | `voice.V1b.T3` | NFR-V1b T3 from the same voice-session run | nfr.md V1b | T3 |  | — | 0 | `$T05_RUNS/*-V1b-T3.json` |
| 49 | `voice.V2.T3` | NFR-V2 T3 from the same voice-session run | nfr.md V2 | T3 |  | — | 0 | `$T05_RUNS/*-V2-T3.json` |
| 50 | `voice.V283_EOS_FINAL.T3` | NFR-V283_EOS_FINAL T3 from the same voice-session run | nfr.md V283_EOS_FINAL | T3 |  | — | 0 | `$T05_RUNS/*-V283_EOS_FINAL-T3.json` |
| 51 | `voice.V1.T0` | NFR-V1/V1b/V2/V283 voice session T0 (-Bench voice-session, 20 questions) | V1 p50 T0 ≤ 2.5 · T1 ≤ 1.5 · T3 ≤ 1.0 s; V1b p95 (nfr.md) | T0 | chat-2b + stt + stt-eou + vad + turn + tts | timing (run.py) | 8 | `$T05_RUNS/*-V1-T0.json` |
| 52 | `voice.V1b.T0` | NFR-V1b T0 from the same voice-session run | nfr.md V1b | T0 |  | — | 0 | `$T05_RUNS/*-V1b-T0.json` |
| 53 | `voice.V2.T0` | NFR-V2 T0 from the same voice-session run | nfr.md V2 | T0 |  | — | 0 | `$T05_RUNS/*-V2-T0.json` |
| 54 | `voice.V283_EOS_FINAL.T0` | NFR-V283_EOS_FINAL T0 from the same voice-session run | nfr.md V283_EOS_FINAL | T0 |  | — | 0 | `$T05_RUNS/*-V283_EOS_FINAL-T0.json` |
| 55 | `voice.V283` | V283 eager STT turn end → final (TurnSplitFixtureTests/eagerSTTLatency) | p50 ≤ 300 ms | T1 | vad + turn + stt + stt-eou | timing | 6 | `build/at/AT-283/eos.json` |
| 56 | `voice.V4` | NFR-V4 false splits, 50 utterances × 4 noise beds (accuracy, shared) | ≤ 2.0 % per bed | T1 | vad + turn | shared | 5 | `build/at/AT-283/turn-split.json` |
| 57 | `voice.V3` | NFR-V3 barge-in onset → TTS silent (BargeInFixtureTests) | p50 ≤ 200 ms | T1 | vad + tts + stt | timing | 7 | `build/at/AT-282/v3.json` |
| 58 | `voice.V5` | NFR-V5 mic click → dictation bar drawn (in-process, no model) | ≤ 150 ms | T1 |  | — | 4 | `$T05_RUNS/*-V5-T1.json` |
| 59 | `voice.V8.T1` | NFR-V8 read aloud → first audio, Kokoro warm, at the T1 cap (-Bench read-aloud, 1- and 3-sentence replies, silent clock) | p50 ≤ 0.5 s | T1 | tts + chat-9b-q4 resident | timing (run.py) | 4 | `$T05_RUNS/*-V8-T1.json` |
| 60 | `voice.V8.T0` | NFR-V8 read aloud → first audio, Kokoro warm, at the T0 cap (-Bench read-aloud, 1- and 3-sentence replies, silent clock) | p50 ≤ 1.0 s | T0 | tts + chat-2b resident | timing (run.py) | 4 | `$T05_RUNS/*-V8-T0.json` |
| 61 | `voice.V8.T3` | NFR-V8 read aloud → first audio, Kokoro warm, at the T3-48 cap (-Bench read-aloud, 1- and 3-sentence replies, silent clock) | p50 ≤ 0.4 s | T3-48 | tts + chat-35b-q4 resident | timing (run.py) | 4 | `$T05_RUNS/*-V8-T3.json` |
| 62 | `voice.V11.T0` | NFR-V11 60-min file transcription speed at the T0 cap (-Bench transcribe-file, n 3) | ≥ 4× real time | T0 | stt + vad-files + chat-2b resident | timing (run.py) | 4 | `$T05_RUNS/*-V11-T0.json` |
| 63 | `voice.V11.T1` | NFR-V11 60-min file transcription speed at the T1 cap (-Bench transcribe-file, n 3) | ≥ 10× real time | T1 | stt + vad-files + chat-9b-q4 resident | timing (run.py) | 4 | `$T05_RUNS/*-V11-T1.json` |
| 64 | `voice.V11.T3` | NFR-V11 60-min file transcription speed at the T3-48 cap (-Bench transcribe-file, n 3) | ≥ 10× real time | T3-48 | stt + vad-files + chat-35b-q4 resident | timing (run.py) | 4 | `$T05_RUNS/*-V11-T3.json` |
| 65 | `voice.V9` | NFR-V9 / AT-284 WER per language (accuracy; ar/zh accepted A-M3-06) | worst language ≤ 6 % (ar 11.4 / zh 10.6 accepted) | T0/T1 | stt + stt-multi (m0 manifest) | shared | 25 | `build/at/AT-284/wer.json` |
| 66 | `photo.handoff.T1` | NFR-P1 T1 + AT-NFR-M3 (unload ≤ 1 s, reload ≤ M1) + NFR-R1 T1 image peak (ImageHandoffTests) | P1 S4 ≤ 20 s (S1 150 / S2 60 / S3 45 scaled); unload ≤ 1 s; peak ≤ 9.5 GB | T1 | img-klein-q4 768² 4 steps + chat-9b-q4 | timing | 12 | `build/at/AT-286/handoff-T1.json` |
| 67 | `photo.P1.bench` | NFR-P1/P2 -Bench image (T3 default 1024², q4) → sd-scale.py per speed class | P1 S4 ≤ 20 s; P2 S4 ≤ 1 s (previews withheld < 512 px, A-M4-R1) | T3-48 | img-klein q4 | timing | 15 | `$T05_OUT/image-q4-*.jsonl` |
| 68 | `photo.M3.T2-24` | AT-NFR-M3 T2-24 / R-236 co-resident image + chat (-Bench coresident) | no eviction; peak ≤ B 16 GB; reply ≤ M1 | T2-24 | chat-9b-q4 + img-klein q8 | timing | 8 | `$T05_OUT/coresident-T2-24.jsonl` |
| 69 | `photo.JOB_CANCEL_FREE` | AT-291 AC3 JOB_CANCEL_FREE proxy: cancel at step 2 → memory back (-Bench cancel) | cancel → GPU memory freed ≤ 2 s (NFR-VID3) | T1 | img-klein q4 | timing | 6 | `$T05_OUT/cancel-q4-*.jsonl` |
| 70 | `photo.IMAGE_TURN_OVERHEAD` | AT-236 AC3 IMAGE_TURN_OVERHEAD: imageTurn − imageGen per image turn (-Bench image-turn: TurnController + MediaJobQueue, Image chip → create_image, gate, artifact, templated caption; perf log) | p50 ≤ 2 s | T1 | chat-9b-q4 + img-klein q4 768² | timing (run.py) | 12 | `$T05_RUNS/*-IMAGE_TURN_OVERHEAD-T1.json` |
| 71 | `photo.P4.T1` | NFR-P4 edit ≤ 1.5× create, T1 klein 768² (EditTimingTests) | edit ≤ 1.5 × P1 | T1 | img-klein q4 768² | timing | 5 | `build/at/AT-NFR-P4/*` |
| 72 | `photo.P4.T3` | NFR-P4 T3 default edit = img-klein 1024² (A-M9-T05-P4; model-matrix §2.2); `photo.P4.T3-best` records img-edit (qwen) 1024² without a bar | edit ≤ 1.5 × P1 | T3 | img-klein q4 1024² (+ img-edit info) | timing | 8 (+50) | `build/at/AT-033/real-legs.log` |
| 73 | `photo.P5` | NFR-P5 remove background 1024² (Vision, 20 runs) | ≤ 1.5 s S1, ≤ 1 s S2+ | na |  | timing | 3 |  |
| 74 | `photo.P3` | NFR-P3 progress never stale > 3 s (XCUITest Perf/ImageProgressPerfTests: the job card sampled every 250 ms, 4 s steps; takes the foreground) | max unchanged ≤ 3 s | na | ScriptedImageEngine | — | 4 | `$T05_AT/AT-NFR-P3/perf-uitest.json` |
| 75 | `photo.R4-R5` | NFR-R4 resident set (ResidentSetTests) + NFR-R5 lighter fallback / refusal | only chat (+embed, +voice) resident; refuse before load | T1 |  | timing | 10 | `build/at/AT-NFR-R4/resident-set.json` |
| 76 | `csc.F7` | NFR-F7 per-image check, full path forced (csc-bench latency, 40 CC0 photos, CoreML) | p95 ≤ 300 ms | T1 | csc-nudity + Vision + MiVOLO + csc-age-bins | timing (run.py) | 6 | `$T05_RUNS/*-F7-T1.json` |
| 77 | `csc.body-age` | A-M4-T02b body-only age model re-check (lawful proxies only; aggregates only) | adopt only if recall ≥ NFR-F2 bars AND adult ≥ 30 y false flag < 12.5 % (v1) | T1 | MiVOLO + csc-age-bins | — | 30 | `build/at/AT-NFR-F2/*.json` |
| 78 | `video.T4` | NFR-VID1/VID2 T4 default: vid-5b 1280×704 × 121 f through the app path (A-M5-13) | VID1 S4 720p ≤ 90 s p50; VID2 S4 ≤ 5 s (open, A-M0-T07c) | T4 | vid-5b + vid-taehv | timing | 12 | `$T05_AT/T4-video/t05-*-t4*.jsonl` |
| 79 | `video.F7_VIDEO.T4` | NFR-F7 video frame checks ≤ 10 % of generation time, T4 default job (the video.T4 rows) | gate time ≤ 10 % per job (max) | T4 | vid-5b + csc detectors | — | 0 | `$T05_RUNS/*-F7_VIDEO-T4.json` |
| 80 | `video.F7_VIDEO.T3` | NFR-F7 video frame checks ≤ 10 % of generation time, T3-48 480p × 73 f (-Bench video, gate on) | gate time ≤ 10 % per job (max) | T3-48 | vid-5b + vid-taehv + csc detectors | timing (run.py) | 10 | `$T05_RUNS/*-F7_VIDEO-T3.json` |
| 81 | `video.T3-480p` | NFR-VID1 T3/S4 480p (VideoBenignGateTests real path; S1–S3 via vid-scale.py) | S1/S2 480p ≤ 480 s · S3 ≤ 210 s · S4 ≤ 90 s | T3 | vid-ltx / vid-5b (plan default) | timing | 15 | `build/at/AT-M5-preview-fp/*.json` |
| 82 | `video.speed-table` | AT-290 VIDEO_ESTIMATE / A-M5-10: speed table re-run (video-speed.py --run) | estimate p80 /err/ ≤ 25 % | S4 |  | timing | 40 |  |
| 83 | `video.VID3.t2v` | NFR-VID3 cancel frees GPU ≤ 2 s, T2V (VideoCancelTests, 21 cancels) | p95 ≤ 2 s | T3 | vid-5b | timing | 20 | `build/at/AT-NFR-VID3/cancel-T3.json` |
| 84 | `video.VID3.i2v` | NFR-VID3 I2V cancel mid-denoise (cancelMidDenoiseFreesTheServerWithinTwoSeconds; never run before) | ≤ 2 s at step 2 and step 4 | T3 | vid-i2v + vid-te (sd-server) | timing | 10 | `build/at/AT-NFR-VID3/cancel-i2v-T3.json` |
| 85 | `video.B5` | NFR-B5 paused for another app (XCUITest Perf/VideoPausedPerfTests: a running job + gpu-burn 30 s; takes the foreground) | paused ≤ 12 s after the other app's GPU load; resumes after it | T3 | ScriptedVideoEngine + gpu-burn | timing | 5 | `$T05_AT/AT-NFR-B5/perf-uitest.json` |
| 86 | `video.B3` | NFR-B3 thermal .serious throughput drop ≤ 30 % **[blocked]** no way to put the SoC in .serious on purpose; covered in-process (ThermalPolicyTests, -FakeThermal serious, build/at/AT-041) |  |  |  | — | — |  |
| 87 | `search.e2e.T1` | AT-248 c1 search answer complete + <web_results> prefill tokens (search-e2e, live engines) | p50 ≤ 12 s; ≥ 2 pills | T1 | chat-9b-q4 + embed | timing (run.py) | 22 | `$T05_RUNS/*-search_e2e-T1.json` |
| 88 | `search.ttft.T1` | AT-254 first answer token after search, 20 availability queries | p50 ≤ 8 s | T1 | chat-9b-q4 | timing (run.py) | 22 | `$T05_RUNS/*-search-T1.json` |
| 89 | `search.ttft.T3` | AT-254 at T3 | p50 ≤ 5 s | T3 | chat-35b-q4 | timing (run.py) | 18 | `$T05_RUNS/*-search-T3.json` |
| 90 | `search.AT-266` | AT-266 tool selection T2 / T0 (embed only) | T2 ≥ 0.85 | T2/T0 | embed | shared | 2 | `$T05_AT/AT-266/t05-T2.json` |
| 91 | `m5.50mbps` | NFR-M5 fast first chat at 50 Mbps, 20 runs (-Bench firstchat) | p50 ≤ 120 s | T1 | starter chat-0.8b (real HF download) | timing | 45 | `$T05_OUT/firstchat-50.jsonl` |
| 92 | `m5.10mbps` | NFR-M5 at 10 Mbps [EMULATED] (in-app token bucket), 20 runs | p50 ≤ 600 s | T1 |  | timing | 185 | `$T05_OUT/firstchat-10.jsonl` |
| 93 | `d3.real` | NFR-D3 real bytes, default install (all eligible packs) on a fresh dev container, T1 | T1 ≤ 15 GB; store within 1 % of the catalog | T1 |  | timing | 40 | `$T05_OUT/d3-T1.json` |
| 94 | `pr1.capture` | NFR-PR1 30-min Offline-only capture (nettop + lsof leg) with journeys 2/7/8 looped (XCUITest attach; takes the foreground) | zero outbound connections; every journey ran | T1 |  | — | 36 | `build/at/AT-NFR-PR1/*` |
| 95 | `pr1.tcpdump` | NFR-PR1 tcpdump leg **[owner]** tcpdump needs root (/dev/bpf*, Q-028): capture-30min.sh records the pcap when `sudo -n` works, else "not run: permission" (the nettop + lsof leg and the journeys run in pr1.capture) |  |  |  | — | — |  |
| 96 | `r1.soak.T1` | NFR-R1 mini-soak T1 60 min (real chat + Evil + image jobs) | peak ≤ 9.5 GB; 0 crashes / jetsam | T1 | chat-9b-q4 + evil-9b | timing (mini-soak) | 62 | `build/at/AT-206/soak-T1.json` |
| 97 | `r1.soak.T2-24` | NFR-R1 mini-soak T2-24 60 min | peak ≤ 16 GB | T2-24 |  | timing (mini-soak) | 62 | `build/at/AT-206/soak-T2-24.json` |
| 98 | `r1.soak.T0` | NFR-R1 mini-soak T0 30 min | peak ≤ 4.0 GB | T0 |  | timing (mini-soak) | 32 | `build/at/AT-206/soak-T0.json` |
| 99 | `r1.soak.T3-48` | NFR-R1 mini-soak T3-48 60 min (chat-35b-q4 + evil-35b-q4 + 6.0 GB image jobs; chat co-resides) | peak ≤ 36 GB; 0 crashes / jetsam | T3-48 | chat-35b-q4 + evil-35b-q4 | timing (mini-soak) | 62 | `build/at/AT-206/soak-T3-48.json` |
| 100 | `stepaside` | Scheduler StepAside ≤ 1 s unload with the real model | unload ≤ 1 s | T1 |  | timing | 8 | `build/at/AT-206/step-aside-real.json` |
| 101 | `files.warm` | Warm document: pressure release ≤ 2 s (antichat-bench files-warm; real memory_pressure needs root) | release ≤ 2 s; peak ≤ B | T2 | chat-9b-q4 | timing | 8 | `$T05_AT/AT-279/t05-files-warm.json` |
| 102 | `files.spreadsheet` | AT-273 full 150-prompt create_spreadsheet model run (5 files × 30) | AT-273 check 5 | T1 | chat-9b-q4 | shared | 60 | `$T05_AT/AT-273/t05/model/*` |
| 103 | `files.presentation` | AT-275 full 20 create_presentation run | AT-275 1c | T1 | chat-9b-q4 | shared | 20 | `$T05_AT/AT-275/t05/model/*` |
| 104 | `report.compare` | compare vs main (informational: every baseline before 2026-11-09 20:00 was measured in Low Power Mode) |  |  |  | — | 1 |  |

104 steps; estimated wall time T05 1296 min ≈ 21.6 h (plus quiet-gate waits); dry run ≈ 285 min

## 5. What this prep changed (so T05 has no surprises)

- **Release bench build fixed.** duckdb-swift's `D_ASSERT` falls back to `<assert.h>` when `NDEBUG` is not defined and
  then references DEBUG-only helpers (`variant_shredding.cpp`, `row_group_collection.cpp`). `make bench-release`
  already passed `-Xcc/-Xcxx -DNDEBUG`; the xcodebuild Release bench app (`tools/bench.sh`, `build/dd-bench`) and the
  M0 scripts that build it now pass `ARCHS=arm64 GCC_PREPROCESSOR_DEFINITIONS='$(inherited) NDEBUG=1'` like
  `make build-release`. No duckdb patch or pin change (nothing to record in `Vendor/VENDORED.json`). Verified:
  `make bench-release` builds; the Release app runs `-Bench hello` (see §6).
- **GPU wrapper** (`run.py gpu_prefix()` / `run_gpu()`, `mini-soak.sh`): one rule for every GPU probe
  (`ANTICHAT_GPU_MODE=timing|shared`, no nested lock under `gpu-run.sh timing`, exit 75 → run.py exit 5 `deferred`).
- **Low Power Mode** in `load.py` (sample + verdict + summary) and as the hard `prep.power` precondition.
- **New drivers:** NFR-U3 (`antichat-bench u3` + `run.py` probe; bars from nfr.md NFR-U3), NFR-B1 (`run.py` probe:
  `top -stats pid,power`, 5 min idle with a window open).
- **Search:** `antichat-bench search-e2e` rows now carry `web_results_tokens` (the `<web_results>` block(s) the model
  prefilled, counted with the chat model's tokenizer) and the run.py note prints its p50/max — measure this before any
  AT-248/AT-254 latency tuning (M9-card).
- **Voice T3:** `-Bench` refuses an unknown `--tier-cap` (bare `T3` used to run uncapped); run.py maps T2/T3 to
  T2-24/T3-48 and picks chat-35b-q4 for T3 voice sessions.
- **Video:** `tools/perf/t4-video-bench.sh` replaces `build/at/T4-video/run-bench.sh` (hard-coded another worktree and
  a scratchpad models dir); `-Bench video` rows label `--installed` jobs by the request's size and carry `load_avg`.
- **D3 real bytes:** `ONB_PROBE_ALL_PACKS=1` keeps every pack the profile pre-selects in the onboarding probe;
  `D3=1 tools/at/at-nfr-d3d4-real.sh` checks the store against the catalog `all` sum and the NFR-D3 cap.

## 5b. Drivers added on `m9/t05-drivers` (2026-11-10)

- **IMAGE_TURN_OVERHEAD (AT-236 AC3)** — new signposts / perf-log intervals: `imageTurn` (TurnController: send → the
  image turn's reply written, recorded in `finalizeNow` when an image tool ran) and `imageGen` (the helper measures
  `image.loadStart` → `image.final` in `runImageLocked` as metric `load_start_to_final_s` and an `imageGen` signpost; the
  app's MediaJobQueue marks it in the app's perf log when the job's `imageResult` arrives, meta `source=queue`). Driver:
  `AntiChat -Bench image-turn` (TurnController + `ToolRuntime.installMedia` → MediaJobQueue + ImageTools over XPC, Image
  chip → create_image, real klein set, gate, artifact, templated caption; run 0 discarded). Probe: `run.py --metric
  IMAGE_TURN_OVERHEAD` (pairs each imageTurn with its imageGen; bar p50 ≤ 2 s in `EXTRA_TARGETS`; `--from-log` re-reads).
- **F7_VIDEO (NFR-F7 video leg)** — timing only, no gate decision changes (D-006): `MediaJobRunner.GateTiming` per job
  (preview checks, final check after the last frame / its wall), emitted as a `videoGate` scheduler note in the job's
  events (`MediaJobOutputs.noteGateTiming`, VideoEngine + SDVideoEngine). `-Bench video` dev-model jobs now carry the
  bench detectors (the gate runs, as in `-Bench image`). Probe `run.py --metric F7_VIDEO` = gate_s ÷ final_s per job
  (bar max ≤ 10 %); steps `video.F7_VIDEO.T4` (ingests the video.T4 rows, `VIDEO_RAW`) and `video.F7_VIDEO.T3`
  (480p × 73 f at T3-48).
- **XCUITest perf legs** — `App/UITests/Perf/`: `SendAckPerfTests` (U2 `sendAck`), `StopPerfTests` (U6 `stopToIdle`),
  `PalettePerfTests` (U10, new `paletteQuery` mark in PaletteController: query change → its chat rows drawn) and
  `LongChatOpenPerfTests` (U11, new `chatOpen` interval: WindowState open → the conversation column's first commit;
  cold open from ⌘K + warm re-open) on the 10,000-chat fixture DB, all writing `ANTICHAT_PERF_LOG` and ingested with
  `run.py --from-log`; `ImageProgressPerfTests` (P3: card sampled every 250 ms, max unchanged ≤ 3 s),
  `VideoPausedPerfTests` (B5: gpu-burn → "Paused for another app" ≤ 12 s, then resumed), `PR1JourneyLoopTests`
  (journeys 2/7/8 looped; attach mode drives the app run-offline.sh starts during the 30-min capture). Conventions:
  foreground app (`ANTICHAT_BACKGROUND=0`), main window by identifier `main-…`, throwaway containers.
- **V8 / V11 per tier** — `AntiChat -Bench read-aloud` / `-Bench transcribe-file --tier-cap <cap>`: the helper at the
  tier's budget B with the tier's chat model resident; Kokoro plays into a silent clock (`Speak.silentOutput`, DEBUG
  only). Steps `voice.V8.T0/T1/T3`, `voice.V11.T0/T1/T3` (V8_JSON / V11_JSON still ingest the in-process tests).
- **R1 at T3-48** — `mini-soak.sh --tier T3-48` (chat-35b-q4 + evil-35b-q4 via the new `soak --evil-key` + 6.0 GB
  scripted image jobs, chat co-resident); `--no-evil` only for a smoke run without the Evil model. Step `r1.soak.T3-48`.
- **NFR-M5 10 Mbps** — planned at the bar's 20 runs (≈ 3 h), not 5.

### Smoke runs (2026-11-10, shared GPU, load 10–48) — NOISY/DRY, not results

| driver | dir under `build/perf/t05-dry/` | what it showed (NOISY/DRY) |
|---|---|---|
| photo.IMAGE_TURN_OVERHEAD (t05 dry, 2 runs + warm) | `20261110T010504Z` | n 2 paired turns, overhead p50 4.81 s (turn 18.3 s, imageGen 13.5 s), load 45; 2/2 images stored, templated caption "Here's your picture." |
| video.F7_VIDEO.T3 (t05 dry, 1 job) | `20261110T011326Z` | 832×480 × 73 f, job 28.4 s, gate 2.16 s = 7.6 % (streamed final check 2.16 s after the last frame, 2.90 s wall, 0 preview checks) |
| video.F7_VIDEO.T4 (ingest, `VIDEO_RAW`) | — | same `video_rows_gate` path; covered by `test_image_turn_pairs_and_video_gate_rows` (no T4 install on this branch) |
| XCUITest U2/U6/U10/U11 (2 actions each) + `run.py --from-log` | `20261110T-uitest-smoke` | all four pass; ingest: U2 p50 56.5 ms / p99 103 ms (first send per launch ≈ 100 ms), U6 p50 165 ms, U10 p50 113 ms / p95 129 ms, U11 p95 794 ms (1000-message chat; includes an early run's opens) |
| photo.P3 (ImageProgressPerfTests) | `20261110T-uitest-smoke/at/AT-NFR-P3` | pass: card pixels never unchanged > 2.38 s; **the progress text itself did not change for 16.8 s of a 17.5 s job** (4 s steps) — check in T05 |
| pr1 journeys (PR1JourneyLoopTests, 0.5 min, own launch) | `20261110T-uitest-smoke/at/AT-NFR-PR1` | pass: J02, J07, J08 once each; **J07 never showed the Evil chrome** in a fresh container (⇧⌘E, File menu and the composer's Evil segment did not switch; `j07_evil_seen` 0) — recorded, not gated |
| video.B5 (VideoPausedPerfTests) | `20261110T-uitest-smoke/at/AT-NFR-B5` | **not completed**: compiled and wired; 4 launches under `gpu-run.sh shared` failed — first the plain-words script never routed to video (now the scripted `create_video` call, as the other media legs), then "app.antichat.AntiChat.dev does not have a process ID" 3× while another track's XCUITest sessions (same app bundle id and `AntiChatUITests.xctrunner`) were running. First real run in T05 (no other tracks); `make test-ui FILTER=VideoPausedPerfTests` alone to re-check |
| r1.soak.T3-48 (t05 dry, 2 min, `--no-evil`) + `run.py R1 T3-48` | `20261110T011033Z` | PASS: 142 turns, 47 scripted 6.0 GB image jobs, peak 25.82 GB ≤ 36, helper stable, 0 .ips / jetsam |
| voice.V8.T0 / V8.T3 / V11.T0 (t05 dry) | `20261110T011644Z` | V8 T0 p50 0.140 s (chat-2b resident), V8 T3 p50 0.124 s, V11 T0 275× (n 1) |
| voice.V8.T3 / V11.T1 after the checked chat warm-up | `20261110T020339Z` | V8 T3 p50 0.278 s with chat-35b-q4 loaded (warm-up 1.92 s), V11 T1 247× (chat-9b-q4) |
| m5.10mbps (`-Bench firstchat --rate 10 --runs 1`) | `20261110T-m5-10mbps` | download 542.5 s, first token 543.6 s (bar p50 ≤ 600 s; T05 runs 20) |

## 6. Dry run (2026-11-09) — NOISY/DRY, not results

Every number below was taken on a busy machine (load 5–60, other tracks' GPU jobs, n = 1) with `--dry --allow-noisy`;
each is labelled noisy / `valid=false` and lives only under `build/perf/t05-dry/<stamp>/` (never in
`build/perf/report.json`). They prove that the probe runs end to end and writes its result; they are not results.

**Scope (lead, 2026-11-09):** a full serial dry run of all GPU steps would have waited hours in the shared GPU queue
(chat.C1.T0 alone waited 109 min behind other tracks' exclusive runs), so the dry run covers every step that needs no
GPU plus the cheapest GPU probe per family: `python3 -I tools/perf/t05.py run --dry --allow-noisy --reduced`.
Dry-run dirs: `20261109T191127Z` (first, stopped after chat), `20261109T214926Z` (reduced), `20261109T234222Z` and
later (re-runs after the fixes below).

| step | dry status | what it showed (NOISY/DRY) |
|---|---|---|
| prep.* (machine, power, disk, bench-release, binaries, runtime-video, gpu-burn, models) | ok | `make bench-release` 9.9 min on Xcode 27.2; runtime + gpu-burn built; dev models present |
| chat.C1.T0 | ok | p50 0.129 s, n 1 (first dry run) |
| chat.U3.T1 (new driver) | ok | status 4 ms after send, first token 2.0 s (budget M1 band + C1 = 4.5 s), n 1 |
| ui.U1 | dry-skip | foreground launch takes focus → T05 only (see §7); the old background launch recorded n = 0 |
| ui.U9 | ok after fix | p50 6.8 ms, p95 14.4 ms, n 30 (readiness fixed: it waited for a `launchToUsable` a background run never records) |
| ui.B1 (new driver) | ok | mean Energy Impact over 15 s: p50 0.4, n 15 |
| ui.U5 | see note | RendererProbe found no window in a background run → fixed (waits for `state.window`); re-run result in the note below |
| voice.V7.T1 / V6.T1 | ok / fail (bar) | V7 0.037 s; V6 0.70 s vs 0.6 s (n 1, load 20+: a bar miss on a busy machine, not a probe fault) |
| voice.V5 | ok | p50 4.8 ms, n 3 |
| photo.P1.bench | ok | 768² q4 at T3-48: final 10.3 s, first preview 3.2 s (52 min of it was the GPU queue) |
| video.T4 | ok | vid-5b 1280×704 × 121 f, 3 steps: final 63.3 s (bar S4 ≤ 90 s), first preview none shown (VID2 open, A-M0-T07c) |
| video.speed-table (dry: `--check`) | ok | bundled JSON = YAML |
| search.e2e.T1 | fail (bar) | complete 17.0 s vs ≤ 12 s, 1/1 runs with ≥ 2 pills; **`<web_results>` prefill 4 403 tokens** — measure per tier in T05 before tuning (M9-card) |
| csc.body-age (dry) | ok after fix | proxy-set folder present (not read), csc-bench builds, `calibrate.py tables` runs |
| pr1.capture (1 min) | ok | `result.json` pass, nettop + lsof leg |
| m5.10mbps, d3.real, r1.soak.T2-24/T0, photo.P4.T3 | dry-skip | long real downloads / soaks; same drivers as exercised steps or first run in T05 |
| report.compare | ok | 91 compared, 15 not comparable (noisy), 0 S1 / 0 S2 (baseline is pre-LPM-fix, informational) |
| owner / blocked rows | printed | U2/U6/U10/U11, P3, B5, PR1 tcpdump (owner); IMAGE_TURN_OVERHEAD, F7_VIDEO, B3 (blocked) |

**U5 after the fix** (`20261109T235329Z`): the probe runs end to end (renderer.json, 120 fps recording, frametime, layout-jump legs): reveal apply median 97.8 ms and 1 322 main-thread hitches at `-RendererCPUScale 0.25` with load ≈ 20 (FAIL on a busy machine; the bar is judged in T05). Layout jumps 0 px, word fade active.

**Probe faults found and fixed by the dry run:** U1 and U9 never recorded `launchToUsable` in a background run (U1 now
a foreground launch, T05 only; U9 readiness = first perf-log record + 10 s); RendererProbe (U5) looked the window up by
title only; `at-008-probe.sh` launched into onboarding (`-SkipOnboarding YES`); the body-age step double-wrapped
`gpu-run.sh shared` (calibrate.py wraps itself); `t05.py` now marks a probe that runs but samples nothing (n = 0) as
an error, and structural dry checks no longer need a result file.

### Dry-run pending — first exercised in T05

These GPU steps were not dry-run (GPU queue; the same probe code ran for their family above). Exact T05 commands
(`$T05_*` as in §4; `make perf-all STEPS=<step>` runs one with the right env):

| step | GPU | exact T05 command |
|---|---|---|
| `chat.C1.T1` | run.py | `python3 -I tools/perf/run.py --metric C1 --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.C1.T2` | run.py | `python3 -I tools/perf/run.py --metric C1 --tier T2 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.C1.T3` | run.py | `python3 -I tools/perf/run.py --metric C1 --tier T3 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.C1b.T0` | run.py | `python3 -I tools/perf/run.py --metric C1b --tier T0 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.C1b.T1` | run.py | `python3 -I tools/perf/run.py --metric C1b --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.C1b.T2` | run.py | `python3 -I tools/perf/run.py --metric C1b --tier T2 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.C1b.T3` | run.py | `python3 -I tools/perf/run.py --metric C1b --tier T3 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.C2.T0` | run.py | `python3 -I tools/perf/run.py --metric C2 --tier T0 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.C2.T1` | run.py | `python3 -I tools/perf/run.py --metric C2 --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.C2.T2` | run.py | `python3 -I tools/perf/run.py --metric C2 --tier T2 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.C2.T3` | run.py | `python3 -I tools/perf/run.py --metric C2 --tier T3 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.C4.T0` | run.py | `python3 -I tools/perf/run.py --metric C4 --tier T0 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.C4.T1` | run.py | `python3 -I tools/perf/run.py --metric C4 --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.C4.T2` | run.py | `python3 -I tools/perf/run.py --metric C4 --tier T2 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.C4.T3` | run.py | `python3 -I tools/perf/run.py --metric C4 --tier T3 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.M1.T0` | run.py | `python3 -I tools/perf/run.py --metric M1 --tier T0 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.M1.T1` | run.py | `python3 -I tools/perf/run.py --metric M1 --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.M1.T3` | run.py | `python3 -I tools/perf/run.py --metric M1 --tier T3 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.C7.T1` | run.py | `python3 -I tools/perf/run.py --metric C7 --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.C7.T3` | run.py | `python3 -I tools/perf/run.py --metric C7 --tier T3 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `chat.U3.T3` | run.py | `python3 -I tools/perf/run.py --metric U3 --tier T3 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V7.T3` | run.py | `python3 -I tools/perf/run.py --metric V7 --tier T3 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V7.T0` | run.py | `python3 -I tools/perf/run.py --metric V7 --tier T0 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V10.T1` | run.py | `python3 -I tools/perf/run.py --metric V10 --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V1.T1` | run.py | `python3 -I tools/perf/run.py --metric V1 --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V1b.T1` | — | `VOICE_RAW=$(ls -t build/perf/raw/m1/V1-T1-*.jsonl ¦ head -1) python3 -I tools/perf/run.py --metric V1b --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V2.T1` | — | `VOICE_RAW=$(ls -t build/perf/raw/m1/V1-T1-*.jsonl ¦ head -1) python3 -I tools/perf/run.py --metric V2 --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V283_EOS_FINAL.T1` | — | `VOICE_RAW=$(ls -t build/perf/raw/m1/V1-T1-*.jsonl ¦ head -1) python3 -I tools/perf/run.py --metric V283_EOS_FINAL --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V1.T3` | run.py | `python3 -I tools/perf/run.py --metric V1 --tier T3 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V1b.T3` | — | `VOICE_RAW=$(ls -t build/perf/raw/m1/V1-T3-*.jsonl ¦ head -1) python3 -I tools/perf/run.py --metric V1b --tier T3 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V2.T3` | — | `VOICE_RAW=$(ls -t build/perf/raw/m1/V1-T3-*.jsonl ¦ head -1) python3 -I tools/perf/run.py --metric V2 --tier T3 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V283_EOS_FINAL.T3` | — | `VOICE_RAW=$(ls -t build/perf/raw/m1/V1-T3-*.jsonl ¦ head -1) python3 -I tools/perf/run.py --metric V283_EOS_FINAL --tier T3 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V1.T0` | run.py | `python3 -I tools/perf/run.py --metric V1 --tier T0 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V1b.T0` | — | `VOICE_RAW=$(ls -t build/perf/raw/m1/V1-T0-*.jsonl ¦ head -1) python3 -I tools/perf/run.py --metric V1b --tier T0 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V2.T0` | — | `VOICE_RAW=$(ls -t build/perf/raw/m1/V1-T0-*.jsonl ¦ head -1) python3 -I tools/perf/run.py --metric V2 --tier T0 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V283_EOS_FINAL.T0` | — | `VOICE_RAW=$(ls -t build/perf/raw/m1/V1-T0-*.jsonl ¦ head -1) python3 -I tools/perf/run.py --metric V283_EOS_FINAL --tier T0 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V283` | wrap | `ANTICHAT_VOICE_IT=1 ANTICHAT_FIXTURES=$ANTICHAT_FIXTURES ANTICHAT_V283=1 make test-unit FILTER=TurnSplitFixtureTests/eagerSTTLatency && python3 -I tools/perf/run.py --metric V283_EOS_FINAL --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V4` | wrap-shared | `ANTICHAT_VOICE_IT=1 ANTICHAT_FIXTURES=$ANTICHAT_FIXTURES make test-unit FILTER=TurnSplitFixtureTests/fiftyUtterancesCleanAndNoise && python3 -I tools/perf/run.py --metric V4 --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 1` |
| `voice.V3` | wrap | `ANTICHAT_VOICE_IT=1 ANTICHAT_FIXTURES=$ANTICHAT_FIXTURES make test-unit FILTER=BargeInFixtureTests && python3 -I tools/perf/run.py --metric V3 --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 1` |
| `voice.V8.T1` | run.py | `python3 -I tools/perf/run.py --metric V8 --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V8.T0` | run.py | `python3 -I tools/perf/run.py --metric V8 --tier T0 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V8.T3` | run.py | `python3 -I tools/perf/run.py --metric V8 --tier T3 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `voice.V11.T0` | run.py | `python3 -I tools/perf/run.py --metric V11 --tier T0 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 3` |
| `voice.V11.T1` | run.py | `python3 -I tools/perf/run.py --metric V11 --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 3` |
| `voice.V11.T3` | run.py | `python3 -I tools/perf/run.py --metric V11 --tier T3 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 3` |
| `voice.V9` | wrap-shared | `ANTICHAT_VOICE_IT=1 ANTICHAT_FIXTURES=$ANTICHAT_FIXTURES make test-unit FILTER=WERFixtureTests && python3 -I tools/voice/wer.py --in build/at/AT-284/wer.json --budget NFR-V9 --tier T1; python3 -I tools/perf/run.py --metric V9 --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 1` |
| `photo.handoff.T1` | wrap | `make test-integration-real TIER=T1 FILTER=ImageHandoffTests` |
| `photo.M3.T2-24` | wrap | `build/AntiChat.app/Contents/MacOS/AntiChat -Bench coresident --tier-cap T2-24 --model chat-9b-q4 --quant q8 --res 1024 --runs 10 --prompts $ANTICHAT_FIXTURES/images/prompts-50.json --out-dir "$T05_OUT/image-out" --raw "$T05_OUT/coresident-T2-24.jsonl"` |
| `photo.JOB_CANCEL_FREE` | wrap | `build/AntiChat.app/Contents/MacOS/AntiChat -Bench cancel --quant q4 --res 1024 --runs 10 --cancel-step 2 --tier-cap T1 --prompts $ANTICHAT_FIXTURES/images/prompts-50.json --out-dir "$T05_OUT/image-out" --raw "$T05_OUT/cancel-q4-1024.jsonl"` |
| `photo.IMAGE_TURN_OVERHEAD` | run.py | `python3 -I tools/perf/run.py --metric IMAGE_TURN_OVERHEAD --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `photo.P4.T1` | wrap | `ANTICHAT_REAL_SD=1 ANTICHAT_PERF=1 ANTICHAT_FIXTURES=$ANTICHAT_FIXTURES make test-unit FILTER=EditTimingTests` |
| `photo.P5` | wrap | `ANTICHAT_PERF=1 ANTICHAT_FIXTURES=$ANTICHAT_FIXTURES make test-unit FILTER=RemoveBackgroundTimingTests` |
| `photo.R4-R5` | wrap | `make test-integration-real TIER=T1 FILTER=ResidentSetTests && make test-unit FILTER=LighterFallbackTests,OverBudgetRefusalTests` |
| `csc.F7` | run.py | `python3 -I tools/perf/run.py --metric F7 --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `video.F7_VIDEO.T3` | run.py | `python3 -I tools/perf/run.py --metric F7_VIDEO --tier T3 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 3` |
| `video.T3-480p` | wrap | `ANTICHAT_REAL_VIDEO=1 ANTICHAT_VIDEO_BENIGN=1 make test-unit FILTER=VideoBenignGateTests` |
| `video.VID3.t2v` | wrap | `ANTICHAT_REAL_VIDEO=1 ANTICHAT_VID3_N=7 make test-unit FILTER=VideoCancelTests` |
| `video.VID3.i2v` | wrap | `ANTICHAT_REAL_VIDEO=1 ANTICHAT_I2V=1 ANTICHAT_I2V_CANCEL=1 make test-unit FILTER=I2VRealTests/cancelMidDenoiseFreesTheServerWithinTwoSeconds` |
| `search.ttft.T1` | run.py | `python3 -I tools/perf/run.py --metric search --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `search.ttft.T3` | run.py | `python3 -I tools/perf/run.py --metric search --tier T3 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 20` |
| `search.AT-266` | wrap-shared | `for t in T2 T0; do .build/release/antichat-bench tool-select --tools $ANTICHAT_FIXTURES/tools/forty-tools.json --fixture $ANTICHAT_FIXTURES/prompts/tool-select-200.jsonl --tier $t --out "$T05_AT/AT-266/t05-$t.json" ¦¦ exit 1; done` |
| `m5.50mbps` | wrap | `build/AntiChat.app/Contents/MacOS/AntiChat -Bench firstchat --rate 50 --runs 20 --raw "$T05_OUT/firstchat-50.jsonl"` |
| `r1.soak.T1` | soak | `tools/soak/mini-soak.sh --tier T1 --minutes 60 && python3 -I tools/perf/run.py --metric R1 --tier T1 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 1` |
| `r1.soak.T3-48` | soak | `tools/soak/mini-soak.sh --tier T3-48 --minutes 60 && python3 -I tools/perf/run.py --metric R1 --tier T3-48 --out "$T05_REPORT" $T05_PERF_FLAGS --runs 1` |
| `stepaside` | wrap | `make test-integration-real TIER=T1 FILTER=StepAsideRealTests` |
| `files.warm` | wrap | `.build/release/antichat-bench files-warm --doc $ANTICHAT_FIXTURES/docs/warm-10k.pdf --followups $ANTICHAT_FIXTURES/docs/warm-10k-followups.jsonl --tier T2 --runs 20 --out "$T05_AT/AT-279/t05-files-warm.json"` |
| `files.spreadsheet` | wrap-shared | `.build/release/antichat-bench fileout-golden --set $ANTICHAT_FIXTURES/prompts/fileout-golden --tier T1 --model chat-9b-q4 --out "$T05_AT/AT-273/t05/model"` |
| `files.presentation` | wrap-shared | `.build/release/antichat-bench fileout-golden --set $ANTICHAT_FIXTURES/prompts/pptx-golden-20.jsonl --tier T1 --model chat-9b-q4 --out "$T05_AT/AT-275/t05/model"` |

## 7. Open items for the lead / owner

- **U1 takes focus.** NFR-U1 is a foreground launch (Dock click → composer focused); a dev-container launch is a
  BackgroundRun that never activates, so `run.py` refuses U1 unless `ANTICHAT_PERF_FOREGROUND=1`, which `t05.py run`
  sets: T05 runs with the owner away from the Mac. U9 and B1 stay background runs (no focus taken).
- **U1 / B1 on a Release build.** The Release app ignores `-ANTICHAT_DEV_CONTAINER`, so a Release launch uses the
  real `app.antichat` container (the owner's try-out data). The runner defaults to the Debug app (`valid=false`).
  Decide: allow `U1_APP=build/dd-bench/Build/Products/Release/AntiChat.app` on this Mac (after the owner quits the
  try-out), or keep U1/B1 at Debug + a Release spot check. C1R/C2R stay visual-QA runbooks (M2.md).
- **Resolved on `m9/t05-drivers` (2026-11-10)** — see §5b: IMAGE_TURN_OVERHEAD, F7_VIDEO, the XCUITest legs
  (U2/U6/U10/U11, P3, B5, PR1 journeys 2/7/8), V8/V11 per tier, R1 at T3-48, NFR-M5 10 Mbps × 20.
- **Still owner / blocked:** `pr1.tcpdump` (root for /dev/bpf*, Q-028; capture-30min.sh records the pcap itself when
  `sudo -n` works), `video.B3` (no way to put the SoC in `.serious` on purpose; in-process ThermalPolicyTests), the real
  `memory_pressure` leg of files.warm (root). **JOB_CANCEL_FREE (AT-291 AC3)** stays the `-Bench cancel` proxy.
- **XCUITest sessions collide across worktrees** (one `app.antichat.AntiChat.dev` / `AntiChatUITests.xctrunner`):
  run the XCUITest steps only with no other track's UI tests running (T05's no-other-tracks rule covers it).
- **Findings from the smoke runs to check in T05:** P3 — the job card's progress *text* stayed unchanged for 16.8 s of
  a 17.5 s scripted job (the pixels changed within 2.4 s, which is what the leg gates on); PR1 J07 — in a fresh
  container with `-FakeEvilEnabled YES` neither ⇧⌘E, the File menu nor the composer's Evil segment switched the new chat
  to Evil (recorded as `j07_evil_seen`; J07EvilChatTests / fix/xcuitest-catchup own the Evil flow).
- **XCUITest steps take the foreground** (like U1): T05 runs them with the owner away. They need
  `ENABLE_HARDENED_RUNTIME: NO` on the UI-test target (also on `fix/xcuitest-catchup`, identical lines).
- **Debug-build numbers:** the new `-Bench` probes (image-turn, read-aloud, transcribe-file, video) run the Debug app
  (dev models, dev detectors) and are filed `valid=false` like the other `-Bench` voice/image probes (§2 Builds).
