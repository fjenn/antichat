# M9 code review and independent triage (M9.T10)

**Base:** `54f648b6c` ("M8.T16: gates green …", 2026-11-08), the last commit of the M8 close on `integration/m0`. It
reached main through `2417e19c3` ("Merge integration/m0 @54f648b6c (M8.T16 close) into queue/8"). No git tag marks
the M8 exit; `docs/prd/M8-report.md` names M8.T16 as the close, and this is its final "gates green" commit.
**Head:** main `a591890f3`. **Range:** `54f648b6c..a591890f3` (1016 commits).

The range is everything that reached main after the M8 close. That includes the M9 branches and also work merged in
the same period: the M4/M5/M6/M7 follow-ups (FileOut, File tools, Skills, Library), the M10 release work, and the
review fixes. Non-test source alone is ~56k inserted lines over 819 files.

**Method.**
1. `/code-review high 54f648b6c..main` gave one pass over the whole range. In practice that pass covered only
   FileOut, so the range was reviewed again area by area, each at **high** effort:
   (a) ChildSafetyCheck, Engines, EngineHost, EngineProtocol, tools/runtime;
   (b) Harness;
   (c) UI and Design;
   (d) App, Storage, Network, Platform, Foundation and Knowledge;
   (e) Tools and FileToolsHost.
   Every pass read non-test sources only. Snapshots, `Localizable.xcstrings` and DEBUG-only probes/benches were
   skipped.
2. Separately from the review passes, the triager read the safety floor directly: `ChildSafetyCheck.swift`,
   `MediaOutputGate`, `MediaJobRunner.emitPreview/emitResult/emitVideoResult`, `VideoCheckStream`, `Thresholds`,
   `ModelManifest` and `SafetyStatus`.
3. Triage: the triager re-read the code behind each finding and assigned a severity with test-strategy §10. The rule
   is quoted where it decides the severity, and the modifiers are applied: +1 for T0/T1, and never below S1 for an
   item on the S0 list. **V** = the triager re-read the code and confirmed the finding. **P** = plausible from the
   reviewer's reading, not re-read by the triager. **✗** = rejected. Nothing was built or run; the soak and gates
   were running.
4. No code was changed. The lead assigns fixes.

**Safety floor verdict.** The verdict logic stays fail-closed: a ChildSafetyCheck timeout leads to one 10 s
re-check and then a block. A detector error while nude or unknown blocks. A preview below `preview_min_side_px` is
withheld, and so is a preview whose check timed out or errored. An incomplete or aborted video stream blocks.
`emitPreview` and `emitResult` write and emit only after `.allow`, and they re-check `withheld`/cancel after every
await. No path shows an output before the allow. The two safety-relevant findings below are in the compiled-model
cache, not in the rule: #E1 (a latent fail-open under an I/O error) and #E2 (a persistent fail-closed lockout).

## Counts

| Severity | Count |
|---|---|
| S0 | 0 |
| S1 | 6 |
| S2 | 12 |
| S3 | 37 |
| S4 | 3 |
| Not a bug | 1 |
| **Total** | 59 |

## S1 / S2 items (release gate: zero open S0/S1; every S2 needs an owner)

**S1**
- **F1** `Packages/Tools/Sources/AntiChatTools/FileOut/FileOutNormalizer.swift:512`: `(1...ctx.attachedImages.count)`
  traps when the chat has no attached pictures (`1...0`). A request such as "deck with photo1" in a chat without
  attachments crashes the app (in-process, Harness). Rule: a crash in normal use on the file journey with no
  workaround.
- **T1** `Packages/Tools/Sources/AntiChatTools/FileOut/FileOutResult.swift:27` (with `RunPythonTool.swift:113` and
  `ActivityLine+RunPython.swift:56`): `parseAll` decodes a file card from any line of the result. `run_python`
  appends raw sandbox stdout, so jailed code can print a forged card whose `path` is any host file. The panel
  auto-opens it. Open runs `NSWorkspace.open` and Save As copies it, from the unsandboxed app. Rule: S0 list
  (security hole / sandbox boundary), held at S1 because it needs a click or a panel view and does not leave the Mac.
