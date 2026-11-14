# R2: independent review of AntiChat main, ce2fbdd65..0fe4cfd20 (product code)

Reviewer: independent (D-025 style). This was a read-only pass over the main checkout at 0fe4cfd20. Nothing was built and no tests were run.
Scope: the first-parent merge rounds ce2fbdd65..0fe4cfd20. Product sources only: tests, evidence and tools/ were read only where they showed whether a product path is reachable.

Counts: **P0 0 · P1 2 · P2 2**. All four were re-verified and fixed on `fix/r2-review`; the resolutions are below each finding.

---

## P1-1: The streamed video check loads the ChildSafetyCheck detectors during decode on T0–T2. That breaks the low-tier memory rule.

Files:
- `Packages/Engines/Sources/AntiChatEngines/Video/VideoEngine.swift:115-122, 207-216`. `StreamedFrames` is created for every job. At the first `decode` progress event it calls `outputs.beginVideoCheck`.
- `Packages/Engines/Sources/AntiChatEngines/Jobs/MediaJobRunner.swift:373-381`. `beginVideoCheck` starts `gate.checkVideo` in a Task right away, with no tier test.
- `Packages/Engines/Sources/AntiChatEngines/Media/MediaOutputGate.swift:86`. `checkVideo` runs `loadChecker()` first, so the detectors load before any frame is in.
- `Packages/Engines/Sources/AntiChatEngines/Scheduler/EngineRuntime.swift:662-668`. This code states the rule: "T0–T2 keep them released until the final check (decision (a), NFR-R1)". Only T3+ adds `detectorBytes` (4.3 GB) to the step-aside.
- MediaJobRunner header lines 13-16: on T0–T2 the detectors are "never resident beside the generator".

