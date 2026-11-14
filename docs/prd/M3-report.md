# M3 report — Voice (close-out, M3.T14)

**Date:** 2026-11-08 · **Branch:** `m3/voice` (worktree `m3-voice`) · **Host:** MacBook Pro M5 Max 128 GB, macOS 26.6.2, shared with 4–5 build tracks (load noted per number).
**Verdict:** see §5.

## 1. Tasks

| Task | Commit(s) | Notes |
|---|---|---|
| T01–T11, T15 | on the branch before 2026-11-08 (see `git log`) | A-M3-01…06, A-M3-T01a…T11a |
| NFR-V1 work | `6179c7a1` speculative generation + first-chunk presynthesis; `4f1bae04` first chunk after 5 words | A-M3-T09b, **A-M3-T09c** |
| T12 echo cancellation, half duplex, ducking | `97ff56fa` | **A-M3-T12a** |
| T13 tools during voice | `afb07dcf` | **A-M3-T13a** |
| T14 close | `4f1bae04` (review fixes, `.voice` shipped), `9c4cb706` (running-app fix), `fe22fa97` (AT-282 span) | this report |

## 2. Acceptance tests

| AT | Result | Artefact | Notes |
|---|---|---|---|
| AT-050 dictation | pass (in-process) | `build/at/AT-050/` | XCUITest legs pending (Q-015) |
| AT-052 conversation | in-process pass; V1 see §3 | `VoiceSessionTests`, `VoiceSessionControllerTests`, `-Bench voice-session` raws | XCUITest pending (Q-015) |
| AT-053 Settings › Voice | pass + captures | `build/at/AT-053/`, `build/visual/4f1bae047-dirty/vq-m3/voice/settings-voice-*.png` | |
| AT-054 read aloud | pass | `build/at/AT-054/` | V8 |
| AT-056 audio files | pass | `build/at/AT-056/` | V11 n = 3 (A-M3-03) |
| AT-057 tools during voice | in-process pass | `VoiceToolsTests` | XCUITest `VoiceToolsTests` pending (Q-015) |
| AT-280 echo / half duplex / ducking | AC2 **pass** (in-process); AC3 see §4; AC1: 0 self-interruptions (same-speaker run), answered-count run = owner step (A-M3-T12b, `docs/prd/M3-owner-steps.md`) | `HalfDuplexPolicyTests`, `build/at/AT-280/` | owner step |
| AT-281 Basic voice | pass | `build/at/AT-281/` | |
| AT-282 barge-in | **pass 36/36** (AC1, AC2 with the aligned reference A-M3-T10b, AC3; V3 silent p50 26.7 ms, cancel p50 255.5 ms; timing, load 7–15) | `build/at/AT-282/spans.json`, `v3.json`, `result.json` | |
| AT-283 end of turn / V4 | **pass** (re-run 2026-11-08 after the review fixes: false splits clean 0, cafe 1, fan 0, keyboard 0 of 50; bar ≤ 1) | `build/at/AT-283/turn-split*.json` | |
| AT-284 language routing | pass except ar / zh (accepted, A-M3-06) | `build/at/AT-284/` | |

## 3. Headline numbers (T1)

| NFR | Bar (T1) | Result | Load | Artefact |
|---|---|---|---|---|
| **V1** voice round trip p50 | ≤ 1.5 s | **1.203 s** (n = 20, gpu-run timing, inject [IN-PIPELINE]) | 5–11 | `build/perf/raw/m1/V1-T1-20261108T163500Z-final.jsonl`, `report.json metrics.V1.T1` |
| **V1b** p95 | ≤ 2.5 s | **2.022 s** | 5–11 | same run |
| V2 stages p50 (same run) | (T3 budget) | endpointing 982 ms · STT final 0.4 ms · TTFT 0.6 ms · first clause 1.7 ms · TTS first chunk 92 ms · audio out 0.4 ms (the reply is speculated and its first chunk presynthesised during the endpointing wait) | 5–11 | `metrics.V2.T1/*` |
| **V3** barge-in: onset → TTS silent p50 | ≤ 200 ms | 25.9 ms (p95 60.3); onset → generation cancelled p50 256 ms (bar ≤ 300) | 14–23 | `build/at/AT-282/v3.json` (2026-11-08 run; re-run see §4) |
| **V5** mic click → DictationBar p50 | ≤ 150 ms | 10.3 ms (p95 13.2, in-process) | noisy | `metrics.V5.T1` |
| V4 false turn splits | ≤ 1 of 50 per condition | clean 0 · cafe 1 · fan 0 · keyboard 0 (after the 1.2 s cap) | — | `build/at/AT-283/turn-split*.json` |

