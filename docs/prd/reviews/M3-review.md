# M3 (Voice pack) — independent close code review (D-025)

- Branch / commit: `m3/voice` @ `5c08f236b` (worktree `.claude/worktrees/m3-voice`), read-only. Nothing was built or run.
- Scope: the helper voice stack (`Engines/Voice`, `Engines/STT`, `Engines/TTS`, vendored `FullDuplexAudioIO` / `PlaybackClock` patches, `EngineHost/VoiceRouting`), the app side (`Harness/Voice/*`, `UI/Voice/*`, `DictationBar`, MicButton, Settings › Voice, `ReadAloudController`), `RecordingStore` + the `v21_voice_recording` migration, `PermissionCenter`.
- Method: I traced each path end to end (app → `EngineClient` → XPC → `SessionRouter` → `VoiceService` → service → session actor → audio graph, and back). I kept only findings I could tie to concrete code and a concrete failure scenario.

**Totals: P0 = 2, P1 = 6, P2 = 8.**

**Resolution (2026-11-09, branch `fix/m3-review` on main `785c5ea29`):** all 16 findings re-verified in the code and confirmed (P2-4 was already partly fixed by M9.T01 on main); all 16 fixed, each with a test. Helper-side tests: `Packages/Engines/Tests/AntiChatEnginesTests/VoiceReviewFixTests.swift`, `Packages/EngineHost/Tests/AntiChatEngineHostTests/VoiceOrderTests.swift`; app side: `Packages/Harness/Tests/AntiChatHarnessTests/VoiceReviewAppTests.swift`, `Packages/Foundation/Tests/AntiChatFoundationTests/VoiceTempTests.swift`; real pipeline: `AntiChat -Bench voice-approval`. One vendored patch added: UP-SS-009 (`FullDuplexAudioIO` output volume + end-of-input prebuffer flush).

**No regression (session pipeline changed), 2026-11-09 on the fix head:** AT-282 `BargeInFixtureTests` (gpu-run timing, load 3 → 29 by the end): **36/36**, V3 onset → TTS silent p50 32.7 ms (p95 106.7), onset → cancel p50 260.9 ms (bar ≤ 300) — `build/at/AT-282/{spans,v3}.json`. V1 (`tools/perf/run.py --metric V1 --tier T1 --runs 20`, gpu-run timing, started at load 18.4; run.py flags it `noisy` under its stricter quietness rule): **p50 1.037 s, p95 2.021 s** (bars ≤ 1.5 / ≤ 2.5) — `build/perf/runs/20261109T134629Z-V1-T1.json`. AT-280: AC2 (half duplex) is in-process (`HalfDuplexPolicyTests`, in the unit gate, pass); AC1 is an owner step and AC3 plays music on the speakers — neither touches changed code (ducking unchanged), not re-run. Gates on the fix head: `make test-unit` pass, `make test-integration-stub` pass (79 tests, 28 skipped, 0 failures), `make audit` EXIT=0.

Checked and clean: no content filters in the voice paths (D-005). The WhisperKit `WhisperDecodePolicy` token suppression is decoding hygiene, not a filter. No transcript or audio text goes into `AppLog` or signposts. Models load offline (`download: false`, `ModelHub.offlineMode`). Incognito dictation names no recording file and `RecordingStore` refuses in-memory DBs. The v21 `file_blob` rebuild follows the standard SQLite table-rebuild procedure and its FK references still resolve.

---

## P0

### P0-1 Pressing End while a conversation is still connecting leaves a session running in the helper with the mic live and no UI
- **Where:** `Harness/.../Voice/VoiceSessionController.swift:98-106` (pump), `:110-114` (`end`); `Engines/.../Voice/VoiceSessionService.swift:113-133` (`start`), `:140-142` (`end`); `Engines/.../Voice/VoiceService.swift:122-128` (`addresses`); `Harness/.../Engine/EngineClient.swift:424-434` (no cancel on stream exit).
- **What happens:**
  1. `start()` sends `.models(set)`, waits for it to finish, then sends `.sessionStart`. `end()` only sends `.sessionEnd` and calls `finished()`. Nothing cancels the request and nothing stops the pump.
  2. **End during `.models`:** the helper answers `sessionEnd` with `voice.unsupported`, because the stream is not open yet. The router drops that error because no request is registered under the id. The pump then still sends `.sessionStart(start)`. The first batch fails the `requestID` guard and the loop returns.
  3. **End while `standardParts` is leasing models** (Parakeet, Kokoro and smart-turn; seconds when cold): `VoiceSessionService.end` finds no entry in `sessions`, because the session is only inserted after `parts` returns, so it returns without doing anything. Then `begin()` starts capture.
  4. In both cases the helper session runs with no consumer. The microphone is open (macOS mic indicator on). VPIO ducks other apps' audio. The Voice models stay leased. The helper keeps emitting about 31 `audioLevel` events per second into an `EngineClient` continuation that nobody reads. The buffer is unbounded, so app memory grows. Nothing ends the session until the XPC connection drops.
  - `VoiceCalls.current` is nil, so the menu bar call indicator is gone too.
