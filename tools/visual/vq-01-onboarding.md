# vq-01-onboarding

Visual QA runbook sections (test-strategy §5); M2.T26 consolidates and executes them.

## Disk short (S-02; M2.T09, AT-204 part 2, NFR-D2)
Launch the Debug build with `-FakeFreeDiskGB 12` and a 5 GB selection: the DiskShortSheet reads "Needs 3 GB more free
space." with [Not now] [Open Storage]; Open Storage opens Settings › Storage. Reference snapshot:
`downloads.DiskShortSheet-{light,dark}.png` (StatusPillSnapshotTests). Metered network: `-FakeNetwork expensive` with
> 1 GB queued → "This is 1.2 GB. You're on a personal hotspot. Download anyway?" [Later] [Download]
(`downloads.DownloadAskSheet-*`).

## M2.T26 capture pass (AT-VQ-M2)
`tools/visual/vq-m2.sh onboarding|main|all` — Debug build with `-VisualQAProbe`; onboarding: fresh container,
`-ResetOnboarding YES -FakeHardware t1-m2-16`, a slow loopback range-server instead of Hugging Face; main: a clone of a
real T1 container. Steps 1–4 (onboarding is always dark: Light and Dark system shots must match), install cards,
Settings › Capabilities / Advanced / Evil Mode / Storage, each under system Light and Dark at 1440×900.
Shots are taken by the runner, not the app: Screen Recording belongs to the responsible process, and an app started by
LaunchServices has none, so an in-app `screencapture -l` came out black/failed (M2.T20's intermittent result).
2026-11-04 run (28 shots, 0 black; evidence `build/at/AT-VQ-M2/`) found and fixed: Voice/Photo unticked by default on
step 2; no install card in the app (the router had no embedder: the app's engine is EngineSupervisorClient); action
bar under a bare card; "fp16 · — context" and a 4-pt inset mismatch in Advanced; stale Storage placeholder copy.
