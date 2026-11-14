# M5 card: video runtime, generator, supervisor, gate, sound, plan card, job card, player, Library

Read `BUILD-BRIEF.md` first, then this card, then only your task sections in `M5.md`. This card doesn't repeat task steps. Where it and `M5.md` disagree on a repo fact, the card is right (checked against the tree on 2026-11-07, main `6b3d8fb0` + M6.T15/T16 merged into `m5/video`).

## What M5 delivers
Text-to-video (FastMetal Wan2.2-TI2V-5B on MLX in a signed, hash-locked Python runtime) and image-to-video (Wan2.2 GGUF through `sd-server`), driven by the helper over a unix socket with real step progress, small previews, in-memory frames and a ≤ budget cancel. Every frame that is shown or written passes `MediaOutputGate` first. An honest plan card (estimate, presets, the R-290 countdown rule), a VideoJobCard that survives window close and yields to heat and other apps, an inline player with MP4 export, a sound track on T3+ Normal (LTX-2.3), and one Library for images, videos and files.
**Exit:** `M5.md` header "Exit" row; journey 6 green except the completion notification (R-042 closes in M8); AT-285 re-run on real video.

## Order and chunks (BUILD-ORDER chunks 18–19)
[T01 T02 T03 T04 T05 T06 T07] [T08 T09 T10 T11 T12 T13 T14].
T01 → T02 → T03 → (T04, T05) → T06 → T07 · T08 → T09 → T10 → T11 · T05 → T12 → T13 · all → T14.
Start after photo's GPU-heavy runs; never run two video jobs at once.

## Safety (D-005 / D-006, hard rules)
- The only filter is `ChildSafetyCheck` via `MediaOutputGate`, called only from `Jobs/MediaJobRunner.swift` (R-241 audit rule 2). No check on prompts, audio tracks or the I2V source image.
- **Nothing unchecked is ever shown or written**, scratch included. The runtime keeps frames in memory and serves them over the socket; it never writes a frame or a video file (T02 tests this).
- Previews go through `MediaJobRunner.emitPreview` → `checkPreview` before display (already in M4).
- Final video: `MediaJobRunner.emitVideoResult(frames:fps:audio:)`. From T03 to T06 it is a **stub**: it drops the frames, writes nothing and ends the job `failed` with `video.gateNotWired`. T06 wires `checkVideo` (`sampleIndices` ≥ 2 fps + first + last), then T05's MP4 encode runs only after `allow`.
- Lawful proxies only in tests (Q-012): benign landscape/object prompts, CC0 photos with no people, `-ScriptedSafetyVerdict block` for blocked paths.
- **Video stays out of `ModelPack.shipped`** (`Platform/Catalog/Selection.swift`, today `[.chat]`) until T14 closes M5.
- The M0 bench path (`App/AntiChat/BenchMode+Video.swift` → `EngineRuntime.runVideo` → `Video/VideoClient.swift`) writes clips ungated (files only, never shown). T03 removes it; the bench goes through `VideoEngine` + `MediaJobRunner` like the product.

