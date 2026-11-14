# M5 (Video pack) independent close review (D-025) — AntiChat main @ 34738a524

Read-only review: nothing was built, run, edited or committed. No imagery or video was created or fetched.

## Prior review status

There is no M5 review document in `docs/prd/reviews/` (only M6 and M8). There was an internal M5.T14 review, whose
fixes are commit 11aa0b194. The review text itself is not in the repo, so I could not check that review for
completeness. I did a fresh review and also checked a sample of the T14 fixes. All of the sampled fixes are present
and correct:
- P1-1 incognito queue: `MediaJobQueue.ephemeral/register/serving`, `IncognitoSession.swift:82-85`, `VideoTools.swift:211` (fails closed when the session has no queue).
- P1-2 xfer cleanup: `resultStored` → `removeFiles` (`MediaJobQueue.swift:179-183`, `VideoTools.swift:248`). The cleanup also runs on blocked, failed and cancelled ends; lost jobs keep only their inputs.
- P1-3 I2V release: `EngineRuntime.runReleasing` (`EngineRuntime.swift:661-672`, `:684-690`).
- P1-4 late cancel: `MediaJobRunner.emitVideoResult` checks cancel before the gate, after the gate and after the encode (`:277`, `:297`, `:314-317`). The queue also turns a result that raced a cancel into `cancelled` (`MediaJobQueue.swift:466`).
- P1-5 sd cancel grace: `SDVideoEngine.swift:100-111`, with `uncancellableSleep` so there is no busy loop.
- A-M5-09: the re-check waits for the timed-out run (`ChildSafetyCheck.swift:161-176`).

## Gate (D-005 / D-006): no bypass found

I checked the gate path end to end:
- Single call site: `MediaOutputGate.check*` is called only from `MediaJobRunner.swift:194,227,295`. `MP4Encoder.encode` and `PosterFrame.jpeg` are called only after `apply(outcome)` returns allow.
- What is checked is what ships:
  - The MP4 is encoded from the same `frames` array whose sampled indices were checked: ≥ 2 fps + first + last (`VideoFrameSampler.swift:22-29`).
  - The poster is `frames[0]`, which is always sampled.
  - Each preview is checked as decoded from the exact bytes that are then written. Multi-image containers are refused (`decode`, `:351-354`).
  - Early previews (A-M5-07) are dropped before the gate and are never written or shown (`VideoEngine.swift:185`, `SDVideoEngine.swift:119`).
  - Audio and the I2V source picture are not checked, by design (D-005/D-006).
- Fail closed:
  - No manifest or a load error gives `safetyMissing`.
  - A stream error, cancellation or incomplete coverage gives block (`VideoFrameSampler.swift:41-55`; `MediaJobRunner.swift:286`).
  - A timeout gives one bounded re-check, and a second timeout blocks.
  - The forced-verdict seam compiles only under `ANTICHAT_UI_TESTING`.
- On a withheld result, the engine throws `video.withheld`. The runner's catch maps it to `jobBlocked`/`safetyMissing` (`MediaJobRunner.swift:134-137`), and the app removes `xfer/<job>`.
- The UI shows only gated paths: `jobProgress.previewPath` → `VideoJobStatus.addPreview`, and the result/poster from `jobResult`. `.videoProgress` events carry no paths. The blocked phase shows `BlockedMediaTile`.
- The scripted engine is `#if DEBUG` on both sides and also goes through `outputs`.

## P0

None.

## P1

### 1. Video does not work on a real install: the TAEHV weights are never installed, and the default T2V model then hard-fails.
- Code:
  - `Packages/UI/Sources/AntiChatUI/Media/InstalledVideoModels.swift:100-102` uses `installs/vid-taehv/taew2_2.safetensors` only "when present (dev models carry it; no catalog entry)". Otherwise `req.taehv = ""`.
  - `Packages/Engines/Python/antichat_video/server.py:76-78`: `Wan22Generator` with no `taehv_path` raises `ValueError("taehvMissing")`. The job fails before generation.
  - TAEHV is also the final-frame decoder (`wan22_generator.py:114,163`), not just the preview decoder.
  - I2V: `SDVideoEngine.swift:39,52` then runs without `--taesd`, with `preview: "proj"`. That means sd.cpp's full Wan2.2 VAE decode, which the same file (`:13-15`, S-10 / A-M0-T07b) calls "unusable at e239e4b".