- **T9** `Packages/Tools/Sources/AntiChatTools/Skills/CreateSkillTool.swift:87`: `install` checks only for a DB row,
  then installs with `replacing: true`. A `Skills/<name>/` folder dropped in through Finder and not yet reconciled is
  replaced and its backup deleted. Rule: S0 list (data loss), never below S1; the trigger is narrow.
- **E1** `Packages/ChildSafetyCheck/Sources/ChildSafetyCheck/CompiledModelCache.swift:52`: any read failure of
  `weight.bin` (not only ENOENT) falls back to an empty weight file. The compacted MIL then references offsets in a
  new file, and the marker stops any retry. This can give a permanent load failure, or a detector loaded with the
  wrong weights (fail-open). Rule: S0 list (ChildSafetyCheck gate), never below S1. Likelihood is low and the fix is
  one line (only ENOENT means "no file").
- **E3** `Packages/Engines/Sources/AntiChatEngines/Scheduler/EngineRuntime.swift:558` with
  `MediaJobRunner.swift:181`: the T0–T2 image path calls `preloadDetectors()`, which sets `preloadTask`. The
  fix/soak-engine end-of-job release (`if preloadTask == nil`) therefore never runs on the tiers it was written for,
  and the detectors (≈1.5 GB) stay beside the reloaded chat model (helper peak 10.3 GB vs B = 9.5 GB). Rule:
  NFR-R1 miss 5–25 % = S2, +1 for T0/T1 = S1.
- **H8** `Packages/Harness/Sources/AntiChatHarness/Incognito/IncognitoSession.swift:88`: the incognito ToolRuntime
  is rebuilt without `chatFilter`, and its permission store is the empty in-memory DB. MCP tools the user Blocked, or
  that sit on disabled/`conn.off` servers, are therefore offered in incognito. A curated read-only one defaults to
  Always and runs without asking. Rule: S0 list (privacy: incognito content goes to a server the user blocked),
  never below S1. This predates the range (since M7.T06/T14) and was found here.

**S2**
- **F2** `FileOutNormalizer.swift:84`: `wrongToolProblem` treats any single format word as the requested output.
  "numbers from this PDF into a spreadsheet" rejects `create_spreadsheet` and forces a PDF. "doc … for my
  presentation" forces pptx.
- **F3** `FileOutNormalizer.swift:371`: on a `data_ref` sheet the rows are empty, so totals are written as
  `SUM(X2:X11)` at row 12. The total is wrong for any other result size and overwrites data row 11.
- **F4** `Packages/Tools/Sources/AntiChatTools/FileTools/EditOfficeFileTool.swift:629`: `_ac_replace_in_runs` with
  `all:true` replaces twice when the replacement contains the search text ("Q1" to "Q1 FY25" gives "Q1 FY25 FY25"),
  and it collapses the runs, so formatting is lost.
- **E2** `Packages/Engines/Sources/AntiChatEngines/Media/MediaOutputGate.swift:203`: `prepare` is now nonisolated
  and detached, so its ≈170 s compile and compaction can run at the same time as the actor's `loadChecker()` in the
  same `<cache>/<key>/`. A torn compile followed by the compaction marker leaves the set fail-closed
  (`safetyMissing`) for good, while `prepared.json` keeps saying "already prepared". This is likely when the user
  starts an image right after the pack download.
- **E6** `Packages/EngineHost/Sources/AntiChatEngineHost/EngineListener.swift:122`: the EraserCache path is
  hard-coded to `Library/Caches/AntiChat-Dev/coreml-erase` in Release. Dev and Release share the folder, and
  Uninstall/Remove everything does not list it, so files are left after removal (AT-NFR-D7 / AT-226 zero files).
- **H2** `Packages/Harness/Sources/AntiChatHarness/Media/ImageJobRestart.swift:68`: `rewrite` matches every
  `tool_result` whose id equals the activity id with `#n` removed. MLXAdapter reuses `call_<n>` in every step, so
  Restart overwrites other steps' stored tool results (persisted reply corrupted).