## Repo reality (the PRD text is older than M0/M4/M6 code)
- **M0.T07 spike already exists** (S-10 report, `docs/research/07-spikes/S-10-video-runtime.md`):
  - `Vendor/FastVideo@d9e6c3e/` with 13 vendored files (`Vendor/FastVideo-allowlist.tsv`, pristine copies in `Vendor/.upstream/`), patches UP-FV-001 (step callback in `sample_wan22_dmd`) and UP-FV-002 (torch-free schedule + safetensors TAEHV). T01 step 1 "vendor FastVideo" = verify, not redo.
  - FastVideo's MLX path is **not torch-free**; our driver replaces the torch pieces (A-M0-T07a): `Packages/Engines/Python/antichat_video/{generate_wan22,umt5,numerics,progress}.py`. No torch, transformers or diffusers in the runtime.
  - `Runtimes/video-runtime/{build.py, base.sha256, requirements.in, requirements.lock}`: CPython 3.12.16 (python-build-standalone 20261026, sha256 `353d5f1b…`), exact pins mlx/mlx-metal 0.32.4, numpy 2.5.4, safetensors 0.8.0, sentencepiece 0.2.2, pillow 13.0.0, `--require-hashes`. M5.md's `pyproject.toml` + `uv.lock` are expressed by `requirements.in` + hash-locked `requirements.lock` (same guarantee; `uv pip compile --generate-hashes`). T01 moves `build.py` → `tools/runtime/build_video_runtime.py` (git mv, keep history); `Runtimes/video-runtime/` keeps only lock inputs.
  - Swift spike: `Engines/Video/{VideoRuntimeSupervisor.swift (VideoChild: posix_spawn, own pgroup, LlamaWatchdog, SIGTERM→3 s→SIGKILL), VideoClient.swift, VideoEncoder.swift}`, protocol v3 `VideoRequest/VideoProgress/VideoResult` in `EngineProtocol/VideoMessages.swift`. `VideoChild` is also used by `SDServerProcessTests`; keep it.