- **Scenario:** Click Voice, then × End within the first 1–5 s (a misclick, or the user changes their mind). The mic stays hot in the background indefinitely.
- **Fix:**
  - App: in `end()`, call `engine.cancel(requestID)` (the router cancels the request task, and `withTaskCancellationHandler` ends the session). In the pump, do not send `.sessionStart` if `requestID != start.requestID` after the models step.
  - Helper: `VoiceSessionService` should remember an `end` for an id that has no session yet. Check it after `parts` and before `begin()`, and also check `Task.isCancelled` there.
- **Resolution:** Confirmed. Fixed on both sides. App: `VoiceSessionController.end()` now cancels the request (`engine.cancel`), stops the pump and sends `sessionEnd` only once the session stream is open; the pump never sends `sessionStart` after an End during the models step. `EngineClient.voiceStream` cancels its helper request when the consumer stops listening, so nothing keeps buffering into an unread stream. Helper: `VoiceSessionService` has a session entry from the moment the start is routed (`prepare`, synchronous in `SessionRouter.routeVoice`); an End or a request cancel that arrives while `standardParts` leases is remembered, the leases go back and capture never starts. Tests: `VoiceSessionServiceReviewTests.endWhileConnectingNeverStartsCapture` / `cancelWhileConnectingNeverStartsCapture` / `endBeforeStartIsKept`, `VoiceSessionControllerTests.endWhileConnectingNeverOpensTheSession` / `endOnAnOpenSessionEndsAndCancels`.

### P0-2 A recogniser failure mid-session sends a terminal error. The app tears down its side, but the helper session keeps capturing forever and cannot be ended
- **Where:** `Engines/.../Voice/VoiceSession.swift:398-414`, `:441-447` (`openFailed` emits `.engine(.error)`); `EngineHost/.../SessionRouter.swift:75-85` (a terminal marks the request terminated and drops every later emit); `Engines/.../Voice/VoiceService.swift:135-141` (the terminal removes the id from `open`); `Harness/.../Voice/VoiceSessionController.swift:180-182, 190-201, 217-221`.
- **What happens:**
  1. `.engine(.error)` is terminal (`EngineEvent.isTerminal`). `VoiceService.tracking` removes the stream from `open`, and the router marks the request terminated.
  2. On the app side the stream finishes. `finished()` sets `requestID = nil` and the phase stays `.error`.
  3. The user presses the error's End (`dismissError`). Since `requestID == nil`, nothing is sent. Even if a `sessionEnd` were sent, `addresses` would answer `unsupported`, because the id is no longer in `open`.
  4. The `VoiceSession` itself was never ended. Capture, VPIO ducking and the session leases stay up. Every later speech onset retries `openRecogniser`, fails again, and its emits are dropped.
  5. On the same path, the leases returned by `make()` are leaked when `t.start(...)` throws. The `catch` at `:411-413` never releases them.
- **Easy trigger:**
  - Set Settings › Voice › Spoken language to a language outside Parakeet's 25 (e.g. Japanese) without `stt-multi` installed. On the first utterance, `RoutedBackend.start` calls `whisper()`, which throws `voice.unavailable` (`STT/LanguageRouter.swift:107-113`, `STTService.swift:134-136`).
  - Any other lease or recogniser error on the first utterance has the same effect.
- **Fix:**
  - Do not send a terminal mid-session. Either emit a non-terminal voice event (e.g. `voiceState`/an error item the app renders), or end the session properly: `await end()`, then send the terminal, then drop the `sessions` entry.
  - Release `leases` in the `catch` of `openRecogniser`.
  - Fail fast at `sessionStart` when the configured language needs `stt-multi` and it is not installed.