Earlier timing runs of the day (same harness): before the work 2.17 / 3.71 s; speculation (8-word chunk) 1.502 / 2.09 s; with the 5-word chunk under my own test load 1.494 / 2.07 s; final (1.2 s cap, quiet host) 1.203 / 2.022 s.

## 4. Physical and real-model runs

**AT-280 AC1 (built-in speakers, unattended).** Harness `tools/voice/aec-10min.sh` → `AntiChat -Bench aec` (live VPIO session, chat-9b-q4 replies, questions by `afplay` on the same speakers). Run 1 (10 min, volume 70 %, ambient −63 dBFS): 20 questions played, **0 self-interruptions**, but **0 answered**. Diagnostic run (2 min, levels logged): VPIO's processed input peaked at −36 dBFS while the questions played (1 of 2 902 frames over −40 dBFS); one question got through and was answered. The music check shows VPIO does not duck other audio at `.min` (−35.1 → −34.4 dBFS), so the questions are attenuated by VPIO's echo/noise processing itself: on macOS the voice-processing unit treats sound played by *any* app on the same output as echo. The card's premise (afplay is outside the echo reference) does not hold, so "≥ 18/20 answered" cannot be measured with one output device; a second output device or a person speaking is needed (the card's own failure mode "No second output device"). The 0-self-interruption half of AC1 holds. A louder-question run (`--question-volume 4`) was queued but could not get a GPU slot before hand-off. **Lead decision needed.**

**AT-280 AC3** (`tools/voice/ducking-check.sh`, 60 s windows = one loop of the music bed, build `0b3b32ab`): setting on — music before −35.9 dBFS, during −36.4 dBFS (**drop 0.5 dB**), `ducking_applied: "min"`. Setting off — the plain-tap probe read −59.6 dBFS during the session while the session's own VPIO input heard the music at up to −7 dBFS, i.e. the probe lost the microphone to the voice-processing session for that leg (an artefact of measuring with a second input client, not ducking); this leg is not valid. On speakers the setting does not change the audio path (A-M3-T12a: off = VPIO at `.min`, the same as on; `ducking_applied: "min"` in both legs), so the 0.5 dB measured with the setting on stands for both; a clean off-leg re-run is still to do (`tools/voice/ducking-check.sh`; a measurement that does not share the microphone — a loopback device — needs P-ADMIN). The 20 s windows of the first runs differed by up to 9 dB between loop positions; one run measured −21 dB with the minimum ducking applied only before the engine start, so UP-SS-008 now applies it again after the start (`0b3b32ab`).

**AT-282 (BargeInFixtureTests, gpu-run timing, 2026-11-08 23:20, load 7–15): pass 36/36.** The two-to-five-word misses of the earlier runs were in the reference: Parakeet's transcript of audio cut mid-word goes on with words never played ("…two meetings this aftern|" → "…This afternoon is a very"). The reference now counts the reply words the played audio contains (A-M3-T10b); the span rule is back to word starts (replayed offline on the per-stop traces: 36/36, half-word rule 35/36).

**V4 / AT-283** re-run after every end-of-turn change: pass (above).

## 5. Close-out

- `.voice` is in `ModelPack.shipped` (Settings › Capabilities shows Voice installable; snapshots re-recorded).
- Independent review (separate agent, high): 12 findings (1 P0, 6 P1, 5 P2), all fixed in `4f1bae04`.
- Running-app check: `tools/visual/vq-m3.sh` launched the Debug app and walked the voice overlay states and Settings › Voice; it found a real crash (Settings › Voice level meter trapped on the audio thread), fixed in `9c4cb706` (main fixed the same independently; main's version kept at the merge). 18 window captures, 1440×900, light + dark: `build/visual/4f1bae047-dirty/vq-m3/voice/`.
- Gates on the merged branch (main e42646cb): `make test-unit` exit 0 (9c610535), `make test-integration-stub` exit 0, `BINARIES_SRC=$HOME/AntiChat/Binaries make audit` exit 0 (6b856f79; `l10n-langs` is report-only).
- AT-280 AC1: lead decision 2026-11-08 — bar unchanged, method changed (A-M3-T12b): the answered-count run needs the owner (live questions) or a second device; steps in `docs/prd/M3-owner-steps.md`.

## 6. Independent close review (D-025), 2026-11-09
`docs/prd/reviews/M3-review.md`: 2 P0, 6 P1, 8 P2, all confirmed and fixed on `fix/m3-review` (merged to main `fb7ef3949`), each with a Resolution line and a test; real-pipeline spoken approval `-Bench voice-approval` passes in full and half duplex. Re-runs after the fixes: AT-282 36/36 (V3 silent p50 32.7 ms, cancel p50 260.9 ms), V1 T1 p50 1.037 s / p95 2.021 s (load 18). New vendored patch UP-SS-009.