- **D-026 / BUILD-ORDER note 4:** M6.T16 built the generic runtime plumbing; M5.T01 adopts it and writes no installer:
  - `Packages/Platform/Sources/AntiChatPlatform/Runtimes/RuntimeInstaller.swift` (`install(_ CatalogRuntime)`: NFR-D2 preflight → TransferEngine (resume, sha256, one re-fetch) → ditto unzip → containment → `SecStaticCodeCheckValidity` strict + nested on every Mach-O → atomic move to `Runtimes/<name>@<ver>/` → `runtime_install` row (`v28_runtime_install`, renamed from m6's `v16_…`)). `RuntimePaths.default()` = fixed Application Support root, never the dev container (A-M6-T16a).
  - `catalog/runtimes.yaml` (fields `name, version, sha256, size_bytes, url, min_app_version, tiers, signature_mode`) → `make catalog` copies entries into the signed catalog's `runtimes[]`.
  - `tools/release/sign-runtime.sh <dir|zip> <entitlements> [--mode] [--out] [--report] [--update-catalog catalog/runtimes.yaml --name N]` (Briefcase port, inside-out, deterministic re-zip). T01's `tools/runtime/sign_video_runtime.sh` is a thin wrapper with `tools/release/entitlements/video-runtime.plist` (allow-unsigned-executable-memory + disable-library-validation, S-10).
  - These came in by merging M6.T15/T16 (`44814bdb`) into `m5/video`; conflicts were resolved to m6/sandbox's own resolution (`e0e617b6`) so m6's later merge stays clean. M6.T17+ is not included.
  - Dev URL: `make site-dev` serves `site/public/` on `http://localhost:4321` (filetools uses `…/runtimes/<zip>`); the video runtime does the same instead of M5.md's port 8765.
- **Models are on disk** (`~/Library/Application Support/AntiChat-Dev/Models/`, via `tools/dev/hf-fetch.py --set m0-t07`): `vid-5b` 18 GB, `vid-i2v` 6.3 GB, `vid-te` 5.6 GB, `vid-taehv` 44 MB (`madebyollin/taehv@fa579a9:safetensors/taew2_2.safetensors`, MIT). TAEHV weights exist, so T02 previews use TAEHV and **A-M5-02 is not needed**.
- **No `ChildProcessSupervisor` type exists.** The shared pattern is `VideoChild` / `SDServerSupervisor` / `LlamaServerSupervisor` + `LlamaWatchdog` + `CloexecPipe` + `CleanSignals`. T03's `VideoRuntimeProcess` builds on `VideoChild` (P-shell-10 pattern) rather than a new supervisor.
- **Unix-socket HTTP:** `Engines/LLM/UnixHTTPClient.swift` (NWConnection, chunked responses, used by sd-server and llama-server). EventSource 1.5.1 is not a dependency; T03 parses SSE with a small line reader over `UnixHTTPClient`'s streamed body (M5.md's own fallback). No new package.
- **Job runner and gate:** `Jobs/MediaJobRunner.swift` (`run(_:emit:engine:)`, `MediaJobOutputs.preview/progress/result`), `Media/MediaOutputGate.swift` (`checkPreview`, `checkResult`, `checkVideo(frames:frameCount:fps:job:)` already implemented), `ChildSafetyCheck.sampleIndices(frameCount:fps:)` in `VideoFrameSampler.swift`. `Jobs/ScriptedImageEngine.swift` is the pattern for `Jobs/ScriptedVideoEngine.swift` (T03).
- **Scheduler:** `ResidencyRole.video` exists (eviction rank 0, pack `video`); `EngineRuntime.stepAsideForMedia` + `sched.runJob(key:)` evict chat / sd-server for a media job.
- **Launch args:** `Packages/Foundation/Sources/AntiChatFoundation/Debug/LaunchOptions.swift` (`enum Key`); `TestHooks.swift` doesn't exist. Add `-UseScriptedVideoEngine` (T03) and `-UseRealVideoTool` (T14) there, Debug-only.
- **Migrations:** one file, `Packages/Storage/Sources/AntiChatStorage/Database/Migrations.swift`; v1–v28 are taken (v28 = runtime_install). T08 (`video_run_history`) and T13 (`library_fts`) take the next free number on main at the time, not `Migrations/v<N>_*.swift`.
- **Strings:** `App/AntiChat/Localizable.xcstrings` + `Packages/Design/Sources/AntiChatDesign/Copy/CopyDeck.swift` + `docs/research/10-architecture/design-system/copy-deck.md`, then `python3 -I tools/ci/copy-sync.py`.
- **XCUITest can't start on this Mac (Q-015).** Write the UI tests; run the in-process probe path (`tools/at/*-probe.sh`); record the XCUITest leg `pending (Q-015)`.

## Key types and interfaces (names are contracts)
- **Runtime (T01):** `make runtime-video [SIGN=1]` → `build/runtimes/video-runtime/` + `video-runtime-<ver>.zip`; `bin/video-runtime-launcher` (C, `tools/runtime/launcher/video_runtime_launcher.c`) sets `PYTHONHOME/PYTHONPATH/PYTHONNOUSERSITE=1/PYTHONDONTWRITEBYTECODE=1/HF_HUB_OFFLINE=1`, clears proxies and `HF_*` tokens, execs `python3 -I -m antichat_video.server`; `--selftest` imports mlx + `fastvideo.mlx_runtime.wan22`.
- **Server (T02):** `antichat_video.server` (FastAPI + uvicorn on a unix socket, bearer token from env): `GET /health`, `POST /v1/video/jobs`, `GET …/{id}/events` (SSE `progress{stage,step,total}`, `preview{frame_index,width,height,jpeg_b64}`, `frames_ready{count,width,height,fps}`, `error{code}`), `GET …/{id}/frames?start=&count=` (length-prefixed RGBA8, memory only), `POST …/cancel|pause|resume`, `POST /v1/shutdown`. UP-FV-001 adds `pause_check()` too.
- **Helper (T03):** `VideoRuntimeProcess` (launch via launcher, `--uds`, random token, 0700 socket dir, health ≤ 20 s, no TCP), `VideoRuntimeClient` (HTTP + SSE over UDS), `VideoEngine.run(job, outputs:)`, `ScriptedVideoEngine`, `MediaJobRunner.emitVideoResult` (stub until T06), `Harness/Media/VideoChatPolicy.swift` (T2: chat waits, `video.gpuBusy` + `video.pause`).
- Later: `SDVideoEngine` (T04), `MP4Encoder` / `PosterFrame` (T05), `VideoEligibility` / `VideoEstimator` / `VideoHistory` / `VideoETA` (T08), `VideoPlanPolicy.shouldAutoStart` / `VideoPresets` / `VideoPlanCard` (T09), `VideoRoute` / `CreateVideoTool` (T10), `VideoJobCard` / `GPUYieldMonitor` / `ProcessPause` + extend M2's `ThermalPolicy` (T11), `InlineVideoPlayer` / `VideoViewer` (T12), `LibraryIndex` / `LibraryView` (T13).

## Cross-task contracts
1. One heavy GPU job at a time: `MediaJobRunner` serialises; model runs go through `~/AntiChat-tools/gpu-run.sh shared --` (accuracy) or `timing --` (latency/memory; exit 75 = DEFERRED → M9.T05). Check free memory ≥ model size + 20 GB before loading. Never two video jobs at once.
2. The scheduler is the only loader: `ensureLoaded(.video, …)`; T2 unloads chat first, T3+ co-resident when it fits B.
3. Every byte through `NetworkGate`; the runtime is offline (`HF_HUB_OFFLINE=1`, selftest under `sandbox-exec … (deny network*)`); the runtime and sd-server open only unix sockets (`lsof` assertion in T03/T14).
4. Evil video uses Normal media models (Q-009 a); LTX (sound) is Normal-only (K-014), so the Sound chip is hidden in Evil chats.
5. Incognito: MP4 to the temp dir, no `video_run_history` row, never in the Library.
6. Every new string is a copy-deck key, in the deck and the xcstrings file in the same commit.

## Verification scope (D-025, T14)
Keeps all M5 ATs, **AT-285 on real video (untouched)**, journey 6, the offline + `lsof` check, the gate-bypass checklist, and the headline numbers VID1, VID2, VID3-cancel at T3. Moves to M9.T05: P1/F7/R1/M4 re-runs; to M9.T08: blind scoring of the video screens. Also kept: `make test-unit` + `make audit`, an independent `/code-review` (high), a running-app check, 1440×900 light + dark captures with H3–H7. Report = AT table + one STATUS line. Then rebuild the owner try-out.

## M11 (not built)
Library **Templates** tab (R-035, M11 A-candidate) is out; M5.T13 builds All / Images / Videos / Files only. M4.T14's image half of NFR-B4 is in M11; the video half stays in M5.T09.

## Pins and IDs to grep
- **Models:** `vid-5b` = `FastVideo/FastMetal-5B-QAD@5e4819ec…`, `vid-i2v` = `QuantStack/Wan2.2-TI2V-5B-GGUF@57437632…` (+ `vid-te` = `city96/umt5-xxl-encoder-gguf@b535255…`, D-016), `vid-taehv` = `madebyollin/taehv@fa579a9`, `vid-ltx` = `dgrauet/ltx-2.3-mlx-q4@f306259…` (+ `vid-ltx-te` = `mlx-community/gemma-3-12b-it-4bit@86cc6a8…`), `vid-14b` = `FastVideo/FastMetal-14B-QAD@fbc5032…` (T4).
- **Code:** `FastVideo@d9e6c3e`, `nativ@72f4b91`, python-build-standalone `20261026` (`fa506e0`), `ltx-2-mlx@895201df37`, `atomic-chat-core@6c7e9e8` (estimator), `osaurus@2922745` (`LocalVideoRequestPolicy`), sd.cpp `e239e4b`.
- **Amendments:** A-M0-T07a…d (S-10), A-M5-02 (not needed: TAEHV pinned), A-M5-03/-06 resolved by D-016, A-M5-04 (LTX engine), A-M5-05 (VID1 n).
- **Decisions:** D-005, D-006, D-010 (Video sizes incl. runtime), D-013 (our Wan2.2 generator), D-014 (≥ 2 fps), D-016, D-019 (Evil video), D-025, D-026.
- **Patches:** P-media-11…14, P-files-tools-08/-09, P-shell-10/-13.
