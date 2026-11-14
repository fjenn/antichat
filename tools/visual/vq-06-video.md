# vq-06 — Video visual QA (M5.T14: plan card, job card, player, Library; S-12, S-19)

Runbook of AT-VQ-M5 (M5.md § M5.T14). Executed by the QA agent with the computer-use grant for AntiChat, Finder and
QuickTime Player **[perm]**; two blind scorers then score the captures on the parity rubric (S-12 ≥ 4.0 with the
NFR-VID2 hard check and "the job survives window close", S-19 ≥ 4.0, no dimension < 3; S-02 / S-11 not below their
bars) → `build/visual/<version>/parity-M5.md`. Hard checks: H4 (`$XUI -only-testing:AntiChatUITests/AccessibilityAuditTests/testVideoAndLibraryScreens`),
H5 (copy keys), H6; H3/H7 per the capture script (`tools/visual/capture.sh`).

**Setup.** dev container, Video pack + runtime at the T3 cap (real hardware), window 1440×900, light; repeat 4–8, 12, 16, 20–24 in dark and at 1180×820. `$OUT=build/visual/<version>/vq-06-video`.
Launch: `build/AntiChat.app/Contents/MacOS/AntiChat -ANTICHAT_DEV_CONTAINER <dev container> -SkipOnboarding YES`
(onboarding steps add `-ResetOnboarding YES`). Dark mode: `osascript -e 'tell app "System Events" to tell appearance
preferences to set dark mode to true'`. Captures: `screencapture -x -l <windowid> $OUT/<name>.png` (1440×900 window);
recordings: `screencapture -v -V <seconds>` (or QuickTime's screen recording) into `$OUT/<name>.mov`.
Lawful proxies only (Q-012): benign landscape / object prompts, CC0 photos with no people; blocked states through the
UI-testing build's `-ScriptedSafetyVerdict block`.

## Steps and checkpoints
1. `-FakeHardware T1`, `-ResetOnboarding YES` → onboarding step 2 → `01_video-dimmed-onboarding.png` ("Needs 24 GB memory").
2. `+` menu → `02_create-video-disabled.png` (tooltip with the reason); ask "make a video of waves" → `02b_explanation.png` (`video.notEligible` + "You can still make images.").
3. Settings → Capabilities → `03_capabilities-video-dimmed.png`.
4. Real T3: `+ → Create video` → "waves at sunset" → `04_plan-card.png` (prompt, presets, `video.plan` estimate).
5. AC power, explicit chip, estimate ≤ 5 min → record 12 s `05_countdown.mov` (`video.countdown` 10…1, then start).
6. Sound chip present on T3 Normal → `06_sound-chip.png`; in an Evil chat → `06b_no-sound-chip-evil.png`.
7. `-FakePower battery:15` → `07_battery-ask.png`; `-FakePower lowpower` → `07b_low-power-ask.png`.
8. [Change] → `08_change-presets.png`; [Cancel] → `08b_card-removed.png`.
9. `-FakeHardware T2`: during a job send a chat message → `09_gpu-busy.png` (`video.gpuBusy` + Pause video).
10. On an image result → ⋯ → Animate → `10_animate-plan.png`.
11. Attach a CC0 photo + "animate this" → `11_i2v-plan.png`.
12. Start the default job → record 60 s at 120 fps `12_job-card.mov` (elapsed, `video.stage`, real %, animated preview ≥ 160 px) → `python3 tools/frametime.py $OUT/12_job-card.mov --crop <card>`: no gap > 3 s; first preview ≤ NFR-VID2.
13. UI-testing build `-ScriptedSafetyVerdict block -UseScriptedVideoEngine …` → `13_video-blocked.png` (`media.videoBlocked`); Evil chat → `13b_video-blocked-evil.png`.
14. Result → inline player: play, scrub, loop, mute, fullscreen → `14_inline-player.png`, `14b_fullscreen.png`; Export MP4 → open in QuickTime → `14c_quicktime.png`; Finder Get Info on the MP4 → `14d_getinfo.png`.
15. Start a job, close the window (⌘W), wait 30 s, reopen from the Dock → `15_survived-close.png`.
16. Library → Videos → `16_library-videos.png` (poster, duration, sound icon).
17. `-FakeThermal critical` mid-job → `17_paused-hot.png` ([Resume]) → Resume → `17b_resumed.png`.
18. Run `tools/perf/gpu-burn --seconds 40` during a job → `18_paused-other-app.png`.
19. Stop a running job → `19_cancelled.png` (memory freed per the perf log).
20. Library grid → `20_library-grid.png`; list → `20b_library-list.png`.
21. Filters Images / Videos / Files → `21_filters.png`; search a prompt word → `21b_search.png`.
22. Item → Open chat → `22_source-chat.png`; Save As / Show in Finder → `22b_reveal.png`.
23. Delete → `23_delete-confirm.png` → file gone in Finder → `23b_deleted.png`.
24. Evil enabled: Evil items with `badge.evil` → `24_evil-badge.png`; Settings → Evil → Show Evil items off → `24b_evil-hidden.png`; new container with no items → `24c_library-empty.png`.
Each checkpoint in `findings.md`: expected, observed, IS rule (IS-8), copy key match, grid, contrast.

## Status (M5.T14)
Not run yet: needs the computer-use grant (M9.T08 owns the blind scoring). XCUITest-backed hard checks are pending
Q-015 on this Mac. The report row is AT-VQ-M5 `pending` in `docs/prd/M5-report.md`.
