# M10 report

M10.T11 closes the release candidate (RC) here (2026-11-13). The M10.T09 final-acceptance section from 2026-11-09
follows it unchanged. M10 stays **blocked (Q-003)** on the owner's production keys (M10.T10): the dev-form RC is the
deliverable, and every item still pending is marked so below.

## RC close (M10.T11), 2026-11-13

### The release candidate
- **RC** = main `e8fe19986` + round 67 (`45f2bfd09`: T05 docs and tools; the perf-only MLX cache-cap switch reverted)
  + round 68 (code-review fixes: Evil withdrawal on a resumed onboarding, the Step-4 way out, the untrusted-repair
  flag, the repetition guard on tool calls only, retitle off main). **Round 68 merged:** main `daff18809` (checked 2026-11-13).
- **Signed release: NOT built.** It needs the owner's production keys ([`tools/release/KEYS.md`](../../tools/release/KEYS.md));
  the release build refuses dev keys. The ad-hoc try-out, build 1655, is at `~/Desktop/AntiChat-tryout`.

### Acceptance on the RC

| Check | Result | Notes |
|---|---|---|
| `make test-offline` | **pass** | harness fix `30508376d` |
| `make test-install` (Tart VM) | **pass** | harness fix `7ce0adae3`; product bug fixed in `62e069850` (the session ledger re-created the logs folder after Remove everything) |
| AT-102 strict | **pass** | native review of the P1 update-copy translations is an owner item (pending) |
| Unit, integration-stub | **pass** | |
| AT-220, AT-109, AT-100, AT-229 checks | **pass** | |
| AT-273 (150 files) | 145/150 on the first pass; 4 of the 5 misses pass re-run alone (1 harness, 2 flaky); 1 real normaliser bug (malformed `sheets` JSON) fixed in `bfd2e55c2`, **re-run pending**. Image prompts 15/15 | run on RC `e8fe19986` |
| UI suite (`make test-ui`) | **pending** (re-run on the RC) | |
| Real-model and GPU evals | **not re-run on the RC** | prior evidence: M9-report §5 (T05), §6 (soak), M3–M8 reports, the M10.T09 section below |
| AT-FA-01 / AT-FA-12 devid forms | **pending M10.T10 owner steps** | need production keys |
| `make audit`, R-241 audit | **pending** (no RC result recorded) | |

### NFR headlines
- **AT-NFR-S3 soak.** The 8-h T1 run on `0418f820a` **failed** on 40 hangs > 2 s only (growth −0.4 %, 0 crashes,
  0 OOM, 319 loops, 0 failures). Root cause: the soak launched the app with the `.prohibited` policy, so the main
  thread ran at priority 31 and was starved under load. Fix: the soak launches through LaunchServices with the
  `.accessory` policy (priority 46; [`AT-NFR-S3-method.md`](AT-NFR-S3-method.md)), plus the writer-off-main fix
  (`da092f429`). A/B under the same load: hangs > 2 s 3 → 0, ≥ 1 s 33 → 0. Owner decision: no 8-h re-run. The **2-h
  confirmation soak on `dbaad0bc9` passed**: 0 hangs > 2 s (max 0.50 s), growth 2.8 %, 98 loops, 0 failures,
  0 crashes, 0 OOM.
- **T05, round-66 quiet window** (M9-report §5.6, §5.7).
  - Pass: U6, U10, U11 (274 ms), C2 T1 (100.8 tok/s), F7_VIDEO T4 / T3, PR1 (0 bytes).
  - Miss (S2, known issues): U2 (34.2 / 119 ms), U5 (18 / 3 hitches), VID1 T4 (105.5 s), VID2 T4 (first preview
    38–76 s), B5 (12.38 s; the sampler attributes the GPU to WindowServer).
  - T4 peak memory fixed (28 GB). Known regression on runtime 0.3.5: i2v is no longer offered on T2-S1 or T3; the
    fix goes to runtime 0.3.6. The ≤ 5-min auto-start rule is unchanged.
- **AT-NFR-S1 crash-free sessions, AT-NFR-R2 swap session:** no result recorded (pending; M9-report §6).
- **NFR-D1 DMG size:** the M10 DMG size doc is an owner item (pending).

### Visual parity (AT-VQ-M10)
The blind re-score on `366483ef8` **misses the looks bar**: ★ 2/11 pass; others ≈ 55 %. **Owner decision
2026-11-12: looks-only misses do not gate the release.** The 8 functional bugs it found (F1–F8) are fixed in round 66.
The full AT-VQ-M10 run (vq-15 DMG, vq-16 website, About label) on a signed build is pending with the signed release.

### Code review
`/code-review` on rounds 61–66: 5 findings, all fixed in round 68 (listed under "The release candidate").

