# M5 report: Video (close-out, M5.T14)

**Date:** 2026-11-08 · **Branch:** `m5/video` · **Host:** MacBook Pro M5 Max 128 GB (S4/T4), macOS 26.6.2, T3 cap where stated.
**Scope (D-025):** every M5 AT, AT-285 on real video, journey 6, offline + `lsof`, the gate-bypass checklist, the
headline numbers VID1 / VID2 / VID3-cancel at T3. P1/F7/R1/M4 re-runs → M9.T05; blind scoring of the video screens →
M9.T08. Video joins `ModelPack.shipped` in this task.

## 1. Acceptance tests

Status: **pass** · **pending (reason)** · **deferred (M9.T05 / M9.T08)**. Artefacts are under `build/at/`.

| AT | What | Status | Artefact |
|---|---|---|---|
| AT-022 | Library: images, videos, files (R-022 AC1–AC4) | pass (in-process: LibraryIndex / LibraryView / FTS suites); XCUITest leg `LibraryTests` pending (Q-015) | `build/at/AT-022/2026-11-08.log` |
| AT-040 | Text → video, plan card → job → clip (R-040 AC1–AC4) | pass (VideoTools / VideoRoute / gate / VID1 proxy); XCUITest `VideoEntryTests` pending (Q-015); `VideoQueueXPCTests` pending (integration host not regenerated); completion notification clause pending M8 (AT-042) | `build/at/AT-040/2026-11-08.log` |
| AT-041 | Job card: progress, background, heat, yielding, cancel (R-041 AC1–AC4) | pass (VideoJobCard / GPUYieldMonitor / ThermalPolicy / VideoCancel suites); `testPausedForOtherApp` with gpu-burn pending (real run); XCUITest `VideoJobCardTests` pending (Q-015) | `build/at/AT-041/2026-11-08.log` |
| AT-043 | Image → video (R-043 AC1–AC2) | pass (SDVideoEngineTests, R241 I2V trace: source never checked); I2VRealTests pass, SSIM 0.971 | `build/at/AT-043/2026-11-08.log`, `build/at/M5.T04/` |
| AT-044 | Plan card presets / advanced only in Settings (R-044) | pass (VideoPlanCardTests); XCUITest `VideoPlanTests` pending (Q-015) | `build/at/AT-044/2026-11-08.log` |
| AT-045 | Inline player + MP4 export, Library video (R-045) | pass (InlineVideoPlayer / MediaProvenanceMP4Export suites; MP4Export folded into MediaProvenanceWriter.exportMP4); XCUITest `VideoPlayerTests`, `LibraryTests/testVideosTab` pending (Q-015) | `build/at/AT-045/2026-11-08.log` |
| AT-046 | Eligibility + estimate (R-046) | pass (VideoEstimatorTests, VideoEligibilityTests); XCUITest `VideoEligibilityTests` pending (Q-015) | `build/at/AT-046/2026-11-08.log` |
| AT-285 (video) | ChildSafetyCheck on every shown/written video frame, nothing on block (R-285) | pass: runner (forced-verdict + normal suites, incl. the M5.T14 cancel-during-check/encode legs) and the real-video benign run; benign false-block rate 7/60 → 1/60 after A-M5-07 | `build/at/AT-285/`, `build/at/AT-M5-preview-fp/` |
| AT-287 (video) | AI mark + details in the MP4 (R-287 AC3) | pass: real FastMetal clip (XMP uuid box, playable) | `build/at/AT-287/2026-11-08-video.log` |
| AT-290 | Countdown / auto-start rule (R-290 AC1–AC3) | pass in-process (VideoPlanCardTests 9/9); XCUITest `VideoPlanTests` pending (Q-015); T3 calibration (`make perf METRIC=VIDEO_ESTIMATE`) pending (real run) | `build/at/AT-290/2026-11-08.log` |
| AT-292 | Sound track on T3+ Normal (R-292, LTX-2.3) | pass: real LTX job 163 s, audio muxed after allow; Sound hidden in Evil (VideoSoundTests); XCUITest `VideoSoundTests` pending (Q-015) | `build/at/AT-292/2026-11-08-test_ltx.log` |
| AT-NFR-VID1 | Default clip time at T3 | pass (proxy): product-path benign run (gpu-run shared, load 24–31, T3/S4 480p 73 frames) p50 45.5 s, p90 59.8 s over 59 results (first cold job 439 s incl. model load); timing-mode number deferred (M9.T05) | `build/at/AT-M5-preview-fp/after.json` |
| AT-NFR-VID2 | First preview latency | pending (A-M0-T07c open): the first shown preview is now the last denoise step (A-M5-07), later than the target; card shows real step progress before it | `build/at/AT-M5-preview-fp/` |
| AT-NFR-VID3 | Cancel ≤ budget, memory back | pass: runtime 0.3.2 (collect before clear_cache) — 21/21 cancelled, memory back 21/21, p95 1.55 s, max 1.56 s; the earlier miss (+390 MB) is gone | `build/at/AT-NFR-VID3/2026-11-08-rerun3.md` |
| AT-NFR-F9 | Video frames sampled ≥ 2 fps + first + last | pass (VideoGateTests / R241 video trace / VideoFrameSampler; M5.T14: only the sampled frames are decoded, same coverage) | `build/at/AT-285/` |
| AT-NFR-F7 (video) | Check share of a video job | deferred (M9.T05, lead 2026-11-08): real timing run | `build/at/AT-NFR-F7/` |
| AT-NFR-B2 (video) | Low Power / battery ask | pass (VideoPlanPolicyTests); XCUITest pending (Q-015) | `build/at/AT-044/2026-11-08.log` |
| AT-NFR-B3 | Heat: paced / paused hot / resume | pass in-process (ThermalPolicy, VideoJobGovernor); `make perf METRIC=B3_SERIOUS` deferred (M9.T05, lead 2026-11-08) | `build/at/AT-041/2026-11-08.log` |
| AT-NFR-B4 (video) | Battery default step-down | pass (VideoPlanPolicyTests); XCUITest pending (Q-015) | `build/at/AT-044/2026-11-08.log` |
| AT-NFR-B5 | Yield to another GPU app | pass in-process (GPUYieldMonitorTests, fixture IORegistry); gpu-burn run deferred (M9.T05, lead 2026-11-08) | `build/at/AT-041/2026-11-08.log` |
| AT-VQ-M5 | vq-06 visual QA + blind scoring | pending (waits for the owner, lead 2026-11-08): needs computer use (runbook `tools/visual/vq-06-video.md`); blind scoring deferred (M9.T08) | — |
| Journey 6 | plan card → start → away → back (test-strategy §4.1) | pending (Q-015): `Journey06VideoTests` written; in-process legs pass (VideoJobCard re-attach, queue survives window close); notification step = M8 (AT-042) | `build/at/AT-041/2026-11-08.log` |
| Offline + `lsof` | runtime + sd-server open only unix sockets | pass for the runtime (VideoRuntimeProcessTests: no TCP listener per `lsof`; VideoRuntimeInstallTests: selftest under `deny network*`); `make test-offline` journeys + a video job pending (real run) | `Packages/Engines/Tests/AntiChatEnginesTests/VideoRuntimeProcessTests.swift` (no build/at artefact yet) |
| M5.T14 review fixes | incognito media queue, xfer cleanup, I2V release, late cancel, sd cancel grace, P2 set | pass (regression tests listed in the commit; runtime 0.3.1 pytest 9 passed, 2 skipped) | `build/at/M5.T14/2026-11-08-runtime-0.3.1-pytest.log` |

