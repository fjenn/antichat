# M3 card: voice (dictation, basic voice, languages, files, TTS, conversation)

Read `BUILD-BRIEF.md` first, then this card, then only your task sections in `M3.md`. This card doesn't repeat task steps. Where it and `M3.md` disagree on a repo fact, the card is right (checked against the tree on 2026-11-04, integration/m0 = `420d5ff7`).

## What M3 delivers
Dictation into the composer (Parakeet on the ANE, live partials, recent recordings), Basic voice (SpeechAnalyzer + AVSpeechSynthesizer) before the Voice pack lands, WhisperKit routing for languages outside Parakeet's 25, audio-file transcription with a real %, Kokoro read aloud, Settings › Voice, and the hands-free voice conversation (VPIO full duplex, Silero + EOU + smart-turn, barge-in with spoken-span truncation, echo cancellation, tools during voice).
**Exit:** `M3.md` header "Exit" row, read through the D-026 verification scope below. Journey 11 must pass with ScriptedVoice.

## Order (chunks, BUILD-ORDER.md)
[T01 T15 T02 T03 T04 T05 T06] → [T07 T08 T09 T10 T11 T12 T13 T14]. T15 (fixtures) runs right after T01 and before T03.
Dependencies: T01 → T15 → T03 · T02 → T03 → T04, T05 → T06 · T03 + T07 → T09 → T10 → T11 → T12, T13 → T14.

## D-026 moves and slims that touch M3
- **Built after M6, M7 and M8 core.** The `M3.md` "Entry: M2 exit" ordering is superseded; M6 intake, M7 search/MCP and the M8 migrator/backups (M8.T01) exist.
- **Note 2: M3.T06 closes the M6 audio leg.** Once `TranscribeFile` exists, re-run on the M6 intake: AT-020 audio leg (M4A upload → transcript) and the M4A column of AT-277 (8 cells; 56/64 → 64/64 except Show in Library, which stays with M5.T13). Until then M4A/WAV/MP3 tiles show transcription `pending`. Minor amendment, note it in the commit body.
- **Note 5: AT-057 real-tools re-run is in M3.T14** (moved from M7.T16): `VoiceToolsTests/testSearchDuringVoice` + `testConnectionDuringVoice` against `-SearchFixtureServer` (M7.T01) and `tools/mcp-ref/` (M7.T06).
- **Note 7:** M8.T08 (Privacy page) consumes the permission service vendored in M3.T02; keep `PermissionCenter` generic (microphone, accessibility, notifications, screen recording). M8.T12–T14 (voice/job events) come after M3.
- **M8.T14 global dictation ("dictate in any app", R-051) is in M11 (A9).** Nothing in M3 builds a global hotkey, `TextInserter` or `DictationMiniIndicator`.
- **Voice pack not shipped yet:** `ModelPack.shipped = [.chat]` (`Platform/Catalog/Selection.swift`). Add `.voice` only when M3 closes (T14), not before. Until then tests use `-FakeVoiceInstalled` / `-FakeInstalledPacks` (they exist) and the M3 hooks below.
- **Verification scope (D-025), T14:** keeps every M3 AT, offline journeys 2 + 11, vq-08 captures, hard checks barge-in ≤ 200 ms and V1, headline **V1, V3, V5 at T1**. Moves to M9.T05: T3/T0/S-scaled repeats of V1–V11, U2/U5/C1/R1/R4 re-runs; to M9.T08: blind scoring of S-16/S-17. Still required: `make test-unit` + `make audit`, independent `/code-review` (high), running-app check, 1440×900 light+dark captures with H3–H7. Per-task NFR ATs run at their primary tier (T1) only; "and `TIER=T3`/`T0`" legs in T03–T12 are M9.T05 work.