### Owner-only items (open)
1. Production keys and the release-keys ceremony ([`tools/release/KEYS.md`](../../tools/release/KEYS.md)); RB-1
   runtime URLs; RB-2 RelayURL. These unblock M10.T10, the signed build and the devid forms of AT-FA-01 / AT-FA-12.
2. VoiceOver walkthrough (NFR-A6); Full Keyboard Access for the KeyboardOnly UI tests.
3. Legal K-060.
4. Native review of the P1 update-copy translations; the "No lectures" copy.
5. sudo legs: tcpdump, fs_usage, `purge`.
6. Open Numbers, Pages and Keynote once each, then re-run the office open matrix.
7. Push fixtures `5416b9c` to the local bare repo.
8. The M10 DMG size doc.

### Pending (not owner-only)
- UI suite re-run on the RC.
- AT-273 re-run of the normaliser fix (`bfd2e55c2`).
- AT-NFR-S1 crash-free sessions, AT-NFR-R2 swap session.
- `make audit`, R-241 audit.

## Final acceptance (M10.T09), 2026-11-09

How to run it: [`tools/release/final-acceptance.md`](../../tools/release/final-acceptance.md) (`make test-final`).
Evidence: `build/at/AT-FA-<nn>/<date>/` (`result.json`, `checks.tsv`, and probe JSON, logs and captures).
Regenerate this table with `python3 -I tools/install-test/fa-report.py`.

### Setup
**Clean account.** Every VM pass ran in a fresh clone of the Tart base image `antichat-clean-26.x` (macOS 26.6.2).
Each clone was deleted afterwards, and the base image was never run or changed.
- **Debug pass.** 8 GB / 4 CPUs, which the app's own hardware probe classifies as **T0**. It ran the test-flavoured
  Debug build of the branch head.
- **Release pass.** It ran the Release RC as two DMGs, N-1 = 0.0.1 (907) and N = 0.0.2 (908). Both are dev-signed
  (Apple Development), use dev keys, and are labelled `UNNOTARIZED`.

**Model downloads in the VM.** The app's real downloader fetched from a local mirror of the signed catalog's
Hugging Face files (`fa-mirror.py`, DEBUG `-DownloadHost`). This Mac's link to Hugging Face measured about 0.5 MB/s.

**Host legs (AT-FA-06, -08).** These ran on this Mac with fresh dev containers, under `gpu-run.sh shared`.
- Photo needs 16 GB and Video needs 24 GB (catalog), so neither runs on the T0 VM, and the VM's GPU is paravirtualised.
- The forced-block seam exists only in the SwiftPM test build.