- Catalog: `catalog/models.yaml` and `Packages/Platform/Sources/AntiChatPlatform/Resources/catalog-baseline.json` have no `vid-taehv` entry. `vid-5b`, `vid-i2v` and `vid-14b` do not `requires` it, and their file lists do not include it.
- Scenario: a user on T2/T3 (assignments: `video: [vid-5b, vid-i2v]`, plus `vid-ltx` on T3) installs the Video pack and asks for a clip with Sound off (the default model is `vid-5b`). The helper gets `taehv=""`, the runtime emits `error{code: taehvMissing}`, and the job ends `failed` (card shows `media.error`). Every silent T2V job fails. Animate (I2V) takes the decode path the code itself calls unusable. Only `vid-ltx` (Sound on, Normal chats, T3+) avoids TAEHV. Evil chats can never use `vid-ltx`, so video never works in Evil.
- Why the ATs passed: the AT and bench runs use the dev model cache, which `tools/m0/at-m0-07.sh:39-47` fills with `vid-taehv` by hand.
- Fix:
  - Add a catalog entry `vid-taehv` (madebyollin/taehv@fa579a9 `safetensors/taew2_2.safetensors`, sha256 `b84609b2…`, MIT) and make it a `requires` of `vid-5b` and `vid-i2v` so the pack installs it.
  - Make `InstalledVideoModels.request` return nil (shown as `unavailable`) instead of `""` when the file is missing.
  - Add a clean-install-view AT that does not use the dev cache.
  - Check whether `vid-14b` (T4) needs a different TAE (Wan2.1 latent space, z_dim 16). I did not verify that.
- **Resolution (fix/m5-review):** confirmed (catalog had no `vid-taehv`; `InstalledVideoModels` sent `taehv=""`). Fixed through the catalog: new entry `vid-taehv` = `madebyollin/taehv@fa579a9a726b0a55951998d73e309bfdf0abd342` `safetensors/taew2_2.safetensors` (22,848,048 B, sha256 `b84609b2…`, MIT) + `LICENSE`, `host: github` (the exact file is only on GitHub; the HF copies `lightx2v/Autoencoders` and `Kijai/WanVideo_comfy` are the same size but all 128 tensors differ, so they would void the A-M0-T07a parity proof). `vid-5b` and `vid-i2v` now `requires` it; `make catalog` published the new version + bundled baseline; catalog-tool resolves `host: github` (GitHub tree API + one hash download), lint/schema accept a commit-pinned `raw.githubusercontent.com` URL (A-M5-11). `InstalledVideoModels.request` takes TAEHV from the install view and returns nil (unavailable) when it is missing. `VideoInstallSetTests`: a fresh T2/T3 install's Video set (Normal and Evil) includes `vid-taehv`, and requests built from catalog-laid-out install views carry the TAEHV path for T2V (Normal + Evil, so Evil chats get video) and I2V, nil without it. `vid-14b` checked: Wan2.1 latent space (z 16, /8 spatial) — taew2_2 does not fit and the runtime's Wan22Generator has no Wan2.1 path, so vid-14b does not require it and a T4 T2V job resolves to unavailable instead of failing; T4 support (TAEW2.1 pin + generator) is a follow-up (A-M5-11). **Follow-up done (fix/t4-video, A-M5-13):** T4 text-to-video now runs on vid-5b (vid-14b measured 5–40× over NFR-VID1 and dropped from the catalog, v12); `VideoInstallSetTests.freshT4InstallResolvesTextToVideo` + a real T4 clip through the app path (`build/at/T4-video/`).

## P2

### 2. A cancel pressed before the job reaches the helper is silently dropped, so the whole clip is generated and then thrown away.
- `Packages/Harness/Sources/AntiChatHarness/Media/MediaJobQueue.swift:427-449`: `pump()` sets `runningJob` with the job's `requestID`. Then `execute` awaits `safety()` (a MainActor hop, possibly a `PackManagementModel.refresh()`), awaits `transport.engineInstanceID()` (connects or launches the helper), and does a DB write. Only after that does it call `transport.submit`.
- During that window, `cancel(id)` (`:282-286`) inserts into `cancelRequested` and calls `transport.cancel(requestID)`. `EngineClient.cancel` (`EngineClient.swift:458-461`) returns early because no stream is registered for that id yet. The helper never hears about the cancel.
- Scenario: the user presses ■ on a fresh card while the helper is cold-starting. Nothing stops. The job keeps the GPU busy and holds a sleep assertion for the whole generation (tens of seconds to minutes). The card stays "running". Only at `jobResult` does `cancelRequested` turn it into `cancelled` and delete the files. NFR-VID3 cancel is not met. The same applies when an incognito session's `discard()` cancels in that window.
- Fix: in `execute`, after the awaits and before `submit`, add `if cancelRequested.contains(id) { ended(id, state: .cancelled); return }`. Also re-send `transport.cancel(submit.requestID)` right after `submit(...)` has registered the stream, if a cancel was requested meanwhile.
- **Resolution:** confirmed (also M4 review P2-2). On top of main's a9d065455 watchdog: `execute` ends the job `cancelled` and never submits it when `cancelRequested` holds the id after the safety/helper awaits, and an engine-instance failure after a ■ also ends `cancelled`. A re-send after `submit` is not needed: `EngineClient.batches` registers the stream synchronously, so from then on `cancel` reaches the helper (or its pending-cancel set). Tests: `MediaJobSlotTests.cancelWhileAwaitingSafetyIsNeverSubmitted` (image and video).