- **Resolution:** Confirmed (including the lease leak). A running session never sends a terminal itself any more: `VoiceSession.openFailed` (and a lost capture graph, P2-3) calls `fatal`, the service ends the session (capture off, VPIO gone, every lease released, `voiceState(.idle)`), and only then is the error the stream's one terminal; the app's error End then has nothing left to stop. The recogniser task releases its leases (and cancels the backend) when `start` throws. `standardParts` fails fast with `voice.unavailable` when the spoken language routes to WhisperKit and `stt-multi` is not installed (no lease taken). Tests: `recogniserFailureEndsTheSessionProperly`, `otherLanguageWithoutSttMultiFailsFast`.

---

## P1

### P1-1 Mic mute / speaker mute pressed while connecting are silently dropped; the overlay shows "muted" while the mic is live
- **Where:** `UI/.../Voice/VoiceOverlay.swift:47-62` (the mute buttons are shown in `.connecting`); `VoiceSessionController.swift:116-124` (flips local state, then `send`), `:150-153`; `VoiceService.swift:122-128`; `VoiceSessionService.swift:135-138` (`guard let s = sessions…[id] else { return }`).
- **What happens:**
  - During `.models` the control fails `addresses`, and its error is dropped by the router because no request is registered under the id.
  - During `standardParts` the session is not yet in `sessions`, so the control is ignored.
  - `micMuted` is never re-sent once the session starts.
- **Scenario:** The user clicks Voice and immediately mutes the mic while the models load. The overlay says "Mic muted", but the helper session starts unmuted and transcribes and answers what it hears. This is a privacy expectation violation.
- **Fix:** Carry the initial mute state in `VoiceSessionStart`, or have `VoiceSessionService` queue controls for an id whose session is still being built and apply them after `begin()`. Alternatively, disable the mute buttons until the first `voiceState(.listening)`.
- **Resolution:** Confirmed. Controls pressed while connecting are no longer dropped: the app keeps them local until the session stream is open and sends the mute states right behind `sessionStart` (`VoiceSessionController.opened`); the helper queues controls for a session that is still building and applies them, in order, after capture starts and before frames are processed (the machine ignores mutes while idle, so they could not be applied earlier). Tests: `muteWhileConnectingAppliesBeforeAnythingIsHeard` (helper: levels −120, no turn), `muteWhileConnectingIsSentWhenTheSessionOpens` (app).

### P1-2 Stopping a read-aloud while Kokoro is loading is lost; the speech then plays in full and cannot be stopped from the UI
- **Where:** `Harness/.../Voice/ReadAloudController.swift:58-60` (opens `.speak` even after `stop()` cleared `requestID`), `:77-83`; `Engines/.../TTS/TTSService.swift:56-64` (lease first, which takes seconds when cold), `:76` (registered in `speeches` only inside `run`), `:100-102` (`stop` finds nothing).
- **What happens:**
  - A `SpeakStop` that arrives during the lease is a no-op. A stop that arrives during `.models` is dropped, and the speech request is still sent afterwards.
  - `stop()` already reset `speakingID`, so the button shows idle while the audio starts seconds later.
  - Clicking another message's Read aloud calls `stop()` and then starts a second speech, so the two overlap.
- **Fix:**
  - `TTSService`: register a stop flag per `requestID` before the lease. Check it after the lease and before `run`, and make `stop` set it.
  - `ReadAloudController`: do not open `.speak` when `requestID != request.requestID` after the models step.
- **Resolution:** Confirmed. `TTSService` registers each speech as `.starting` from `prepare` (or the start of `speak`) and a `SpeakStop` before it plays marks it; after the Kokoro lease the speech ends with `ttsStopped(.stopped)` + `done` without a sound. `ReadAloudController` does not open `.speak` when it was stopped during the models step and also cancels the request on stop. Tests: `ReadAloudStopReviewTests.stopDuringTheModelLoadIsKept`, `VoiceReviewAppTests.readAloudStoppedBeforeItPlaysIsNeverOpened`.

### P1-3 Speaker mute does not silence the reply that is already playing (and unmute leaves it silent)
- **Where:** `Engines/.../Voice/VoiceOutputSink.swift:83-100, 119` (the `muted` flag is applied when a buffer is scheduled); `Engines/.../TTS/KokoroBackend.swift:127-148` (each chunk is synthesised and scheduled as soon as its text arrives, ahead of playback).
- **What happens:**
  - Kokoro schedules every available chunk immediately, and the LLM usually streams faster than speech. Most of a reply is therefore already queued in the player node when the user presses mute, and it keeps playing at full volume.
  - The reverse also happens: chunks scheduled while muted stay silent after unmute.