## Repo reality (the PRD text is older than the code)
- **M0.T05 spike code exists; replace, don't duplicate.** `EngineProtocol/Voice.swift` (`VoiceRequest`/`VoiceTurnReport`, `ClientMessage.voice`), `Engines/Voice/{SpikeVoiceSession, CaptureVPIO, Endpointing, VoiceEnvironment}.swift`, `STT/ParakeetSTT.swift`, `TTS/{KokoroTTS, SystemTTS}.swift`, `EngineCore.runVoice` in `EngineHost/EngineListener.swift`, `-Bench voice` in `App/AntiChat/BenchMode.swift`. Keep the bench lane working (AT-M0-05 / V1 probe) until T09–T11 supersede it.
- **`EngineEvent` is the closed seven-event R-229 contract.** Voice events travel as their own `StreamItem.voice(VoiceEvent)` (like `.lifecycle` / `.media`), not as new `EngineEvent` cases. Protocol version is 6 (M6.T03); M3.T01 bumps it (expect renumbering at merge).
- **Already vendored:** `SpeechSwiftVendored` target = `FullDuplexAudioIO.swift` + `SmartTurn.swift` (UP-SS-001…003); osaurus allow-list already has `SystemPermission.swift`, `SystemPermissionService.swift`, `MarkdownStripper.swift` (`TTSService.swift` is `watch`). T01 adds `StreamingVADProcessor`/`Configuration`/`Protocols`/`CoreMLLoader` and agent-squad `PlaybackClock`; T02 only adds the trim + `PermissionCenter`.
- **Pins:** FluidAudio 0.18.0 and ORT 1.24.2 (via `Packages/ChildSafetyCheck`) are resolved; `argmax-oss-swift` 1.1.1 is a `"when": "present"` row in `tools/ci/pins.json`. Xcode builds use `-disableAutomaticPackageResolution`: update both `Package.resolved` and `AntiChat.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
- **Catalog:** `models.yaml` has `stt, stt-eou, tts, vad-files, turn` (ONNX); no `stt-fb`, `stt-multi`, `tts-stream`. `turn` has role `vad`. The M0 model store already holds `turn/coreml` (= `aufklarer/Smart-Turn-v3.2-CoreML@75f0697`, `tools/dev/models-m0.json`), so A-M3-01 formalises what M0 used. `ResidencyRole` has `.stt`/`.tts` only (voice pack); `ResidencyRole(catalogRole: "vad")` = `.tts`.
- **TCC (AT-M0-05):** the prompt names "AntiChat" with helper capture, one Settings entry. **Capture stays in the helper**; the helper keeps `com.apple.security.device.audio-input`.
- **Migrations:** one file, `Storage/Database/Migrations.swift` (`… v14_files_m6`; M8 adds more in parallel). Name M3's distinctively (`v<N>_voice_recording`), append-only, expect renumbering.
- **Fixtures:** `fixtures/audio/` has only `librispeech-test-clean-200/` (200 FLAC) plus `SOURCES.md` stubs for `dictation, fleurs-multi, turn-split-50, barge-in, long-file, noise`; no `music/`, `formats/`, `fixtures/voice/`. T15 fills them.
- **UI:** `Composer/ComposerView.swift` has a `MicButton` that shows the Voice install card (`micInstallCard`) and sends `voiceHover()` warm-up hints (M2.T15); `Settings/Sections/VoiceSection.swift` exists (stub). Launch args in `Foundation/Debug/LaunchOptions.swift` (`TestHooks.swift` doesn't exist).
- **Strings:** `App/AntiChat/Localizable.xcstrings` + `copy-deck.md` §7 in the same commit, then `tools/ci/copy-sync.py`.
- **XCUITest can't start here (Q-015):** write the UI test, run the in-process probe path, record the XCUITest leg `pending (Q-015)`. Computer-use legs pending (Q-021). BlackHole needs P-ADMIN: probe `sudo -n true` once, never ask.
- **No live mic or speakers in tests:** ScriptedVoice / pre-recorded WAVs, mode `inject` `[IN-PIPELINE]`. Only AT-280 AC1 (T12) plays aloud, unattended, in T14.
- **Compute placement:** STT/TTS on the ANE (Core ML), VAD/turn on CPU/ANE (`MLModelConfiguration.computeUnits` set explicitly); nothing voice-side touches the GPU, which stays with chat decode (K-NEW-ENG-10).
- Host is shared and loaded: note `uptime` load next to every timing number. Model runs go through `/Users/armando/AntiChat-tools/gpu-run.sh`: `timing --` for latency/throughput/memory numbers (exclusive), `shared --` for accuracy-only runs; never wrap builds or `make test-unit`.

## Per-task essentials (chunk 14; chunk 15: read the task)
- **T01** pins (WhisperKit 1.1.1 `1bbc57c`, ORT 1.24.2 `b7fb7f7`), vendor the rest of P-media-03/-04, `Voice/VoiceMessages.swift` (8 messages, `VoiceEvent`), helper `VoiceService` actor routing to `STTService`/`TTSService` stubs, voice model roles → `ResidencyRole`, `turn-coreml` slot + A-M3-01. Checks: `VoiceMessagesCodableTests`, `VoiceServiceRoutingTests` (unknown → `voice.unsupported`), `make pins-verify`, `make audit`.
- **T15** `tools/fixtures/make-voice-fixtures.py` (`--seed 20261030`, `verify`), `rir.py`; folders dictation (30), fleurs-multi de/ja/zh/ar (40 each), turn-split-50, barge-in (36, Kokoro stems), long-file (60 min, A-M3-05), noise, music. 16 kHz mono 16-bit except music. Lock + push the fixtures repo.
- **T02** `PermissionCenter` (status/request/openSystemSettings, re-check on activation, `-FakePermission microphone=…`), `PermissionPromptSheet`, `PermissionDeniedPopover`, no-device state, `NSMicrophoneUsageDescription` in app + helper plists. Checks: `PermissionCenterTests`, snapshots; `PermissionJITTests` pending (Q-015).
- **T03 / AT-050, V5–V7, V10** `SpeechBackend`, `ParakeetBackend` (CAS path, offline), `ScriptedVoice`, `DictationBar`, recordings table (keep 20, never in incognito). T1 only for perf.
- **T04 / AT-281** `TTSBackend`, `SpeechAnalyzerBackend`, `SystemVoiceBackend`, `VoiceBackendSelector` (choose per session, never switch mid-session), `voice.basic`.
- **T05 / AT-284, V9** `LanguageRouter`, `WhisperKitBackend` (`stt-multi` catalog slot, on demand), `tools/voice/wer.py` (CER for ja/zh, A-M3-02).
- **T06 / AT-056, V11** `AudioIntakeAdapter` on the M6 intake, `FileTranscriber` (`transcribeDiskBacked`, real %), transcript attachment; then re-run AT-020 audio + AT-277 M4A column (note 2). V11 n = 3 (A-M3-03).

## Cross-task contracts
1. **Helper owns audio.** Capture, VAD, STT, TTS and playback run in `AntiChatEngine.xpc`; the app sends `VoiceMessages` and renders `VoiceEvent`s.
2. **Every model loads from the CAS / model store path** with `ModelHub.offlineMode = true` set before any FluidAudio call (D-11); WhisperKit with `download: false`. No voice byte through the network.
3. **Incognito:** no recording rows, no audio files, no transcripts on disk.
4. **No filtering** besides `ChildSafetyCheck` (D-006): nothing in STT, TTS, captions or transcripts; zero ChildSafetyCheck invocations in voice paths (r241 audit).
5. **One session, one backend:** the backend (Parakeet/Kokoro vs Basic) is chosen at session start and never switched mid-session.

## Pins and IDs to grep
FluidAudio 0.18.0 `b6a8b39`, speech-swift `d53bcb3`, agent-squad `729d5f5`, argmax-oss-swift 1.1.1 `1bbc57c`, ORT 1.24.2 `b7fb7f7`, `aufklarer/Smart-Turn-v3.2-CoreML@75f0697`, whisperkit-coreml `0f63a78`; P-media-02…05, -14, P-shell-20; screens S-16, S-17, S-21, S-24; IS-9, IS-10; NFR-V1…V11; AT-M0-05; K-NEW-ENG-10, K-NEW-ARCH-5; A-M3-01…05; Q-015, Q-021; D-006, D-010, D-025, D-026.

## Close-out progress / handoff (2026-11-08 18:30, voice track agent 2)
State: `m3/voice` @ HEAD (see `git log`), main e42646cb merged (`9c610535`). Report: `docs/prd/M3-report.md`.
- Done: NFR-V1 met at T1 (timing, load 5–11: p50 1.203 s, p95 2.022 s; A-M3-T09c, 5-word first chunk, 1.2 s finished-sentence cap with V4 re-run 0/1/0/0); T12 (`97ff56fa`), T13 (`afb07dcf`); independent review, 12 findings fixed (`4f1bae04`); `.voice` shipped; running-app check + 18 captures (`tools/visual/vq-m3.sh`); gates green on the merge (test-unit, integration-stub, audit). Fixtures: bare repo branch `m3/voice` (4f2f849, merges main's 63457bc); push to fixtures main only after the code is on main.
- Lead decisions 2026-11-08 18:00: AT-280 AC1 bar stays, method changed (A-M3-T12b, `docs/prd/M3-owner-steps.md`, `--source owner|remote`, `d61a72a1`); AT-282 AC2 must be ≥ 35/36; AC3 re-run; gates on the final head, then READY.
- AT-282 analysis: `BargeInFixtureTests` now writes per-item traces (played, chunk table, word starts, heard text) into `build/at/AT-282/spans.json`; `scratchpad/m3v/span_an.py <spans.json>` replays the span rule offline for thresholds f (0 = word start, 0.5 = midpoint) and word-start shifts, to pick a rule without more GPU runs. Queued run (shared) and AC3 ducking re-run were waiting on GPU slots at 19:10.
- 2026-11-09 state: AT-282 36/36 (A-M3-T10b aligned reference; span rule back to word starts, `91cc038e`); AT-280 AC1 method A-M3-T12b (owner steps doc, `--source owner|remote`), the answered-count run is an owner step; AT-280 AC3: on-leg 0.5 dB with min ducking; the off leg's mic probe lost the microphone to VPIO (invalid), ducking re-applied after engine start (`0b3b32ab`); a clean off-leg re-run is still to do.
- Env notes: `tools/mcp-ref` needs `npm ci --ignore-scripts`; integration FileTools needs `make runtime-filetools SIGN=1` (it rewrites `catalog/runtimes.yaml` locally — do not commit that). GPU shared slots are contended (AT-250 runs for hours); keep timing runs free of your own CPU load.
