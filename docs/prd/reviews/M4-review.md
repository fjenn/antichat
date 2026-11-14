# M4 close review (D-025): Photo pack + ChildSafetyCheck output gate

Branch `m4/photo` at `a9d065455`. Read-only review. I read the code with `git archive` into the scratchpad and did not build or run tests. Scope: the CSC package, `MediaOutputGate`, `MediaJobRunner`, `MediaJobQueue`, `ImageTools` / `ImageEditFlow` / `ImageEditorActions`, `LocalImageJob` / `LaMaEraser`, the `EngineRuntime.runImageLocked` sd-server path, the image cards and viewer, `SafetyPreparation` (install-time compile), `InstalledPhotoModels` (per-tier model and detector resolution), and the incognito wiring.

Counts: **P0 0 · P1 3 · P2 8**

## Verified clean (no finding)
- **Single import / single call site.** `import ChildSafetyCheck` appears only in `Packages/Engines/Sources/AntiChatEngines/Media/MediaOutputGate.swift:10`; `csc-bench` sits inside the package. The gate's `check*` methods are called only from `MediaJobRunner.swift:190,223,281`.
- **Fail closed.** If the manifest is missing, or the detectors are missing or damaged, the result is `.safetyMissing` (`MediaOutputGate.swift:176-193`). A detector error or a non-finite score while nude or unknown gives `.block` (`ChildSafetyCheck.swift:169-230`). A timeout, measured from the start of the work or capped from the moment it is queued, gives `.block` (`ChildSafetyCheck.swift:157-166, 243-259`). An undecodable or multi-image output is never written (`MediaJobRunner.swift:186, 221, 324-327`). With `safety == nil` the job fails closed with size 0.
- **Nothing is written or announced before `allow`.** Previews and the result are written only in `emitPreview` / `emitResult`, after the check. Reentrancy is re-checked after each await, and a result is checked at most once. Engines have no other image-write path; `grep '.write(to'` over Engines/EngineHost shows only the runner, the poster frame (after `checkVideo`) and the prepared marker.
- **Masks are composited before the gate.** The checked picture is the written picture (`EngineRuntime.swift` around 448-454, `LocalImageJob.swift:31-37`).
- **Blocked jobs leave nothing behind.** On `jobBlocked` the app deletes the job's xfer dir, earlier allowed previews included (`MediaJobQueue.swift:410-414`), and increments only `child_safety_blocks`.
- **No extra filtering (D-005).** No injected negative prompt, neutral tool descriptions, no prompt rewriting, and the decision rule is exactly `nude ∧ minor` (`DecisionRule.swift:74-76`). The forced-verdict seam compiles only under `ANTICHAT_UI_TESTING`.
- **Nothing sent, nothing logged.** No network API in the package. sd-server logs request params, including the prompt, only at `LOG_DEBUG` / `LOG_VERBOSE` (`examples/server/routes_*.cpp`, tokenizers), and `-v` is never passed (`SDServerSupervisor.swift:74-75`).
- **Incognito rows.** Incognito job rows live in the session's in-memory store (child queue). For normal chats, `media_job.chat_id` cascades on chat delete.

---

## P1