- **Scenario:** The assistant starts a long answer and the user presses speaker mute. Nothing changes until the next reply.
- **Fix:** Implement mute on the output itself (`playerNode.volume = 0` / the mixer volume inside `FullDuplexAudioIO`), so that it applies now and keeps the clock running, as the protocol comment promises.
- **Resolution:** Confirmed. Speaker mute is now the player node's volume (`FullDuplexAudioIO.setPlaybackVolume`, new patch UP-SS-009, kept across graph rebuilds by `VoiceAudioEngine`): it applies to audio already queued, unmute restores it, and the buffers keep playing silently so the clock and spoken span still advance. Buffers are no longer zeroed at scheduling. Test: `DuplexOutputReviewTests.speakerMuteAppliesToQueuedAudio`.

### P1-4 Any playback stall or route change mid-reply makes the reply never "finish"; the session sticks in `.speaking` (half duplex: the mic stays gated)
- **Where:**
  - `Vendor/agent-squad@729d5f5/.../PlaybackClock.swift:33-38` (`willSchedule` resets `playedMs = 0` when the queue went idle), `:42-49`.
  - `VoiceOutputSink.swift:102-105` (`playedSamples = min(scheduled, playedMs…)`, while `scheduled` keeps counting since the last flush).
  - `KokoroBackend.swift:150-156` (drain loop: `while playedSamples < scheduledSamples`, no timeout).
  - Vendored `FullDuplexAudioIO.swift:535-559` (after a drain the prebuffer target becomes `recoveryPrebufferFrames` = 8 × 100 ms), `:487`.
  - `VoiceAudioEngine.swift:138-148, 160-177` (route rebuild); `VoiceSession.swift:215-217` (`micGated`).
- **What happens:**
  - **Stall mid-reply:** the next chunk is not ready before the previous one finished playing. This always happens around a tool call (M3.T13), and also happens with slow decode on a loaded GPU. Three things then go wrong:
    1. `PlaybackClock` restarts the burst, so `playedMs` restarts from 0 while `DuplexOutputSink.scheduled` keeps the earlier chunks. `playedSamples` can never reach `scheduledSamples`, so Kokoro's drain loop never exits and `.finished` never comes.
    2. Later `.started(i)` announcements (captions) compare against the restarted clock, so they come late or never.
    3. After a drain, `FullDuplexAudioIO` waits for 8 slices (800 ms) before it plays again. A last chunk shorter than that (e.g. "Done.") is never played at all.
  - **Route change mid-reply:** plugging in headphones (exactly what the `voice.headphones` hint suggests) triggers `rebuildLive`, which stops the old IO. The queued buffers' `onPlayed` never fires (generation bumped), and buffers scheduled during the rebuild are dropped while still counted. The result is the same infinite drain.
  - **Consequence:** the machine never gets `replyDone`. In half duplex the mic is zeroed while `.speaking`, so the conversation is dead until End or a typed message. In full duplex only a barge-in unsticks it.
  - The unit and AT runs use `ClockedSilentSink`, which has a continuous playhead, so they cannot see this.
- **Scenario:** "Let me look that up." → web search (3 s, underrun) → "It's 21 °C." The second sentence plays, but the session never returns to listening.
- **Fix:**
  - Give the sink one monotonic played counter per reply: accumulate across bursts instead of restarting, or track `scheduled` per burst.
  - In `KokoroBackend` drain, also exit when the sink is idle with nothing pending.
  - Use the small initial prebuffer at the reply's tail, or flush the prebuffer when no more input is coming (`speakEnd`).
  - On `rebuildLive`, re-base the sink: flush the clock, set `scheduled` to what was played, and re-schedule or drop the remainder explicitly.