### 3. The "one running job" rule is per queue, so an incognito queue and the app queue both show a job as running at once.
- `MediaJobQueue.ephemeral` (`:115-118`) creates an independent `runningJob`/`pump`. The parent queue and its derived queues never share a slot. Both rows go to `running` (position 0) and both are submitted. The helper's `MediaJobRunner.acquire` (`MediaJobRunner.swift:158-165`) then serialises them, so the second waits in the helper.
- Scenario: a Normal-chat video is generating and the user starts a picture or video in an incognito window. The second card shows "Preparing…" at 0 % with a running timer and no waiting position, for the full length of the first job (minutes). Its ETA and elapsed time are wrong. R-291 AC1's single running job and the `job.waitingPosition` line are not honoured across queues.
- Fix: derived queues should pump through the parent's slot (one process-wide pump token or semaphore, positions computed across queues). At minimum, keep the row `queued` and show waiting until the helper's `jobStarted` arrives.
- **Resolution:** confirmed (also M4 review P2-1). The app queue and its derived incognito queues share one slot (`MediaJobSlot`); a queue whose next job waits for another queue's job keeps it `queued` (position 1 → the card shows waiting) and submits only when it holds the slot, so the start watchdog counts from the real submission; freed slots go to waiting queues in arrival order. Helper side: `MediaJobRunner` hands its lock straight to the waiter (no barging with ≥ 3 callers) and ends a job cancelled while waiting with `jobCancelled` before its engine runs (A-M5-12). Tests: `MediaJobSlotTests` (image + video, three queues, cancelled waiting queue), `MediaJobRunnerHandOffTests`.

### 4. Cancelling an Animate (I2V) job can take more than 10 s to free memory, beyond NFR-VID3's 2 s, and this is not measured.
- `Packages/Engines/Sources/AntiChatEngines/Video/SDVideoEngine.swift:26,100-111`: cancel → sd-server `cancel` → poll until sd-server reports `cancelled` (it finishes the current Wan 5B step first) or until the 10 s `cancelGrace` runs out → `stopServer`. The T2V runtime path escalates after 500 ms + 1 s (A-M5-T01a d). AT-NFR-VID3 (`docs/prd/M5-report.md:27`) covers only the runtime path.
- Scenario: the user cancels an Animate job mid-step. The card stays busy and the sd-server context, several GB, stays resident for up to about 10 s. That breaks the 2 s cancel-frees-memory budget for a video job.
- Fix: use the same escalation as the runtime (stop sd-server about 1.5 s after the cancel; the context is released after I2V anyway). Or record an amendment, and run AT-NFR-VID3 on the I2V leg.
- **Resolution:** confirmed (10 s `cancelGrace`). `SDVideoEngine.cancelGrace` is now 500 ms, the T2V runtime's soft-cancel window: sd-server gets 500 ms to answer `cancelled`, then it is stopped (and EngineRuntime's `runReleasing` stops it after every I2V job anyway), so the context's memory comes back within NFR-VID3's 2 s instead of up to ~10 s. Unit: `SDVideoEngineCancelGraceTests` (ignored cancel → stopped after the grace, no spin; default = 500 ms). Measurement: new AT-NFR-VID3 I2V leg `I2VRealTests.cancelMidDenoiseFreesTheServerWithinTwoSeconds` (real Animate job, cancel at denoise step 2 and 4, cancel → sd-server gone ≤ 2 s; rows `build/perf/raw/video-i2v-cancel.jsonl`, summary `build/at/AT-NFR-VID3/cancel-i2v-T3.json`). The timing run `~/AntiChat-tools/gpu-run.sh timing -- env ANTICHAT_REAL_VIDEO=1 ANTICHAT_I2V=1 ANTICHAT_I2V_CANCEL=1 make test-unit FILTER=cancelMidDenoiseFreesTheServerWithinTwoSeconds` is queued (holds the GPU lock and slot 1 since 05:35, load 26 at queue time); slot 2 is held by another track's AT-250 judge run (4 h+), so the number is not in yet — pending, to be recorded from that run (or M9.T05 if it is deferred).