Also: helper `engines` segfault fixed (ASan/lldb before, clean after) → `build/at/engines-segv/2026-11-08.md`.
Perf legs `B3_SERIOUS`, B5 with gpu-burn and `F7_VIDEO` are deferred to M9.T05 (lead 2026-11-08), with the P1/F7/R1/M4 re-runs. XCUITest legs (Q-015) and vq-06 wait for the owner.

## 2. Amendments

| ID | What | Status |
|---|---|---|
| A-M5-02 | latent-projection previews | not needed (TAEHV pinned) |
| A-M5-03 / A-M5-06 | ungated text encoders | resolved by D-016 |
| A-M5-04 | sound engine = ltx-2-mlx in the video runtime | accepted (minor) |
| A-M5-05 | VID1 n = 20 / 5 | open (VID1 proxy n = 59 here; timing-mode run in M9.T05) |
| A-M5-07 | previews before 3/4 of the schedule not shown (false blocks 7/60 → 1/60) | accepted (lead); the VID2 consequence stays with A-M0-T07c (open) |
| A-M5-08 | MP4 provenance as XMP uuid box | accepted (minor) |
| A-M5-09 | one bounded re-check after a ChildSafetyCheck timeout | accepted (lead); M5.T14: the re-check waits for the timed-out run (inside the 10 s), never runs beside it |
| A-M5-10 | video speed table bundled, not in the signed catalog | open (next catalog schema bump) |

STATUS: M5 done with pending legs — Video ships (`ModelPack.shipped`); AT-285 on real video passes; open: NFR-VID2 (A-M0-T07c), XCUITest legs (Q-015, owner), AT-VQ-M5 (computer use / M9.T08), perf real runs (B3/B5/F7_VIDEO → M9.T05), notification clause (M8, AT-042).