| AT | Leg | Result | Form | Evidence |
|---|---|---|---|---|
| AT-FA-01 | Download → Gatekeeper | **pass** | dev: Gatekeeper on in the VM; DMG and app rejected as unnotarized; first open held behind "Apple could not verify"; Open Anyway's effect applied; runs, window, `codesign --verify --deep --strict` | `build/at/AT-FA-01/20261109-160644` |
| AT-FA-01 | — devid form | **pending M10.T10 owner steps** | notarized DMG | `make test-final PASS=release FORM=devid PREV_DMG=<N-1 dmg> DMG=<N dmg>` |
| AT-FA-02 | Onboarding | **pass** (web-search switch visual: AT-VQ-M10) | T0, Chat + Voice + Evil, real downloads (mirror), no TCC prompt | `build/at/AT-FA-02/20261109-220537` |
| AT-FA-03 | Fast first chat | **pass**: Continue → first token 23.6 s (bar 120 s) | local mirror; Hugging Face link recorded | `build/at/AT-FA-03/20261109-220537` |
| AT-FA-04 | Offline chat | **pass** (on-screen label: visual QA) | network service off in the VM; answer on chat-2b; 0 outbound rows | `build/at/AT-FA-04/20261109-212455` |
| AT-FA-05 | Dictation + voice | **pass** (3 consecutive fresh-clone runs, `fix/fa05-voice-helper`; finding 7 resolved) | dictation 3/3, WER 0.036; voice 4/4 turns transcribed and answered on chat-2b, one helper process for the whole conversation | `build/at/AT-FA-05/20261110-005124`, `…/20261110-005953`, `…/20261110-010327` (failing runs: `…/20261109-214617`, repro with crash report `…/20261109-231054`) |
| AT-FA-06 | Image, then video | **pass** (notification sub-leg host-blocked, open finding 9) | image: real Photo models, gated, 5 distinct % progress values, XMP AI mark (`…/20261109-155936/image`); video: real vid-5b 1280×704 × 121 f, gated, AI-marked MP4 | `build/at/AT-FA-06/20261109-202451`, `build/at/AT-FA-06/20261109-155936/image` |
| AT-FA-07 | Evil mode | **pass** | 18+ refusal, enable, ⇧⌘E, frame + badge, lawful answer on evil-2b, lock | `build/at/AT-FA-07/20261109-212455` (failing run before fixed item 1: `…/20261109-200910`) |
| AT-FA-08 | Safety floor | **pass** (repair-card on-screen and Release UI form pending) | forced block through the real gate (11 tests); blocked job → counter +1; detectors absent → Photo job withheld, no picture; real video → `safetyMissing`, no clip; R-241 audit | `build/at/AT-FA-08/20261109-212526` |
| AT-FA-09 | ChatGPT import | **pass** | 5 chats / 41 messages / 3 images, tagged Imported, branches kept | `build/at/AT-FA-09/20261109-212455` |
| AT-FA-10 | Crash recovery | **pass** (fixed item 7; 3 consecutive VM runs) | kill -9 mid-stream → the chat reopens, interrupted + Retry, draft kept, crash prompt (Ask), nothing sent, Retry answers; helper kill → `engine.restarted` + Retry (5.1–7.1 s in the VM) | `build/at/AT-FA-10/20261110-001455`, `…/20261110-002517`, `…/20261110-003416` (also `…/20261109-234000`, `…/20261109-231905`; failing runs before the fix: `…/20261109-220537`, `…/20261109-214617`) |
| AT-FA-11 | Relaunch keeps history | **pass** | canonical DB dump and settings equal; 10 chats shown | `build/at/AT-FA-11/20261109-212455` |
| AT-FA-12 | Update N-1 → N | **pass** | v32 user data migrated with a backup; Sparkle fetched, downloaded and installed 907 → 908; data and models unchanged; PR5 | `build/at/AT-FA-12/20261109-160644` |
| AT-FA-12 | — devid form | **pending M10.T10 owner steps** | production feed + key | as AT-FA-01 devid, plus `FEED=stable SPARKLE_KEY_FILE=…` |
| AT-FA-13 | Uninstall | **pass** (sheet's typed word: Q-015) | Debug: Uninstall action → zero files, Trash, no login item, no stray files; Release: documented manual way → zero files | `build/at/AT-FA-13/20261109-212455`, `…/20261109-160644/release-manual` |
| AT-FA-14 | Low-RAM tier | **pass** (VM, not physical hardware, D-003) | 8 GB VM → T0; journeys 1–2; peak helper footprint 2.2 GB ≤ 4.0 GB | `build/at/AT-FA-14/20261109-220537` |

### Fixed on this branch (with tests)
1. **The first Evil chat failed with `llamaNotListening`.** llama-server opens its socket only after Metal init, and
   a first launch compiles the Metal shaders. In the VM that took longer than the 10 s listen bound.
   - Fix: `LlamaServerSupervisor.Config.healthTimeout` raised to 90 s. A server that exits is still reported at once.
   - Test: `LlamaServerConfigDefaultsTests`.
2. **The copied app failed `codesign --verify --strict`.** dmgbuild's `hide_extensions` wrote `com.apple.FinderInfo`
   on the app bundle inside the DMG, and the app copied out of it failed strict verification ("detritus not allowed").
   - Fix: the setting is removed.
   - Test: `verify-dmg.sh` now checks that the app in the DMG has no xattrs and verifies `--deep --strict`.
3. **The Debug Uninstall left a folder behind.** It missed `~/Library/Caches/app.antichat.AntiChat.Engine`: the
   helpers keep the shipped ids in Debug.
   - Fix: added to `DataPaths` for Debug builds.
   - Tests: StorageTests, plus the Storage settings snapshots.
4. **`VideoGateTests.cancelDuringCheckOrEncodeWritesNothing` was stale.** The runner gained a cancel read at job
   start, so the test's flip points moved. Product behaviour was unchanged.
5. **`-DownloadHost` was parsed but never used.** It is now wired: `DownloadRequest.rewritten`, DEBUG only, with
   `DownloadHostTests`.
6. **The VM release smoke tested nothing in Gatekeeper.** The Cirrus base image ships with Gatekeeper assessments
   disabled, so the M10.T09 smoke's "accepted" lines (a696d34d3) were under `override=security disabled`.
   - Fix: the release pass now runs `spctl --global-enable` first.
   - Consequence: the devid Gatekeeper checks of AT-225/AT-FA-01 must be re-run in M10.T10.

7. **AT-FA-10: the chat did not always reopen after kill -9** (was open finding 8; reopened in 1 of 2 runs). Reopening
   relied on macOS having written the window's restorable state before the kill.
   - Fix (`fix/fa10-reopen`): `LastShownChatStore` keeps each main window's shown chat in the app's own store
     (`<container>/last-shown-chats.json`, keyed by the window's SceneStorage `windowKey`). A chat switch is written
     at once; a window becoming key is a debounced reorder. An incognito chat is never written or reopened. `running`
     stays true until a normal quit. After an unclean exit each window takes its chat back (a restored window by key,
     the first non-restored window the newest entry, leftovers open their own windows), and the partial reply shows
     as M8 specifies. Off for `-ApplePersistenceIgnoreState`, test hosts, in-memory databases, and when the user
     closes windows on quit (`NSQuitAlwaysKeepsWindows` false).
   - Tests: `LastShownChatsTests` (persistence and the launch decision). The probe records `lastShownStore` and
     `reopenedByStore`. In the VM, `make test-final PASS=debug LEGS=02,10` passed 3 consecutive times (the store
     reopened the chat in 2 of them; macOS restoration had it in the third), plus 2 earlier passing runs. One extra
     run was aborted by hand when AT-FA-02's onboarding stalled at `evil: checking` for 25 min (unrelated to this
     fix; its AT-FA-10 evidence `…/20261109-234445` is void: the kill hit the stalled onboarding app).

### Open findings
7. **AT-FA-05: the engine helper exits after some voice turns at T0 (8 GB VM).** In
   `-Bench voice-session --runs 3` (4 turns with the warm-up), every turn is transcribed and answered with speech. But
   twice the helper process went away right after the turn ("engine.restarted (XPC session invalidated)"), with no
   .ips and no jetsam line. The bench now registers the models before every session, as `VoiceSessionController`
   does, so later turns recover.
   - **Resolved on `fix/fa05-voice-helper` (2026-11-10).** It was a crash, not an exit: `SIGSEGV` in libBNNS
     (`BnnsCpuInferenceOperation`) in Kokoro's last Core ML stage, the iSTFT tail. The first run's log collection
     missed the report (it only looked at the helper's own lines); the repro run has it
     (`build/at/AT-FA-05/20261109-231054/logs/crash/`). In the VM Core ML has no GPU and no Neural Engine, so every
     Kokoro stage runs on the CPU, and the tail's `conv(x_pre [1,128,T], W [22,128,7], pad 3/3)` faults for some
     lengths T (9 of 64 English clauses on the M5 host with only the tail forced to `.cpuOnly`; deterministic per
     clause). FluidAudio keeps the tail on the GPU for this reason (#667), which only helps where a GPU exists.
     Not M3's session lifecycle, idle exit or memory pressure.
   - Fix: `KokoroTTS.load` serves the tail from its link folder with that one op rewritten in `model.mil` as seven
     shifted matmuls (`KokoroTailRewrite`; same fp32 math, ≈ 100 dB SNR against the GPU tail; the model store is
     never written). Tests: `KokoroTailRewriteTests`, and `KokoroTailCPUTests` (real models: the clauses that faulted,
     tail on the CPU and every stage on the CPU).
   - A second fault showed up once the helper stayed up: the last turn's session could end in `engine.noTerminal`.
     `VoiceSessionService.finish` sent the terminal after `session.end()` had already let the request's body return.
     `start` now sends the one terminal itself (`endOfARunningSessionSendsItsTerminalBeforeTheRequestReturns`).
   - `fa-05-voice.sh` now fails if the helper pid changes during the conversation, and `collect_logs` copies crash
     reports and the launchd / ReportCrash / kernel lines.
   - On real Macs the tail runs on the GPU, so the field exposure was mainly Macs whose Core ML has no GPU (VMs). The
     fix covers any CPU fallback.
8. Fixed on `fix/fa10-reopen` 2026-11-10: see "Fixed on this branch" item 7 (AT-FA-10 reopen).
9. **Host window probes are blocked on this Mac since about 17:00.** SwiftUI scene windows of non-activating
   (`.prohibited`, BackgroundRun) apps are never ordered in.
   - Reproduced outside AntiChat with a minimal SwiftUI WindowGroup app. A plain AppKit window orders in fine.
   - Not explained by Focus, Stage Manager, settings, the launch method or the build (binaries from 13:28 that
     passed earlier now fail too).
   - Affects the host AT-108 / AT-042 / AT-001 probes and the image half of AT-FA-06 on rerun. The image half and
     the AT-FA-08 Photo leg ran before or around it, and the VM legs are unaffected.
   - Owner action: a logout/login or reboot when no agents run, then `make test-final PASS=host` and
     `tools/at/at-108-probe.sh`.
10. **A T0 model routes "write a long story" to `create_document`.** The tool call was rejected as `tool.rejected` in
   the engine log, so the chat got no streamed story. Seen while building AT-FA-10, whose prompt now asks for
   counting. Worth a look in M9 parity.

### Sub-checks that need UI automation or visual QA
These are listed per leg in `result.json` as `pending`. Their XCUITest forms are in
`App/UITests/FinalAcceptanceTests.swift` (Q-015):
- the onboarding web-search switch;
- the on-screen `net.offline` label;
- the microphone prompt on first use;
- the Retry and S-25 anchors;
- the repair card on screen;
- the Release fail-closed form;
- the Uninstall sheet's typed word.