### 5. Incognito: Show in Finder and Open on an incognito clip leave traces outside the session (platform behaviour; I did not run this).
- `Packages/UI/Sources/AntiChatUI/Media/VideoJobCard.swift:223-226` ("Show in Finder" `activateFileViewerSelecting`, "Open" `NSWorkspace.open`) and `ImageViewer/VideoViewer.swift:76` (reveal) are offered unchanged for incognito clips, which live in `$TMPDIR/AntiChat-incognito-*/`. There is no incognito check anywhere under `Packages/UI/Sources/AntiChatUI/Media` or `ImageViewer`.
- Scenario: in an incognito chat the user picks Open. QuickTime Player records the file in its recent documents, and may save window state, with the path. Show in Finder makes Finder/Quick Look generate and cache a thumbnail of the clip and poster in the per-user QuickLook thumbnail cache. Both outlive `discard()` and the launch sweep. This is the same class of issue as M6 review #4.
- Fix: in incognito, hide Reveal and Open, or route them to the in-app viewer. Keep Export (an explicit save is the user's choice).
- **Resolution:** confirmed (no incognito check). Like M6 review #4 (path under `AntiChat-incognito-*`, `IncognitoPaths`): Show in Finder and Open are not offered for an incognito clip on the card (`VideoJobCard.offersFinder`) or in the viewer; Export/Save As stays. Test: `VideoReviewUITests.incognitoClipsAreNotHandedToFinder`.

### 6. Accessibility: the live video preview has no label.
- `Packages/UI/Sources/AntiChatUI/Media/AnimatedPreview.swift:38-39`: the element has only `accessibilityIdentifier("videoJob.preview")` and `accessibilityValue("\(shown.count)")`. VoiceOver reads a bare number such as "3", or "image".
- Fix: add a label (for example a `video.preview` copy key: "Preview, step n of N"), or `accessibilityHidden(true)` and let the stage line carry the state.
- **Resolution:** confirmed. The preview is one image element labelled `video.preview.a11y` ("Video preview") with the value `video.preview.a11yStep` ("Step n of N", the shown frames' step); copy deck + `gen-xcstrings.py`. Test: `VideoReviewUITests.previewHasALabelAndAStepValue`.

### 7. Accessibility: when Export MP4 fails, the only feedback is a beep.
- `Packages/UI/Sources/AntiChatUI/Media/VideoSavePanel.swift:66-71`: the catch calls `NSSound.beep()` and returns nil. There is no toast, alert or VoiceOver announcement.
- Scenario: a VoiceOver user, or anyone with sound off, exports to a full or read-only volume (or a passthrough export fails). Nothing tells them the file was not written.
- Fix: show an error toast (`AppToasts`, as other file saves do) and post an accessibility announcement.
- **Resolution:** confirmed. A failed export shows the warning toast `video.exportFailed` (the toast host posts it as a VoiceOver announcement) and logs the error; no beep. Test: `VideoReviewUITests.failedExportShowsTheErrorToast`.

## Checked and dropped (no defect)

- Thermal governor: a hold always ends on cancel (`checkpoint` polls `isCancelled`, and `releaseForCancel` sends SIGCONT or `/resume`). The router sets the media flag on session teardown too, so there is no spin when the Task is cancelled. `Control.cancel` also unblocks a cooperative pause.
- The runtime failure paths free the job's frames: an error makes `afterJob(keepWarm: nil)` stop the runtime.
- AVI parser bounds are correct.
- In a closed incognito session, files the helper writes again (its dir is recreated) are removed by `removeFiles` on the terminal event. At most an empty, ownerless temp dir is left, and the launch sweep removes it.
- Keep-open: `hasRunningVideo` includes the derived queues. A queued video behind a running picture is covered by `hasRunning`.
- Model selection: Evil never runs LTX (`VideoSound.model`, and `InstalledVideoModels.request:119` returns nil).