### P1-1: A Release build can run the gate on unpinned, self-hashed detector files (`-Bench image`)
- `App/AntiChat/AntiChatApp.swift:39-41`: `-Bench` is honoured in every configuration (no `#if DEBUG`). The M4 card's Release check relies on this.
- `App/AntiChat/BenchMode+Image.swift:126,130`: every bench image job carries `benchSafety = SafetyManifestResolver.resolve(modelsRoot: devModelsRoot)`, with no `pinned:` argument.
- `Packages/Harness/Sources/AntiChatHarness/Media/SafetyStatus.swift:64-76`: when `pinned` is nil, the expected sha256 of each detector is **computed from the file on disk**. The helper's "verify before load" (`ModelManifest.verifyFile`) then compares a file with its own hash.
- **Failure scenario.** Someone puts any ONNX/safetensors files at `~/Library/Application Support/AntiChat-Dev/Models/csc-nudity/onnx/model.onnx` (and `csc-age`, `csc-age-bins`), for example a nudity model that always returns 0. They then run the shipped Release app with `-Bench image --prompts F --out-dir D`. The helper's only content check loads those files, allows every output and writes the PNGs to `D`. This is a launch argument changing the gate's effective behaviour, which D-006 and the gate header (`MediaOutputGate.swift:5-8`: "No setting, launch argument or environment variable changes this") forbid. The normal product path is not affected: it uses the signed catalog's pins (`InstalledPhotoModels.swift:131-147`).
- **Fix.** Compile the image and video bench lanes only in DEBUG (or in a dedicated bench configuration that is never shipped). Failing that, build `benchSafety` from the catalog pins (`InstalledPhotoModels.safety`) and refuse to run when no pins are available. Make `resolve(pinned: nil)` itself `#if DEBUG`, and add an r241-audit rule that flags any non-DEBUG call to it.
- **Resolution.** Confirmed (AntiChatApp.swift honours `-Bench` in Release; BenchMode+Image built `benchSafety` with `resolve(modelsRoot:)` and no pins). Fixed on `fix/m4-review`: the self-hashing resolver is now `SafetyManifestResolver.resolveUnpinned` (+ `devModelsRoot`), compiled only under `#if DEBUG`; the public `resolve(modelsRoot:pinned:)` requires the catalog's pins. Release `-Bench image` keeps working for M9 perf but builds its manifest from the last good VERIFIED catalog (cache, else the signed baseline) and this container's install views, so the helper re-verifies the signed sha256 before loading; with no installed detectors every output is withheld. Release bench PNGs always go to the app's media cache (`~/Library/Caches/AntiChat/xfer/bench`), whatever `--out-dir` says. New r241-audit rule 2c fails any reference to the unpinned resolver outside `#if DEBUG` / tests (selftest `test_unpinned_detector_manifest_outside_debug_fails`). Note for the Release in-app check: a Release `-Bench image` run now needs the catalog's detectors installed in that container.

### P1-2: Closing an incognito chat, or stopping its turn, leaves the image job running; its result and prompt are written to disk after the session is "gone"
- Nothing cancels a media job when a turn stops or an incognito session ends. `ChatSessions.incognitoClosed` (`Packages/UI/Sources/AntiChatUI/Window/ChatSessions.swift:249-257`) only calls `m.stop()`. `IncognitoSession.discard` (`Packages/Harness/Sources/AntiChatHarness/Incognito/IncognitoSession.swift:147-163`) never touches `MediaJobQueue`. In production `queue.cancel` is called only from the card's ■ (`ImageJobActivityCard.swift:79`) and from quit.
- `ImageTools.run` waits in `queue.finished(id)` (`MediaJobQueue.swift:266-272`). That is a plain `withCheckedContinuation`, so it ignores task cancellation and runs on after the turn is cancelled.
- When the job finishes, `saveArtifact` (`ImageTools.swift:134-143`) calls `FileOutTools.Stores.shared.store(for: db)`. `discard` already removed that store (`IncognitoSession.swift:154`), so `Stores.store(for:)` (`FileOutTools.swift:30-37`) creates a **new** `ArtifactStore` rooted at a fresh `$TMPDIR/AntiChat-incognito-out-<uuid>` (`ArtifactStore.swift:34-38`). `save` writes the PNG **before** the DB insert (`ArtifactStore.swift:65`). The insert then fails, because the chat row was deleted and the FK cascades. The PNG, which embeds the prompt in XMP/tEXt (`MediaProvenanceWriter.writePNG(..., stripPrompt: false)`), stays on disk until the next launch's sweep. `ImageEditorActions.save` (`ImageEditorActions.swift:116-130`) behaves the same for Erase and Remove background.
- **Leak on top.** The child queue is never removed from `children` (`MediaJobQueue.swift:120-137`). It keeps the in-memory store alive, along with its own `$TMPDIR/AntiChat-incognito-xfer-<uuid>` root, which `discard` does not delete because it is not under the session's temp dir. Both last for the life of the process.
- **Scenario.** A user asks for a picture in incognito, then closes the window while it shows "Creating image…". 30-90 s later an image file carrying the prompt appears in `$TMPDIR` and survives until the next relaunch, possibly days later. The GPU job also keeps running and keeps the chat model evicted.
- **Fix.**
  - Add `MediaJobQueue.close(store:)`: cancel all of that child's jobs, delete its xfer root and remove it from `children`. Call it from `IncognitoSession.discard` / `incognitoClosed`.
  - Make `finished()` cancellation-aware (`withTaskCancellationHandler` → `cancel(id)`).
  - Have `Stores.store(for:)` refuse a closed in-memory DB instead of recreating a store, or keep a "closed" set. In `ArtifactStore.save`, write the file only after the row inserts, or delete it on failure.
  - Optionally cancel the call's job when a normal turn is stopped, and say so in the UI.