- **Resolution:** Confirmed (all three effects). `DuplexOutputSink` keeps one monotonic played count per reply: when its queue ran dry the PlaybackClock burst's played time moves into a per-reply base before the clock restarts, under the sink lock that the played callbacks also take. A graph rebuild reports `onPlaybackReset`: the sink re-bases (what played stays, the lost remainder is dropped from `scheduled`), and audio handed over while no graph runs is not counted. Kokoro's drain waits on `hasPendingAudio` (buffers still owed a callback) instead of `played < scheduled`, and at the end of the chunk stream calls `endOfInput` → `FullDuplexAudioIO.playPrebuffered()` (UP-SS-009), so a tail shorter than the 800 ms recovery prebuffer plays. Tests with `ModelPlaybackDevice` (a model of the patched FullDuplexAudioIO queue: real-time buffers, 3/8-buffer prebuffer, drain on a dry queue, route change drops the queue without callbacks): `stallMidReplyStillFinishes`, `routeChangeMidReplyStillFinishes`, `audioDroppedDuringARebuildIsNotOwed`, `sessionReturnsToListeningAfterAStalledReply` (half duplex: back to listening).

### P1-5 Spoken tool approvals (M3.T13 step 4) cannot work through the real pipeline: the answer is treated as a barge-in (full duplex) or never heard (half duplex)
- **Where:** `Harness/.../Voice/VoiceTurnBridge.swift:120-141` (the prompt is spoken as part of the still-open reply), `:74-83` (`ttsStopped(.bargeIn)` cancels the reply); `VoiceSession.swift:301-327` (barge-in runs whenever the state is `.speaking`/`.thinking`, whether or not audio is playing), `:215-217`; `BargeInDetector.swift:56-80`; `VoiceSessionMachine.swift:125-131`.
- **What happens:**
  - After "Write note. Allow?" has played, the turn is still running (no `speakEnd`), so the helper stays in `.speaking`.
  - **Full duplex:** the user says "Allow once". That is ≥ 250 ms voiced, so it becomes a barge-in: `stopSpeech(.bargeIn)` + `cancelGeneration`. The bridge calls `port.stopReply`, which stops the turn that was waiting for approval, and the approval card goes away (`approvalChanged(nil)` clears `pendingApproval`). The final transcript arrives about 1 s later and is sent as a new user message "Allow once."
  - **Half duplex:** the mic is gated for the whole `.speaking` state, so the answer is zeroed and the card must be clicked.
  - `VoiceToolsTests.anApprovalIsSpokenAndAnsweredByVoice` feeds `finalTranscript` straight into the bridge, so it bypasses this.
- **Fix:** While an approval is pending, end the spoken part (`speakEnd` for the prompt segment, or a new `awaitingAnswer` control) so that the helper returns to `.listening`, then resume speaking with the post-approval text. Alternatively, have the bridge treat a barge-in while `pendingApproval != nil` as an answer attempt and not cancel the turn.
- **Resolution:** Confirmed. `VoiceTurnBridge.approvalChanged` now ends the spoken segment after the prompt (`speakEnd`): the helper plays "… Allow?", returns to listening (half duplex: the mic opens after the 300 ms tail) and hears the answer as a normal turn. The text after the approval is a new spoken segment of the same reply (its own helper turn id; its spoken offsets continue from what the first segment stored). Speech over the prompt (a barge-in on it) is treated as the answer starting, not as an interruption of the reply that waits for it. Tested through the helper pipeline: `SpokenApprovalSessionTests.fullDuplex` / `.halfDuplex` drive a real `VoiceSession` with the bridge's exact control sequence (answer → final transcript, no barge-in, the reply continues); the real models end to end with the app's own `VoiceSessionController` + `VoiceTurnBridge` over XPC: `AntiChat -Bench voice-approval --duplex full|half` (2026-11-09, gpu-run shared, load 4: answer at 16 s, after the prompt → **pass in both**: answered `allowOnce` by voice, 0 barge-ins, 0 reply stops, 1 user message, listening again; answer at 9 s, over the prompt: full duplex **pass** through the barge-over-prompt path (1 barge-in counted as the answer, 0 stops); half duplex: the answer was zeroed by the mic gate while the prompt played — by design of half duplex (no voice barge-in), the user answers after the question; evidence `build/at/M3-review/voice-approval-*.jsonl`); bridge units in `VoiceToolsTests` / `VoiceReviewAppTests.answerOverThePromptIsNotAnInterruption`.