- **H3** `Packages/Harness/Sources/AntiChatHarness/Turn/TurnController.swift:1566` (also 1584, 1603): the
  `toolStep` tasks are untracked, and `stop()` never cancels them. A stopped turn still runs its image or video job
  and saves the artifact as an orphan. A video plan card left open waits forever. The new `onCancel` plumbing is dead
  on this path.
- **H4** `TurnController.swift:2147`: `mediaMade` is appended for every `.done` create_image/create_video, including
  `not_shown` (safety block), `not_started` and `failed`. In voice, "The picture is in the chat" is spoken when there
  is none. Rule: misleading copy.
- **U1** `Packages/UI/Sources/AntiChatUI/Renderer/StreamingMarkdownBinder.swift:217`: when the final text is shorter
  than the streamed text and the reply was not interrupted, the reveal rewinds, but `tick()` never applies (0 words)
  and never finishes (`appliedBytes != shown`). The removed text stays on screen and the 40 Hz clock never stops.
- **P1** `Packages/Platform/Sources/AntiChatPlatform/Updates/UpdaterBridge.swift:106`: the gentle reminder sets
  `.ready` with no install block (automatic downloads off), so clicking "Restart to update" does nothing. Workaround:
  Check now.
- **P2** `Packages/Platform/Sources/AntiChatPlatform/Runtimes/RuntimeInstaller.swift:168`:
  `runtimeDidChangeNotification` is posted from the nonisolated async `install`/`remove` (a background thread).
  SwiftUI `.onReceive` (`ToolsSettings+FileTools.swift:120`) then calls the `@MainActor` model off-main, and
  `FileToolsTools` re-registers off-main. Under Swift 6 this is either an isolation trap or an off-main mutation of
  @Observable state. Needs a repro: **S1 if it traps.**
- **P7** `Packages/Foundation/Sources/AntiChatFoundation/IncognitoTemp.swift:68`: `isLive` trusts `kill(pid,0)` or
  EPERM. After a crash, a reused pid (root gives EPERM) keeps a dead session's incognito temp dir "live", so the
  incognito attachments stay on disk (VoiceTemp uses the same check). Rule: incognito "nothing on disk", rare edge.

## Findings