- **Resolution.** Confirmed (on main some of it had moved: the child queue is unregistered and `cancelAll` runs at discard, but `finished()` ignored cancellation, `Stores.store(for:)` recreated a store for a closed DB and `ArtifactStore.save` wrote the PNG before the insert). Fixed: `MediaJobQueue.close()` (no new job, every job cancelled, the session's xfer root removed once the running job ended — also when a late result raced the cancel; no further job starts); `IncognitoSession.discard` closes its queue; `finished()` is cancellation-aware (a stopped turn cancels its job); ImageTools / ImageEditorActions store nothing when the call was cancelled; `Stores.openStore(for:)` returns nil for a closed store (no fresh temp dir); `ArtifactStore.save` deletes the file it wrote when the row insert fails; the helper's runner writes no preview or result once the job is cancelled. Tests: MediaJobSessionEndTests (close, cancelled wait, closed store, failed insert).

### P1-3: T3+ live previews are checked at latent resolution, where the minor branch of the rule barely applies (unmeasured)
- `ImageRequestBuilder.swift:109` sets `preview: "proj"` whenever live previews are on (T3+, `ImageTurnPolicy.swift:60`). sd.cpp's `PREVIEW_PROJ` is a latent→RGB projection (`Binaries/sdcpp/src/pipeline/diffusion_engine.cpp:2052-2066`). For FLUX.2 (klein) that is 128 channels with patch 2, so a 1024² job gives roughly a **128×128** preview. `EngineRuntime.swift:375-377` itself calls these previews "latent-sized". Each is checked as-is (`MediaJobRunner.swift:186-190`), then shown scaled up to the 512-pt card (`ImageJobCard.swift:137-139`, `.resizable().scaledToFill()`).
- **Why the minor branch fails.** A face counts only if its shorter side is ≥ 24 px (`thresholds.json face_min_side_px: 24`, `DecisionRule.swift:47-49`). At 128 px most faces in anything but a close portrait are below that, so there is no face age. "Minor" then rests on Vision's human-rectangle detector, and the age bins on body crops of a few dozen pixels. If no person is found, `queries` is empty, `minor == false`, and the result is **allow even when nude** (`ChildSafetyCheck.swift:188-224`).
- **No measurement covers this.** S-8 / F1 / F2 were calibrated on full-size images. The M4 report moves the T3 preview figures to M9 (`M4-report.md:24`).
- **Scenario.** A T3+ job whose final picture would be blocked shows 1-3 blurry but recognisable previews before the final check blocks it. D-006 ("nothing unchecked is ever shown, previews included") is met on paper, but the check on those frames may be close to a no-op. T0–T2 are unaffected, because they have no previews.
- **Fix.** First measure F1/F2 on preview-sized inputs (downscale the existing SFW / age-labelled sets to the proj size; never combine nudity with a minor). Then pick one, as an owner decision:
  - (a) Decode previews with the VAE / TAESD at ≥ 512 px.
  - (b) Show no preview below a detector-valid size.
  - (c) For previews only, treat "nude ∧ age inconclusive (no usable face or body)" as "don't display this preview" without blocking the job.
- **Resolution.** Confirmed and measured (see M4-report amendment A-M4-R1, build/at/M4-review/preview-size.json). The check cannot be shown valid at latent-projection size (usable faces drop sharply; nudity recall at small sizes is not measurable under D-019), so preview handling now fails closed: `ChildSafetyCheck.evaluatePreview` withholds any preview whose shorter side is below `preview_min_side_px` (thresholds.json v4) without running anything — the job continues with progress only, the final image is checked unchanged. T3+ sd-server `proj` previews (~128 px) are therefore never shown; video step previews (160 px short side) likewise (flagged to the lead / M5). Decoding previews at ≥ 512 px (VAE / TAE preview) is the way to bring them back; its cost is a timing item for M9.T05.

---

## P2

### P2-1: Incognito child queues break "one job at a time"; the waiting job fails `job.notStarted` after 60 s and still runs later in the helper
- Each in-memory store gets its own `MediaJobQueue` with its own `runningJob` / `pump` (`MediaJobQueue.swift:125-137, 297-313`), and every queue shares one helper transport. A normal-chat job and an incognito job (or Erase in one, an image in the other) are therefore both submitted at once.
- The helper's `MediaJobRunner.run` sends `jobStarted` only **after** `acquire()` (`MediaJobRunner.swift:107-125`). The second job waits there for the whole first job, which includes a cold sd-server start, chat step-aside and generation and can exceed 60 s. The app's start watchdog then fires (`MediaJobQueue.swift:359-373`): the card shows an error and the tool returns failed.
- `transport.cancel` only sets the job's `CancelFlag` (`SessionRouter.swift:119-124`), and `run` never checks it after `acquire()`. When the first job ends, the abandoned job still steps the chat model aside and starts sd-server (`EngineRuntime.swift:336-366`) before its poll loop notices the cancel.
- **Aggravating.** With three or more queues (two incognito windows plus normal), `acquire()` lets a newcomer barge in. `run` sets `busy = false` and only then resumes a waiter (`MediaJobRunner.swift:139-140, 154-161`); a new caller can see `busy == false` before the waiter wakes, and two jobs enter the runner together. `current` is a single slot, so one job's outputs fail the `c.job == job` guard and it ends `noResult`. The gate is never bypassed, but the job fails.
- **Fix.**
  - Serialise every store's jobs through the parent queue: one `runningJob`, children only own rows and files.
  - Hand the runner's lock straight to the waiter (keep `busy` true when resuming one).
  - In `run`, after `acquire()`, end at once with `jobCancelled` if the flag is set.
  - Start the app's watchdog only once the job is at the helper's head, or have the helper ack submits before `acquire`.
- **Resolution.** Not in this branch: owned by the M5 fixer.

### P2-2: A ■ pressed before the submit is sent is lost; the job runs to completion and the picture appears
- `pump()` sets `runningJob` synchronously (`MediaJobQueue.swift:307-308`). `execute()` then awaits `safety()`, which does a MainActor hop and possibly `PackManagementModel.refresh()`, and `transport.engineInstanceID()`, which may connect or launch the helper, before `transport.submit` (`:315-340`).
- If ■ is pressed in that window, `cancel()` sees the running id, records `cancelRequested` and calls `transport.cancel(requestID)` (`:186-189`). The helper has no entry for that request yet, so it ignores it (`SessionRouter.swift:119-126`).
- The submit then goes out and the job runs. Its `jobResult` maps to `.done` regardless of `cancelRequested` (`:376`). The ■ fix in e8ec68c6f covers only "helper never starts it".
- **Fix.** Just before `transport.submit`, end with `.cancelled` if `cancelRequested.contains(id)`, and send the cancel again right after the submit. If the engine-instance lookup fails after a ■, end cancelled, not failed.
- **Resolution.** Not in this branch: owned by the M5 fixer.

### P2-3: `queued` rows left by a crash or force-quit run ahead of the user's next job, unattended
- At launch, `RecoveryRepository` moves only `running` rows to `lost` (`RecoveryRepository.swift:27-28`). `ChatEnvironment.open` calls `sweepFiles()` but never `pump()` (`ChatEnvironment.swift:96-99`).
- Leftover `queued` rows sit idle until the next `enqueue` or `cancel`. That call's `pump()` then picks the oldest one first (`MediaJobQueue.swift:299-301`).
- **Scenario.** After a crash with two pictures queued, the user's first new picture waits behind two orphan jobs nobody is waiting for. The orphans' results end `.done`, are never `discardFiles`'d and are never stored, so they sit in `~/Library/Caches/AntiChat/xfer/<id>/` until the next launch.
- **Fix.** At launch, mark leftover `queued` rows `cancelled` or `lost` (with Restart) in the recovery sweep, or pump them deliberately. Never run them silently before new work.
- **Resolution.** Confirmed. Fixed: the launch sweep (RecoveryRepository) settles `queued` rows like `running` ones — `lost`, position cleared, Retry on the card — so nothing runs unattended ahead of new work. Test: MediaJobSessionEndTests.queuedRowsAtLaunchAreSettledLostAndNeverRunAheadOfNewWork.

### P2-4: Memory at T0–T2: local jobs skip step-aside, LaMa stays loaded forever, the install compile has no lease
- `EngineListener.runMediaJob` handles `.local` (Erase, Remove background) without `runtime.attach` / `sched.runJob` / `stepAsideForMedia` (`EngineListener.swift:289-303`). At T0–T2 the detectors are loaded for the final check while the chat model stays resident. S-8 measured the detectors at 2.3 GB steady and 4.3 GB peak before compaction; the T1 cap is 9.5 GB.
- `EraserCache` keeps the `LaMaEraser`, and so the loaded `MLModel`, for the helper's whole life (`EngineListener.swift:388-399`). `LaMaEraser.unload()` has no caller. About 600 MB stays resident outside the scheduler's budget, which the next image job's step-aside maths does not see.
- `MediaOutputGate.prepare` compiles and loads the detectors twice in a detached task (`MediaOutputGate.swift:128-154`), with no scheduler lease, typically during onboarding while a chat model is loaded.
- **Fix.**
  - Run local jobs under `sched.runJob` with step-aside bytes equal to LaMa plus the detectors.
  - Unload LaMa after each job on `lowTier`, or register it as a job model.
  - Take a scheduler lease, or step the chat model aside, for `prepareSafety` at T0–T2.
  - Measure Erase at T1 with the chat model resident.
- **Resolution.** Confirmed. Fixed within the scheduler: new `EngineRuntime.runMediaWork(key:bytes:)` runs work whose models the scheduler doesn't track in its job slot after the media step-aside. Erase / Remove background run through it with LaMa/Vision + detector bytes (`EngineRuntime.detectorBytes`, S-8 peak 4.3 GB), and LaMa is unloaded after each job on T0–T2 (`EraserCache.unloadAll`). The install-time detector compile runs through it on T0–T2 (already prepared ⇒ no job). Erase at T1 with the chat model resident is a measurement for M9.T05.

### P2-5: Erase / Remove background with missing detectors shows a generic error, not the repair card (R-285 AC6)
- `ImageEditorActions.run` pre-checks `photo.safetyManifest() != nil` (`ImageEditorActions.swift:60`). `InstalledPhotoModels.safetyManifest()` always returns a manifest built from catalog paths, even when the files are absent (`requireSlot: false`, `InstalledPhotoModels.swift:68, 131-147`), so the job always runs. The helper answers `safetyMissing`, and the result maps to `.unavailable` (`:100`).
- `ConversationModel.localEdit` folds `.unavailable` into `.failed` (`ConversationModel.swift:209`), and the viewer shows `media.error` (`ImageViewer.swift` `local(_:)`).
- **Fix.** Carry `safetyMissing(sizeBytes:)` through `LocalEditOutcome` and show `SafetyMissingCard` / the repair action in the viewer.
- **Resolution.** Confirmed. Fixed: `ImageEditorActions.Outcome.safetyMissing(sizeBytes:)` → `LocalEditOutcome.safetyMissing` → the viewer shows `SafetyMissingCard` with the repair action (Settings › Capabilities). Test: MediaJobSessionEndTests.editorActionsReportMissingDetectorsWithTheRepairSize.

### P2-6: Lost jobs' input files are kept forever
- `ended(.lost)` and the launch sweep keep a lost job's `input-*` files (Erase's brush mask) "for its restart" (`MediaJobQueue.swift:412, 465`). `restart(_:)` (`:221-235`) has no production caller: the card's Retry re-runs the turn instead.
- Every lost Erase therefore leaves `~/Library/Caches/AntiChat/xfer/<id>/input-mask.png` behind, with no expiry.
- **Fix.** Wire Restart to `restart(_:)`, or delete inputs with the lost job. Alternatively, age out lost rows' dirs after N days.
- **Resolution.** Confirmed. Fixed: the launch sweep removes a lost job's dir including its inputs (nothing restarts a job of an earlier run); within one run the inputs still stay for `restart(_:)`, which now refuses (`inputGone`) when its mask is gone. Test: MediaJobSessionEndTests.launchSweepRemovesALostJobsInputsAndRestartThenRefuses.

