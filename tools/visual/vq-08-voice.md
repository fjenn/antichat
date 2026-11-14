# vq-08-voice — AT-VQ-M3 runbook (M3.T14)

Copied from `docs/prd/M3.md` §M3.T14. Computer-use legs wait for Q-021 (no automation grant on this Mac); the
captures this milestone takes now come from `tools/visual/vq-m3.sh` (in-app `-VisualQAProbe voice`, window shots
taken by the runner at 1440×900, system Light and Dark) — see the M3 report for which checkpoints they cover.

Setup: fresh dev container (`-ANTICHAT_DEV_CONTAINER /tmp/ac-vq08`), Voice pack ready at T1 cap, window 1440×900, light mode; repeat steps 4–22 in dark mode and at 1180×820. `$OUT=build/visual/<version>/vq-08-voice`.
1. `tccutil reset Microphone app.antichat.AntiChat`; click Mic → capture `$OUT/01_permission-sheet.png` (S-24; `voice.permission`).
2. Deny in the system dialog → capture `02_denied-popover.png` (`voice.denied`, [Open System Settings]); click it → System Settings Privacy → Microphone opens (capture `03_system-settings.png`); grant.
3. Relaunch with `-FakeAudioDevices none` → capture `04_no-device.png` (`voice.noDevice`).
4. Hover Mic for 1 s (warm-up), click → capture `05_dictation-recording.png` within 150 ms (S-17: × · waveform · elapsed · ■ · ↑).
5. Relaunch with `-UseScriptedVoice fixtures/voice/scripts/dictation-q01.jsonl` (or, if BlackHole is installed, play `dictation/q01.wav` into it with the device selected) → record 10 s at 120 fps `06_partials.mov` (grey partials appear, NFR-V6).
6. ■ → capture `07_review.png` (final text in the composer, editable).
7. Mic → ↑ send-now → capture `08_sent.png` (user bubble).
8. Mic → play `silence-5s.wav` → ■ → capture `09_silence-empty.png` (empty composer, no error).
9. Settings → Voice → Recent recordings → capture `10_recordings.png`; delete one → `11_recording-deleted.png`.
10. Relaunch with `-FakePackState voice=absent` → Mic → capture `12_basic-voice.png` (`voice.basic`); read aloud → `13_basic-readaloud.png`.
11. Attach `fixtures/audio/formats/clip.m4a` → capture `14_transcribing-tile.png` (`status.transcribing` with %) and `15_transcript-tile.png`.
12. On an assistant reply with a code block, click Read aloud → record 6 s `16_readaloud.mov` (spinner → ‖ in place → stop on second click).
13. Settings → Voice: capture each row `17_settings-voice.png`, Microphone popup `18_mic-list.png`, Preview a voice (3 s) `19_preview.png`.
14. Click Voice → capture `20_connecting.png`, then `21_listening.png`.
15. Ask `dictation/q02.wav` → record 20 s `22_conversation.mov` (thinking → speaking, captions, assistant text streaming).
16. During speech, inject `barge-in/item03-room1-user.wav` (ScriptedVoice script `conversation-bargein.jsonl`) → record at 120 fps `23_bargein.mov` → `python3 -I tools/frametime.py $OUT/23_bargein.mov --json $OUT/23_bargein.json` (orb snap) and the `voice.bargeOnset`→`tts.silent` signposts (loopback recorder only if BlackHole is installed) → orb snap and TTS silence ≤ 200 ms.
17. Mute mic → `24_mic-muted.png`; mute speaker → `25_speaker-muted.png`.
18. Type a message during the session → `26_typing-during-call.png` (reply spoken).
19. Hide AntiChat (⌘H), ask a question, capture the menu bar `27_menubar-indicator.png`; unhide → `28_background-reply.png`.
20. Unplug/disable the input device (`-FakeAudioDevices drop-after=5s`) → `29_mic-lost.png`.
21. End → `30_ended.png` (indicator gone).
22. Repeat 14–15 in an Evil chat (`31_evil-call.png`, badge + frame visible) and an Incognito chat (`32_incognito-call.png`).
23. `afplay fixtures/audio/music/bed-60s.wav` at 50% volume, start a session → `tools/voice/ducking-check.sh` level log `33_ducking.json` (setting on and off; M3.T12 AC3).
24. Relaunch with `-FakeAEC unavailable` → `34_half-duplex-hint.png` (`voice.headphones`).
25. Enable the scripted web-search tool, ask by voice → `35_tool-in-voice.png` (ActivityLine in the thread); scripted create_image → `36_spoken-pointer.png`.
Each checkpoint lists in `findings.md`: expected state, observed, IS rule, copy key match (OCR vs copy-deck), grid check (`tools/visual/grid.py`), contrast (`tools/visual/contrast-sampler.py` on the orb backdrop).