### P1-6 A dictation keeps recording in the helper when its controller goes away (e.g. window closed mid-dictation); its buffer grows without bound
- **Where:** `Harness/.../Voice/DictationController.swift:120-128` (`guard let self else { return }` just leaves the loop; no stop and no cancel); `Engines/.../STT/STTService.swift:153-176` (the run ends only on stop or cancel; no maximum length); `:293-296` (`l.samples += samples` for the whole dictation). No window-close hook stops dictation (`UI/.../Window/*`).
- **What happens:** Closing the window (or tearing down the composer) during a dictation leaves `MicCapture` running in the helper. The `ParakeetBackend` and VAD keep running, and memory grows by about 3.8 MB/min, plus `ParakeetBackend.State.samples` grows the same way. This lasts until the helper restarts. The mic indicator stays on with no UI to stop it.
- **Fix:** Cancel the request (`engine.cancel(id)`) from a teardown hook (window `willClose` / the controller's deinit path / pump cancellation via `onTermination`). Add a helper-side maximum dictation length (e.g. 10–15 min) as a backstop.
- **Resolution:** Confirmed. A dictation whose window closes is cancelled in the helper (`ChatSessions.windowClosed` → `DictationController.teardown`, wired to the main window's `onDisappear`); a controller released mid-dictation cancels its request at the next batch, and a cancelled consumer cancels the request (`voiceStream` termination). Helper backstop: `STTService.maxDictation` (15 min) stops a dictation nobody stops, as ■ (the transcript so far is the final), which also bounds the sample buffers. Tests: `teardownCancelsTheDictation`, `releasedControllerCancelsTheDictation`, `dictationStopsAtTheMaximumLength`.

---

## P2

### P2-1 Session controls can be reordered: each non-opening voice message runs in its own unstructured Task
- **Where:** `EngineHost/.../VoiceRouting.swift:17-25` (`Task { await core.runVoiceService(message…) }` per message); `VoiceTurnBridge.swift:115` (one `speak` per token delta); `VoiceSession.swift:536-558`.
- **What happens:** XPC delivers messages in order, but separate `Task`s on the global executor hop onto the `VoiceService` actor in no guaranteed order. On a loaded host:
  - `speakEnd` can overtake the last `speak`, so the delta is fed after `feed.finish()` and is never spoken.
  - Two deltas can swap, so the speech is garbled and the stored-text offsets used for truncation are wrong.
  - `pttUp` can overtake `pttDown`, so the session stays in push-to-talk listening until the next press.
- **Fix:** Use one serial `AsyncStream` per `requestID` (or a per-session FIFO) for controls, in the same way as `policyBarrier`.
- **Resolution:** Confirmed. `SessionRouter.routeVoice` registers every stream-opening voice message synchronously in arrival order (`VoiceService.prepare`, which also tells the service: session / speech / dictation), and the messages acting on one stream run through a FIFO per request id (`VoiceOrder`) instead of one unstructured Task each, so speak deltas, `speakEnd`, `pttDown`/`pttUp` keep their order and a stop or End can never overtake its start. Tests: `VoiceOrderTests`, `endBeforeStartIsKept`, `DictationReviewTests.cancelBeforeStartIsKept`, `stopDuringTheModelLoadIsKept`.

### P2-2 A dictation whose capture fails to start leaks the started recogniser (polling tasks forever, model retained)
- **Where:** `STTService.swift:160-166` (on `begin` throwing, only `fail` runs), `:264-290` (`backend.start` and the `partials` task run before `capture.start` can throw); `ParakeetBackend.swift:169-174, 261-304`.
- **What happens:** `runWindow` (100 ms loop) and `runEOU` (20 ms loop) run until cancelled. Nothing calls `backend.cancel()`, so they spin forever. They retain the `ParakeetModel` actor even after the scheduler evicts the lease, and they leave the shared EOU model's callbacks pointing at the dead backend.
- **Trigger:** `MicCapture.start` throws, e.g. the input format is 0 Hz after a device vanished, or the engine fails to start.
- **Fix:** In `DictationRun.begin`, wrap the post-`backend.start` steps and call `await backend.cancel(); partials?.cancel()` on failure. Also remove the tap if `engine.start()` throws (`DictationCapture.swift:37-42`).
- **Resolution:** Confirmed. `DictationRun.begin` closes the recogniser (cancels the partials task and the backend) when the capture fails to start after `backend.start`; `MicCapture.start` removes its tap when `engine.start()` throws. Test: `captureStartFailureClosesTheRecogniser`.

### P2-3 A failed graph rebuild after a device change silently deafens the conversation
- **Where:** `VoiceAudioEngine.swift:174-176` (`catch { state.running = false }`, with no event).
- **What happens:** After a route or device change, if VPIO and non-VPIO both fail to start, capture stops and nothing is reported. The overlay keeps saying "Listening", the level meter freezes, and nothing is ever heard again.
- **Fix:** Surface it through a callback to the session, which emits `voice.noDevice` (non-terminal) or ends the session with that error. Retry once after a short delay.
- **Resolution:** Confirmed. A failed rebuild after a device change is retried once after 300 ms; a second failure reports `VoiceAudioEngine.onGraphFailed`, which the session receives (`VoiceSessionParts.watchDevice`) and turns into a proper end with `voice.noDevice` (the overlay shows the error state with End). Test: `lostCaptureGraphEndsWithNoDevice` (the device itself cannot be failed in a unit test; the retry path is code-reviewed).

### P2-4 Voice UI accessibility: test hooks are exposed to VoiceOver and state changes are not announced
- **Where:** `VoiceOverlay.swift:128-131` (the orb's label is always "Listening" and its value is `"\(phase)"`, e.g. `userSpeaking`, `error("voice.noDevice")`); `DictationBar.swift:36-38` (the waveform's `accessibilityValue` is the level-update count, which changes 30×/s); `ComposerView.swift:302` (the MicButton value is the raw enum `needsPermission`/`ready`); `HeadphonesHint.swift:24-27` (a mode change that disables voice barge-in, auto-hidden after 10 s, with no announcement).
- **What happens:** VoiceOver reads debug strings and a constantly changing number. A blind user is never told that the session switched to half duplex, or that it moved between listening, thinking and speaking.
- **Fix:**
  - Use localized labels and values (e.g. `voice.state.*`).
  - Move test values to `accessibilityIdentifier`-only hooks or a DEBUG-only probe.
  - Post `AccessibilityNotification.Announcement` for the half-duplex switch and for errors.
  - Do not auto-dismiss the hint while VoiceOver is running.
- **Resolution:** Partly fixed on main before this round (M9.T01 `8f95f6749`: the orb's label is localised and its debug value is gone). Fixed here: the dictation waveform's value is "Recording" (`a11y.dictation.recording`) and the mic button's value is the localised mic state (`a11y.mic.needsPermission`, `voice.denied`, `voice.noDevice`, the pack reason); the raw values the UI tests read are the values only in automated runs (`LaunchOptions.isAutomationRun`, never in Release). VoiceOver announces the call becoming ready (`voice.listening`), the half-duplex switch (`voice.headphones`) and errors; the headphones hint is not auto-dismissed while VoiceOver runs. Listening / thinking / speaking transitions are not announced on purpose: the spoken reply itself is the speaking signal and announcing over it would talk over the assistant; the orb's label carries the state. Copy in the deck §M9 a11y row with de/es/fr/nl/pt translations.

### P2-5 `VoiceSection.sessionActive` is a single static closure that each window overwrites
- **Where:** `UI/.../Window/ChatSessions.swift:171` (assignment), `:211-212` (chained only with the same window's voice); `Settings/Sections/VoiceSection.swift:65-67` (the meter starts only on appear).
- **What happens:** With two windows, only the last-bound window's dictation or call counts. Settings › Voice then opens its own input tap on the mic while another window dictates or is on a call, instead of showing "In use". A dictation or call started while Settings is visible also never stops the meter.
- **Fix:** Use an app-wide registry (e.g. `VoiceCalls.shared` plus a dictation counter), and observe it in the section so the meter stops and starts when it changes.
- **Resolution:** Confirmed. The static closure is gone: `VoiceCalls.shared` tracks every active dictation (by controller) next to the call, and Settings › Voice reads `micInUse` (app-wide) through its host and stops / restarts the meter when it changes while the section is visible.

### P2-6 Temporary voice audio is never swept
- **Where:** `DictationController.swift:70, 110-115` (`$TMPDIR/AntiChat-dictation/<id>.m4a`); `STTService.swift:210` / `FileTranscriber.swift:81-83` (`$TMPDIR/AntiChat-transcribe/*.wav`, full-length 16 kHz float, ~690 MB for 3 h).
- **What happens:** Both are deleted on the normal paths. After an app or helper crash, or a kill mid-stop, the user's voice recordings and decoded audio stay in the temp directory with no startup cleanup. For an incognito audio attachment, the decoded WAV is also briefly on disk, which goes against M3 contract 3 ("no audio files on disk"), at least on a crash.
- **Fix:** Sweep both directories at app and helper launch. For incognito files, consider decoding to memory-mapped anonymous memory instead of a scratch file.
- **Resolution:** Confirmed. Dictation recordings and decoded transcription audio now live in per-process directories `$TMPDIR/AntiChat-{dictation,transcribe}/<pid>/` with an `.owner` pid (`VoiceTemp`, the same scheme as `IncognitoTemp`); the app (dictation) and the helper (transcription) sweep at launch what dead processes left (loose files of the old flat layout after 1 h), never a live process's files. The incognito decoded WAV stays a scratch file, now in the owned, swept directory: the incognito intake copy it is decoded from already lives on disk under `AntiChat-incognito-*` by design (M6), and decoding a 3 h file to memory (~690 MB in the helper) was rejected; after a crash both are removed at the next launch. Test: `VoiceTempTests`.

### P2-7 Push-to-talk gets stuck if Space is released after the window lost key
- **Where:** `VoiceOverlay.swift:163-173` (the local monitor requires `window.isKeyWindow` for keyUp too); `VoiceSessionController.swift:138-148`.
- **What happens:** If the user holds Space, ⌘-Tabs away and releases, `pttUp` is never sent. The helper keeps recognising (and buffering) until the next press and release.
- **Fix:** Send `pttUp` on `NSWindow.didResignKey` / `NSApplication.didResignActive` while `pttIsDown`, and accept keyUp regardless of key-window state.
- **Resolution:** Confirmed. `PushToTalkMonitor` accepts Space's key-up wherever it lands once Space is down, and releases push-to-talk (`VoiceSessionController.releasePushToTalk` → `pttUp`) when any window resigns key or the app resigns active while Space is held. Test: `pushToTalkIsReleasedWhenTheWindowLosesKey`.

### P2-8 Dictation in one window and a voice call in another can run at once, sharing the streaming EOU model
- **Where:** `ComposerModel.swift:408-420` (`startDictation` checks only this composer; `startVoice` checks only this composer's dictation); `ChatSessions.swift:215` (`VoiceCalls` only gates calls); `ParakeetBackend.swift:98-105` (`ParakeetEOUModel.begin` resets the shared resident model and replaces its callbacks).
- **What happens:**
  - Two captures run at once: `MicCapture` and the VPIO graph.
  - The second `begin` steals the EOU callbacks, so one stream's partials and EOU signals reach the other. The voice session's captions or end-of-turn can be driven by the dictation's audio, and the reverse.
- **Fix:** Make dictation and a call mutually exclusive app-wide (check `VoiceCalls.shared.isActive` in `startDictation`, and any active dictation in `startVoice`). Alternatively, give each recogniser its own EOU state.
- **Resolution:** Confirmed. Dictation and a call are mutually exclusive app-wide: `DictationController.start` refuses while a call is active (`VoiceCalls`), and `ChatSessions.startVoice` refuses while any window dictates. Test: `dictationDoesNotStartDuringACall`.

---

## One-line list
1. P0-1 End while connecting → orphaned helper session (mic live, ducking, leases, unbounded app buffer).
2. P0-2 Mid-session recogniser failure sends a terminal error → helper session can never be ended (mic stays live); leases leak.
3. P1-1 Mute pressed during connecting is dropped; UI shows muted while the mic is live.
4. P1-2 Read-aloud stop during Kokoro load / models step is lost; speech plays later and cannot be stopped; overlaps the next one.
5. P1-3 Speaker mute applies only to future buffers; the current reply keeps playing (and stays silent after unmute).
6. P1-4 Playback stall (tool call) or route change mid-reply → clock/prebuffer never drain → reply never finishes, session stuck in speaking.
7. P1-5 Spoken approvals: the answer is a barge-in that cancels the turn (full duplex) or is gated out (half duplex).
8. P1-6 Dictation not stopped when its controller/window goes away; helper records indefinitely with an unbounded buffer.
9. P2-1 Voice control messages can be reordered (one Task per message).
10. P2-2 Capture start failure leaks the started recogniser (spinning tasks, retained model).
11. P2-3 Failed graph rebuild after a device change silently stops capture.
12. P2-4 VoiceOver reads debug values; no announcements for the half-duplex switch or state changes.
13. P2-5 `VoiceSection.sessionActive` overwritten per window; meter does not yield the mic correctly.
14. P2-6 No sweep of temp dictation/transcription audio; incognito decoded WAV touches disk.
15. P2-7 Push-to-talk stuck when Space is released after the window loses key.
16. P2-8 Dictation and a call can run concurrently across windows and share the EOU model (cross-talk).