Failure scenario: a T2 Mac (video presets exist for T2-S1..S4, vid-5b) runs a text-to-video job. Step-aside freed room for `req.footprintBytes` only. When the runtime reports `decode` (VAE decode, the job's memory peak), `beginVideoCheck` starts the check and about 4.3 GB of detectors load inside the helper while the runtime still holds its decode memory. That is up to 4.3 GB over budget B on a 16 GB machine. The likely result is heavy swap or a jetsam kill of the helper or runtime (the job is lost). At best, detector timeouts under contention cause false blocks. The one-shot path, which this PR keeps only as a fallback, checks after `client.release(jobID)` has freed the runtime's job memory.

D-006 itself still holds: every sampled frame is checked, the verdict applies only when the clip is complete, the check fails closed, and `check*` is still called only from MediaJobRunner.swift. This is a resource and spec defect, not a safety bypass.

Suggested fix: stream only when the detectors were preloaded. For example, `beginVideoCheck` returns nil when `preloadTask == nil` (T0–T2), or VideoEngine gets a `streamCheck: !lowTier` flag. Low tiers then take the one-shot `videoResult` path after the runtime released the job. Add a test that a lowTier video job never calls `checkVideo` before `frames_ready`/release.

**Resolution (fix/r2-review): confirmed and fixed.** I re-checked it on 0fe4cfd20. `StreamedFrames.decoded` opened the check at the first `decode` event on every tier, and `beginVideoCheck` had no tier test. On T0–T2 `EngineRuntime.runVideoLocked` never calls `preloadDetectors`, so the runner's `preloadTask` is nil. `MediaJobRunner.beginVideoCheck` now returns nil unless the job preloaded the detectors (`preloadTask != nil`, which means T3+, where the step-aside counted `detectorBytes`). A low-tier job therefore pulls no frames during the decode. It takes the one-shot path: all frames, then `client.release(jobID)`, then `videoResult`. Only that last step calls `checkVideo` and loads the detectors, so NFR-R1 / decision (a) holds again. D-006 is unchanged: there is still one check per clip, it fails closed, and the call site is still MediaJobRunner.swift.
Tests:
- `VideoCheckStreamTests.streamOnlyWhenTheDetectorsWerePreloaded`: no preload gives no stream. A preload at the job's start, or a late preload (EngineRuntime on T3+), gives a stream.
- `VideoRuntimeProcessTests.lowTierJobChecksTheClipOnlyAfterTheRuntimeReleasedIt` (real runtime tree, scripted generator): the gate's video call count is 0 at every `decode` event and still 0 at the `frames` stage, which comes after `release`. Afterwards it is 1, with no `videoStream` note. I checked that this test fails without the fix.
- T3+ leg: `finalFramesStreamIntoTheCheckDuringTheDecode` now preloads, as EngineRuntime does on T3+, and still streams all 49 frames before `frames_ready`.

## P1-2: The new 120 s stall watchdog fails healthy turns whose prefill sends no events (llama-server Evil models, and the MLX prefix-cache prefill)

Files:
- `Packages/Harness/Sources/AntiChatHarness/Turn/TurnController.swift:123` (`defaultStallLimit = 120 s`), `1033-1039` (timer), `1527-1541` (`stallCheck`). The check counts `.prefill` as streaming. Phase becomes `.prefill` on `loadReady` (TurnState.swift: `(.loading, .loadReady) → .prefill`), so it is set before any prefill progress arrives.
- The code comment says "MLX prefill sends progress, so a long prefill is not silence". That is not true on two paths:
  - `Packages/Engines/Sources/AntiChatEngines/LLM/LlamaServerAdapter.swift:207-260`. `stream: true` sends no `return_progress` or other heartbeat. llama-server sends nothing until the first token, and the adapter emits no `prefillProgress` at all. The shipped Evil models evil-2b/4b/9b/122b are `engine: llama.cpp` (catalog/models.yaml:83-123), with context_default 16K–64K.
  - `Packages/Engines/Sources/AntiChatEngines/LLM/MLXAdapter.swift:386`. `prefixCache.prepare(...)` prefills the stable and session prefix (`MLXPrefixCache.prefill`, :272, which has no progress callback) before the AsyncStream exists. `params.prefill.progress` (:337) covers only the suffix that `generate` sees.

Failure scenario: an Evil chat on T1/T2 (evil-9b Q4 through llama-server) with a long attached document or a long history, about 16–32K tokens. Prompt eval at roughly 150–250 tok/s means 65–200 s of silence after `loadReady`. At 120 s the watchdog cancels the request and the reply ends as `engine.stalled` with Retry. Retry hits the same wall. The T4 evil-122b at its 64K default is similar. On MLX, a follow-up turn after the chat model was reloaded (step-aside for an image or video job, eviction) prefills the whole history inside `prepare` with nothing sent, and gets the same false stall on slow Macs.

Suggested fix: count only real silence. Either (a) the adapters emit a heartbeat `prefillProgress` while waiting for the first byte (llama: `return_progress: true` / `timings_per_token` if the pinned server supports it, else a timer). Or (b) `prepare` reports progress through the same `progressCont`. Or (c) exempt `.prefill` from the watchdog, or scale the limit by prompt tokens. Add a scripted-engine test with a 150 s silent prefill that must not stall.

**Resolution (fix/r2-review): confirmed and fixed in both adapters. The watchdog itself is unchanged and still strict.**

Re-check:
- llama-server got no `return_progress`, so it sent nothing between the headers and the first token.
- On MLX the problem was larger than reported. `MLXLMCommon.generate` builds its `TokenIterator`, which prefills inside `init`. That ran inside `container.perform` before `MLXAdapter.generate` returned its stream. So the prompt's own prefill progress was also buffered (`bufferingNewest(64)`) and delivered all at once after the prefill, and the prefix-cache prefill reported none at all.

Fixes:
1. `LlamaServerAdapter` sends `"return_progress": true`. The pinned llama.cpp (620d222, `server-context.cpp`) then streams a `prompt_progress` chunk when the slot starts and after every batch (n_batch 2048), with `{"delta":{"role":"assistant","content":null}}` and no timings. `prefillFraction` maps each chunk to `prefillProgress((processed − cache)/(total − cache))`, before the first token only.
2. `MLXAdapter.generate` now returns its stream before the prefill. `container.perform`, which holds the prefix-cache prepare and the prompt's own prefill, runs inside the stream's task. Progress is therefore forwarded while the prefill runs. A failure there becomes the stream's terminal `.error` (the adapter contract: `generate` throws only before streaming).
3. `MLXPrefixCache.prepare` takes a progress callback. Each prefix prefill passes a `PrefillParameters` whose progress reports `(k − reused + done)/(n − reused)`. `PrefillScale` continues the suffix's progress on the same whole-prompt scale.

The 120 s watchdog keeps its rule: any event restarts the clock, and silence counts in `.prefill` / `.streaming` / `.toolCall`. A real stall, meaning no progress and no token for 120 s, is still cancelled. A healthy prefill now sends an event every batch: about 8–14 s per 2048 tokens at 150–250 tok/s, far inside 120 s. That is why I did not add a prompt-size-scaled bound: it would only widen the window for real stalls. The comment now says what each engine does.

Tests:
- `TurnStallTests.aLongPrefillThatReportsProgressIsNotAStall`: after a load, 2.4 s of prefill (6 × the 400 ms limit) in 120 ms steps, then the answer is `done`.
- `TurnStallTests.silenceInTheMiddleOfAPrefillIsStillAStall`: progress, then silence, ends as `engine.stalled` in well under 15 s. The existing `silentPrefillFailsAsStalled` and `silentStreamEndsAsStalledWithRetry` still pass.
- `LlamaServerSupervisorTests.promptProcessingProgressPrecedesTheFirstToken`: the real pinned llama-server with tiny-gguf. Progress arrives, in order, before the first delta and never after it.
- `LlamaToolChoiceTests.promptProgressChunkBecomesThePrefillFraction`: parser cases.
- `MLXAdapterTests.prefixCachePrefillReportsProgressBeforeTheFirstToken`: tiny-mlx with a long stable system prefix. Partial whole-prompt fractions arrive, in order, before content.

## P2-1: The streamed video check leaks a hung gate task when the audio fetch throws

File: `Packages/Engines/Sources/AntiChatEngines/Video/VideoEngine.swift:144-151` with `:245`.
`streamed.complete(...)` sets `stream = nil` ("handed to finishVideo") and returns the `VideoCheckStream`. The next line is `let audio = req.audio == true ? try await client.audio(jobID) : nil`. If that throws (runtime died, HTTP error), the error propagates. The `defer { streamed.abort() }` at :117 only aborts `StreamedFrames.stream`, which is already nil. `finishVideo` is never called, so the `VideoCheckStream` is neither closed nor aborted. Its `AsyncThrowingStream` continuation is never finished, and dropping it does not finish the stream. The check Task inside `MediaOutputGate.checkVideo` then waits forever. It holds the loaded `ChildSafetyCheck` instance (about 4.3 GB of detectors, kept alive after the gate's 60 s `release()`) and the buffered sampled CGImages.

Failure scenario: an audio-enabled video job (`req.audio == true`) whose runtime fails between `frames_ready` and `/audio`. Each such failure leaks one gate task and pins a detector instance in the helper for the rest of its life. No unchecked output appears: the job fails and nothing is written.

Suggested fix: fetch the audio before `streamed.complete(...)`, or wrap the block in do/catch that calls `stream.abort()` on any error before `finishVideo` takes ownership.

**Resolution (fix/r2-review): confirmed and fixed. The outcome stays fail-closed.**

Fixes:
- `VideoEngine.run` now fetches the sound track before `streamed.complete(...)` hands the stream over. A failed fetch throws while `StreamedFrames` still owns the stream, so its deferred `abort()` ends the open check. The check can then only block, and nobody applies it. The runtime's job is also released on that path. The one-shot path uses the same single fetch.
- Defence in depth: `VideoCheckStream.deinit` now finishes its stream with an error and cancels the check when the stream is dropped without `close`/`abort`. Any future throwing path between hand-off and `finishVideo` can no longer leave the gate task waiting while it holds the detectors.

Tests:
- `VideoRuntimeProcessTests.audioFetchFailureAfterAStreamedClipEndsTheCheckAndWritesNothing`: real runtime. The streamed check is opened and the audio fetch is replaced by a throwing one (DEBUG-only `setAudioFetch`). The result is `jobFailed`, nothing is written, and the test does not hang.
- `VideoCheckStreamTests.aDroppedStreamEndsItsCheckClosed`: a draining check whose stream is dropped mid-clip returns `.block`.

## P2-2: A citation settle task is orphaned when its TurnController goes away. The reply stays "checking" until relaunch and the verifier keeps running ungated.

File: `Packages/Harness/Sources/AntiChatHarness/Turn/TurnController.swift:2033-2051` (`settle`), `2089` (`waitUntilIdle`), `finalizeNow` (`citationsChecking` written true).
The final write stores `provenance.citationsChecking = true`. The settle Task captures `[weak self]` and only `self?.settled(...)` clears the flag and writes the verdict. The gate is `{ [weak self] in await self?.waitUntilIdle() }`. Closing the window drops ChatSessions, its ConversationModels and their TurnControllers (`sessions.windowClosed()`).

Failure scenario: the user asks a web question, the answer appears with checking pills, and the user closes the window (or the controller is otherwise released) while MiniCheck and the generative verifier are still running. Those can take many seconds: one verifier request per sentence batch on the chat model. The task keeps running, `self` is nil, so:
- the DB keeps `citations_checking`, and the text keeps unverified markers;
- reopening the chat in any window shows spinner pills indefinitely, until the next launch's `settleUnfinishedCitations` sweep;
- the remaining verifier requests no longer wait behind that chat's new turns (the gate returns at once when `self` is nil), so they compete with the user's next reply on the same model.

Suggested fix: keep the controller alive for the bounded settle (a strong capture), or move the settle into a chat-independent owner. Otherwise, on teardown, cancel the task and write the sweep result for that message (markers removed, flag cleared).

**Resolution (fix/r2-review): confirmed and fixed with the teardown option.** `TurnController.deinit` cancels every running settle task. That stops the verifier: the request in flight is cancelled through `CiteVerify.generator`'s cancellation handler, and `CitationVerifier.apply` stops between batches. It then writes the launch sweep's result for exactly those replies, using `MessageRepository.settleUnfinishedCitations(only:removeMarkers:)` (new `only` filter): unverified markers are removed, the words stay, and `citations_checking` is cleared.

Why teardown and not keeping the controller alive: a kept-alive settle would still not yield to the turns of a new controller for the same chat (a reopened window). It would also leave that window's pills spinning, because the verdict goes to the old controller's update stream. Teardown removes both problems. The trade-off is the same one a quit has: that reply's pills are dropped rather than verified.

Test: `CitationSettleTests.closingTheChatMidCheckStopsTheChecksAndUncitesTheReplyAtOnce`. The verifier runs, then the controller is released while the UI-style update reader keeps no reference. Then:
- the controller deinits;
- the flag is cleared;
- the stored text is "It is macOS 27.";
- the in-flight verifier request is cancelled, and no further request is sent.

I checked that this test fails without the fix.

---

## Checked, no defect found

- **Test-only paths in Release:** these are all compiled out in Release:
  - every new probe (`FinalAcceptanceProbe`, `VisualQAM6/M7`, `SearchProbe`, `OnboardingProbe`), all `#if DEBUG`;
  - the new LaunchOptions keys `-FinalAcceptanceProbe`, `-OpenURLSpy`, `-SimulateUpdatedFrom`, because `LaunchOptions.parse` is `#if DEBUG` (so `DownloadRequest.rewritten` and SiteLinks/WhatsNew spies are the identity in Release);
  - `PromptDump`, a no-op in Release;
  - `ConversationModel.debugController`, `#if DEBUG`;
  - `ForcedVerdictCheck`, `ANTICHAT_UI_TESTING` only.

  `-Bench` (and its new image-turn/read-aloud/transcribe-file commands) was already Release-reachable at ce2fbdd65. The new commands use temp databases and dev-model paths, and image-turn goes through the real gate.
- **D-005:** `asksForChart` / forced web search only choose a tool. Citation removal strips markers only and never words. No content filter was added.
- **D-006 / VideoCheckStream:** every sampled index must arrive (`evaluateVideo` returns `pending.isEmpty ? .allow : .block`). Errors and cancellation block. The verdict applies only in `finishVideo` after `close()` returns all frames, with reentrancy re-checked. Audio is still never checked. Both `checkVideo` call sites are in MediaJobRunner.swift. Only P1-1 (memory) and P2-1 (leak) remain.
- **UntrustedContextRule:** the read_url exemption compares against `TurnWebSources` URLs the search engine fixed. read_url records its own URL only after it ran, which means after approval when untrusted. Calls to tools that were not offered are rejected by `RepairRetry.problem` against `loop.offered`. The MCP reserved-name and curated-URL changes tighten the model.
- **Incognito:** `LastShownChatStore` never writes incognito chats. The verifier's shared session goes through `IncognitoEngine`, so it is flagged incognito, never slot-saved or snapshotted, and the mark is sticky.
- **FileTools:** the slot lease always wipes on a holder change. A failed wipe clears the holder and the slot is not reused. Per-process instance locks use O_EXLOCK at create. `RLIMIT_NPROC=1` blocks forks. Between runs the interpreter is SIGSTOP-frozen, and a forged reply line ends the session.
- **Voice:** `VoiceSessionService` sends its terminal once, after `end()`. `endings` is set before `end()`, and `untilEnded` resumes only from `end()`. The KokoroTailRewrite MIL (pad/slice/matmul) is correct and falls back to a link when the op does not match.
- **AppDefaults:** `.standard` in Release, and the in-memory store exists only in DEBUG test processes.
- **Other:** the `showMode` same-new-chat guard is sound. `healthTimeout` 90 s is bounded by an early `exit` report.