### P2-7: T3+ preview-check timeouts block the whole job (over-blocking, unmeasured)
- Every preview gets the 2 s deadline (`thresholds.json timeout_ms: 2000`) while the generator holds the GPU. On timeout the check returns `.block` (`ChildSafetyCheck.swift:163-165`), and the runner withholds the **job**: no later previews and no result (`MediaJobRunner.swift:191, 308-315`). The user sees "Not shown" for a benign picture, and `child_safety_blocks` goes up. The M4 report confirms load can add blocks (`M4-report.md:31`), and T3 preview timings are deferred to M9.
- **Fix.** For previews, a timeout or inference error should only suppress that preview, which is still fail closed because nothing unchecked is shown. Keep `block` for finals. This needs a package-internal reason, already present in `Trace.failure`.
- **Resolution.** Confirmed. Fixed: a preview check gets one attempt (no 10 s re-check); a timeout or detector error while nude or unknown returns `withhold` — that preview is not shown, the job goes on, nothing is counted. A rule block on a preview still stops the job; the final image's rules are unchanged. Tests: PreviewRuleTests.

### P2-8: Accessibility: the live preview image has no label
- `ImageJobCard.swift:137-140`: the preview `Image(nsImage:)` has an identifier but no `accessibilityLabel` and is not hidden, so VoiceOver reads an unlabeled image while generating. The done image and the placeholder are handled (`:134`, `DotMatrixPlaceholder` hidden).
- **Fix.** Label it (e.g. "Preview of the picture being created") or hide it, since the % pill already speaks the progress.
- **Resolution.** Confirmed. Fixed: the live preview carries the label `img.preview.a11y` ("Preview of the picture being created", deck + 5 translations, xcstrings regenerated).

---

## One-line list
- P1-1: Release `-Bench image` loads self-hashed, unpinned detectors, so a launch argument changes the gate.
- P1-2: An incognito close or turn stop doesn't cancel the job; the late result and its prompt are written to a new `$TMPDIR` dir after discard; the child queue and xfer root leak.
- P1-3: T3+ previews are checked at roughly 128² latent resolution, where the minor branch rarely fires; not calibrated.
- P2-1: Incognito child queues run jobs concurrently, the second fails `job.notStarted` at 60 s and still runs later; the runner's `acquire()` lets jobs barge in.
- P2-2: ■ before submit is ignored by the helper; the job completes and shows.
- P2-3: Stale `queued` rows from a crash run ahead of new work, unattended; their results are orphaned.
- P2-4: Local jobs skip step-aside, LaMa is never unloaded, and the install-time compile has no scheduler lease (T0–T2 memory).
- P2-5: Viewer Erase / Remove background with missing detectors shows `media.error`, not the repair card.
- P2-6: Lost jobs' input masks are kept forever because `restart` is never called.
- P2-7: A preview-check timeout at T3+ blocks the whole job (over-block plus counter).
- P2-8: The live preview image has no accessibility label.
