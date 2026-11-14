# vq-11 — Failure and edge states visual QA

Sections are added by the tasks that build each state; M2.T26 consolidates and executes them.

## Offline (M2.T03, AT-209; S-25 offline state ≥ 4.0)
1. Launch with no route: `build/AntiChat.app/Contents/MacOS/AntiChat -FakeNetwork none -ANTICHAT_DEV_CONTAINER /tmp/vq11`.
2. Capture the sidebar footer: indicator `net.offline` ("Offline — everything still works"), light + dark, 1440×900.
3. Send one message to an installed model: it answers; capture the window (no error banner, no globe chip).

## Download paused (M2.T09, AT-204 part 2, R-204 AC5)
1. `make build`; start `python3 -I tools/fixtures/range-server.py --root fixtures/downloads --fail-after 1` (every
   connection fails once tripped) and queue a fixture download (antichat-cli download … against it).
2. After three failed attempts the sidebar footer shows "Download paused — check your connection" with [Retry]
   above the StatusPill (error state "{pack} download stopped"). Reference: StatusPillSnapshotTests
   `downloads.DownloadPausedNotice-{light,dark}.png`.
3. [Retry] → the notice disappears and the download restarts at once (backoff reset).

## OOM fallback (M2.T13, AT-206 part 2, AT-NFR-R5; S-25 ≥ 4.0)
1. Debug build, `-FakeHardware t0-m1-8 -ChatModel chat-9b-q4` (B 4.0 GB, model 6.5 GB, no lighter model installed): send
   "Hello". Expect the reply slot to show `model.notEnoughMemory` + [Retry] (ErrorInline), the user message kept above it,
   nothing loaded (Activity Monitor: the helper's memory does not move). Look for: no "try anyway" anywhere; Retry
   focusable; light and dark.
2. Same, with `chat-2b` installed as the lighter fallback of the requested model (ANTICHAT_DEV_CATALOG with a `smaller`
   chain): the reply streams from the lighter model and one muted line `model.usingLighter` sits under it.
3. Settings › Capabilities › Advanced › "Allow loads above the memory budget" on → the refusal becomes a load attempt
   (only there; the default UI never offers it).
4. Media step-aside on T1 (`-FakeHardware t1-m2-16`, a scripted image job): the job card line `sched.makingRoom`
   "Making room for the Photo model…", then after the job the next message shows `status.loadingModel` while the chat
   model reloads; the composer stays typeable and the queued message sends when loaded.

## Migration from a newer version (M8.T01, AT-301; S-25 ≥ 4.0, scored in M8.T16)
1. `mkdir -p /tmp/vq11n && cp fixtures/chats/db/future-v999.sqlite /tmp/vq11n/antichat.sqlite`.
2. `build/AntiChat.app/Contents/MacOS/AntiChat -ANTICHAT_DEV_CONTAINER /tmp/vq11n -ApplePersistenceIgnoreState YES`.
3. Capture `newer-data-light` and `newer-data-dark`: one window, app icon, `storage.newerVersion`, [Quit AntiChat]
   and [Update AntiChat] (default); no sidebar. The file in /tmp/vq11n is unchanged (`shasum` before/after).
4. Tab to [Update AntiChat] (focus ring visible) → `newer-data-focus`.
5. Migration failed: same with a copy of `fixtures/chats/db/v13_artifact.sqlite` and `-MigrationFailAt <head id>`
   (DEBUG) → `migration-failed` (`storage.migrationFailed`, [Restore backup] opens the sheet).