| Id | File:line | Sev | Summary | Verdict |
|---|---|---|---|---|
| F1 | Tools/FileOut/FileOutNormalizer.swift:512 | S1 | `1...0` range trap with no attached pictures, app crash | V · fixed 8e5066967 (round 64) |
| F2 | Tools/FileOut/FileOutNormalizer.swift:84 | S2 | any one format word forces the output tool/format | V · fixed 8e5066967 (round 64) |
| F3 | Tools/FileOut/FileOutNormalizer.swift:371 | S2 | data_ref sheet totals hard-coded to rows 2–11 / row 12 | V · fixed 8e5066967 (round 64) |
| F4 | Tools/FileTools/EditOfficeFileTool.swift:629 | S2 | replace all: double replace + run collapse | V · fixed c913495a5 (round 64) |
| F5 | FileToolsHost/Jail.swift:140 | S3 | openOutputs TOCTOU on intermediate dir symlink (service sandbox still bounds it) | V |
| F6 | Tools/FileOut/FileOutNormalizer.swift:60 | S3 | "500-word document" read as a docx request | V |
| F7 | Harness/Tools/FileOutContext.swift:44 | S3 | duplicated attached-pictures query; 10 vs 20 cap mismatch | V |
| F8 | Tools/FileOut/FileOutNormalizer.swift:428 | S3 | regexes compiled per row/per header on the TurnController actor | V |
| F9 | Harness/Turn/TurnController.swift:130 | S3 | file-out maxTokens floor 2048 exceeds half of a small window | V |
| F10 | Tools/FileOut/FileOutNormalizer.swift:670 | S3 | " (cont.)" accumulates on split slides | V |
| E1 | ChildSafetyCheck/CompiledModelCache.swift:52 | S1 | weight.bin read error → empty file → wrong offsets, marker set (latent fail-open) | V · fixed f096fb8e5 (round 64) |
| E2 | Engines/Media/MediaOutputGate.swift:203 | S2 | detached prepare races loadChecker on the same compiled cache; permanent safetyMissing | V · fixed 3391fd5de (round 64) |
| E3 | Engines/Scheduler/EngineRuntime.swift:558 | S1 | T0–T2 preload defeats end-of-job detector release (NFR-R1) | V · fixed a8261db4d (round 64) |
| E4 | Engines/Jobs/MediaJobRunner.swift:456 | S3 | video result paths lack in-flight guard; no withheld re-check after encode | P |
| E5 | ChildSafetyCheck/ChildSafetyCheck.swift:103 | S3 | parallel detector load: peak = sum of detectors (measure on T0–T2; S1 if OOM) | P |
| E6 | EngineHost/EngineListener.swift:122 | S2 | Release erase cache under AntiChat-Dev; missed by uninstall | V · fixed 860034f43 (round 64) |
| E7 | Engines/Image/MaskCompositor.swift:23 | S3 | `CGContext(...)!` force unwrap can crash the helper on degenerate sizes | V |
| E8 | Engines/Media/MediaOutputGate.swift:118 | S4 | retry counter diff across awaits misattributes counts (logs only) | P |
| E9 | Engines/Video/VideoEngine.swift:297 | S3 | streamed path ignores runtime fps (tier-dependent clip timing) | P |
| H1 | Harness/Turn/TurnController.swift:1564 | — | forced-tool path reuses requestID | ✗ `startStep` assigns `run.requestID = UUID()` (:1833) |
| H2 | Harness/Media/ImageJobRestart.swift:68 | S2 | restart rewrites other steps' tool_results with the same call id | V · fixed 3857eaa73 (round 64) |
| H3 | Harness/Turn/TurnController.swift:1566 | S2 | Stop does not cancel tool tasks; media still made and saved | V · fixed 1c986b0d5 (round 64) |
| H4 | Harness/Turn/TurnController.swift:2147 | S2 | voice says the picture is in the chat after block/cancel | V · fixed be20f4365 (round 64) |
| H5 | Harness/Media/ImageDescriptionService.swift:42 | S3 | incognito pictures described via a non-incognito request; text kept in memory until quit (no disk) | V |
| H6 | Harness/Turn/TurnController.swift:837 | S3 | ensureTools unregisters run_skill_script on the shared registry mid-turn of another chat | V |
| H7 | Harness/Prompt/PromptDump.swift:39 | S4 | full-request dump has no incognito check (DEBUG/perf harness, `-DumpPrompts` only) | P |
| H8 | Harness/Incognito/IncognitoSession.swift:88 | S1 | incognito runtime drops chatFilter: blocked MCP tools offered/run | V · fixed c0ba02292 (round 64) |
| H9 | Harness/Voice/VoiceSessionController.swift:80 | S3 | call start does not check app-wide dictation (two mic streams) | P |
| H10 | Harness/Media/VideoTools.swift:258 | S3 | save failure returns done with job id/xfer path; files leak | P |
| U1 | UI/Renderer/StreamingMarkdownBinder.swift:217 | S2 | shorter final text: stale words shown, reveal clock never stops | V · fixed c7b871ad5 (round 64) |
| U2 | UI/Window/ChatSessions.swift:152 | S3 | deinit leaves connectionsObserver registered | V |
| U3 | UI/Library/LibraryModel.swift:32 | S3 | MessageReveal.shared never cleared; transcript jumps back | P |
| U4 | UI/Accessibility/StreamAnnouncer.swift:107 | S3 | cancelled drain clears the newer drain; double drain | V |
| U5 | UI/Conversation/ConversationModel.swift:1410 | S3 | background windows' replies announced over the focused chat | P |
| U6 | UI/AppBootstrap.swift:121 | S3 | detached initial catalog apply can overwrite a newer snapshot | P |
| U7 | UI/Renderer/MarkdownSegmenter.swift:96 | S3 | `$$` inside code merges the rest of the reply into one unstable block | P |
| U8 | UI/Media/InlineVideoPlayer.swift:157 | S3 | State init builds an AVQueuePlayer per re-eval; poster read on main each body | P |
| U9 | UI/Conversation/ConversationModel.swift:200 | S3 | editImage chips leak to a queued follow-up turn | P |
| U10 | UI/Onboarding/SetupLaunch.swift:345 | S3 | cite_check once-flag set before preconditions; never retried this launch | P |
| P1 | Platform/Updates/UpdaterBridge.swift:106 | S2 | "Restart to update" pill without install block does nothing | V · fixed 9d98e9dd2 (round 64) |
| P2 | Platform/Runtimes/RuntimeInstaller.swift:168 | S2 | change notification posted off-main into @MainActor observers (S1 if it traps) | V (code); trap not reproduced · fixed e1025df09 (round 64) |
| P3 | App/AntiChat/AntiChatApp.swift:201 | S3 | launch sweep drops user descriptions of non-blob images (generated/attached ones are blobs) | V |
| P4 | Storage/ImportExport/ChatImporter.swift:202 | S3 | new content dedup key ignores old `title|createdAt` records: re-import duplicates | V |
| P5 | Platform/Updates/UpdaterService.swift:74 | S3 | checkNow overwrites `.ready`; can stick at "Checking…" | V |
| P6 | Storage/ImportExport/AntiChatImporter.swift:209 | S3 | crafted export can point parent/leaf/active_child into another chat | P |
| P7 | Foundation/IncognitoTemp.swift:68 | S2 | pid reuse keeps a crashed incognito temp dir forever | V · fixed b20d64b95 (round 64) |
| P8 | Platform/Runtimes/RuntimeInstaller.swift:203 | S3 | symlink preflight case-sensitive on a case-insensitive volume (zip is sha-pinned) | P |
| P9 | Storage/Library/LibraryIndex.swift:102 | S3 | items() scans and decodes everything before filtering/limit | P |
| P10 | Platform/ProcessLauncher.swift:51 | S4 | output over the limit throws instead of truncating (doc mismatch) | P |
| T1 | Tools/FileOut/FileOutResult.swift:27 | S1 | sandbox stdout can forge a file card pointing at any host path | V · fixed bc6eacd54 (round 64) |
| T2 | Tools/FileTools/RunPythonTool.swift:134 | S3 | case-only duplicate input names overwrite each other in the jail | P |
| T3 | Tools/FileTools/EditOfficeFileTool.swift:443 | S3 | `_AC_SET_TEXT` persists in the REPL, disabling the pptx content-loss check later (versions keep the original) | P |
| T4 | FileToolsHost/SessionPool.swift:295 | S3 | idle reaper races a run starting at the 10-min mark | P |
| T5 | FileToolsHost/Jail.swift:178 | S3 | lock open errors other than EWOULDBLOCK treat a live instance as dead | P |
| T6 | Tools/FileTools/RunPythonTool.swift:129 | S3 | jailName can start/end with whitespace and fail the run | P |
| T7 | Tools/FileTools/FileToolsClient.swift:104 | S3 | late INVALID of an old XPC connection clears the new one (leak) | P |
| T8 | Tools/FileOut/ArtifactStore.swift:68 | S3 | file written before the blob dedup: orphan copies; rare race deletes a referenced file | P |
| T9 | Tools/Skills/CreateSkillTool.swift:87 | S1 | create_skill install replaces an unreconciled user Skills folder | V · fixed 0afc04159 (round 64) |
| T10 | Tools/Search/Fetch/PageFetcher.swift:288 | S3 | redirect bodies read without a size cap until the timeout | P |

Paths are relative to `Packages/` unless they start with `App/`.

## Notes for the lead

- H8 predates the range (since M7). It is listed because the review found it, and the release gate counts it.
- P2 and E5 depend on runtime behaviour that could not be measured during the soak. Each has a repro to run: an
  install in Settings › Tools under Swift 6, and the first detector load on T0–T2. Either moves to S1 if it
  reproduces.
- E3 is likely to show in the running 8-h soak's memory numbers on a T0–T2 profile.
- The "P" rows were not re-read by the triager. Their severities assume the reviewer's description is accurate.
