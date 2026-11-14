# M8 independent code review (M8.T16 step 5)

**What was reviewed:** integration/m0 @ d027444aa, every M8 commit (T01–T14). A fresh agent did the review
read-only, at high effort. Two sub-reviewers covered T04–T07 and T09/T12–T14; the main reviewer checked the serious
findings again in the code.

**Triage:** 25 findings. All 25 were confirmed and fixed in the same commit. "Verified" means the reviewer re-read the
code behind the finding.

| # | Sev | Area | Finding | Fix |
|---|---|---|---|---|
| 1 | S0 | Relaunch (restore, Remove everything) | The new instance started before the old one quit. The old one could still check-point the swapped database or write files into the removed container. A quit guard could stop the old one from quitting at all. | The new instance waits (≤ 60 s) for the old PID to exit before it opens anything (`AppRelaunch.waitForPredecessorIfRelaunched`, first line of `Entry.main`). The quit skips the guards (`AppRelaunch.inProgress`). After Remove everything the new instance deletes the documented paths once more. |
| 2 | S0 | `BackupService.applyStagedRestore` | The marker was deleted even when the restore failed. A corrupt live DB broke the pre-restore copy. The live file was deleted before the backup copy existed. | The marker is removed only on success. A database that cannot be opened is saved as raw files. The backup is copied to a staging file that atomically replaces the live one; WAL/SHM are removed afterwards. Test: `restoreSurvivesACorruptLiveDatabaseAndKeepsAFailedRequest`. |
| 3 | S0 | `AntiChatImporter` media | A crafted `sha256` / extension in `media/blobs.json` could write outside Media. | The name must match `^[0-9a-f]{64}$`, the extension `^[a-z0-9]{1,8}$`, and the path must stay inside Media. The file is extracted to a temp file and kept only if its bytes hash to the name. Test: `importerAcceptsOnlyRealSHA256Names`. |
| 4 | S0/S1 | Export: two project files with the same name | The `blob.prefix(8)` suffix collided (UUIDv7), so the second file got the first file's bytes on import. | A counter suffix, checked against the names already used. |
| 5 | S1 | Log bundle | Continuation lines of a multi-line content entry went into Export logs with content off. | `AppLog.content` writes one line (newlines escaped). `LogBundleBuilder.tail` drops the continuation lines of older logs too. Test: `multiLineContentEntryIsDroppedWhole`. |
| 6 | S1 | Quit → Wait | Could hang forever when the end notification waited on an explainer that no window could show. | The job list is updated first. A held quit waits ≤ 5 s for the notification. The explainer counts as Not now when no main window is on screen. Subscribers use tokens. |
| 7 | S1 | Remove everything: `cancelJobs` | Only downloads were cancelled. | Also picture/video jobs (`cancelForQuit`) and the linked-folder watchers. |
| 8 | S1 | Uninstall | When the waiter failed, the app still went to the Trash with the data left behind. | The app stays and shows `uninstall.failed` (new copy key). |
| 9 | S1 | Importing an AntiChat export with projects | Files came back as `ready` with no chunks or text. | Imported as `pending`. Copied files are re-indexed from their blobs (`reindexPending`, after the import and at launch); linked ones at the next rescan. |
| 10 | S1 | Manage memories | Project-scoped memories were not listed. | `MemoryStore.allActive()`, grouped by scope and project. |
| 11 | S2 | Reset memory | Pending suggestions and frozen per-chat snapshots kept memory text. | Both are cleared (A-M8-T16a a). |
| 12 | S2 | Memory review | The busy gate ignored media jobs. Chats with project-only memory became global suggestions. | `MediaJobQueue.hasRunning` added to the gate. Project-only chats are left out. |
| 13 | S2 | Projects | Extracted text stayed on disk after a file or project was removed. | Removed with the file or project. |
| 14 | S2 | Diagnostics | Building the log bundle on the main thread caused a beachball. | Built in a detached task. Regexes compiled once. FileVault status read once per launch. |
| 15 | S2 | Notifications | An incognito click routed a chat id to a normal window. | Incognito notifications carry no id; a click only brings the app forward (A-M8-T16a c). |
| 16 | S2 | Debug Remove everything / Uninstall | Deleted Release data (shared caches, Keychain). | `DataPaths.keepsReleaseShared` when Release data exists (A-M8-T16a b). |
| 17 | S2 | Menu bar | A background test run's `isVisible = false` was saved under the default autosave name. | Separate autosave names for test runs, and `isVisible` is always set. |
| 18 | S2 | Quick panel ⌘O | A window that already showed the chat kept its stale model. | `adopt` replaces it with the live model. |
| 19 | S2 | Quick panel unread | A reply finishing while the panel was hidden got no unread dot. | The headless sessions' current chat is cleared while the panel is hidden. |
| 20 | S2 | Project file races | Concurrent adds overshot the limit. Rescans overlapped. | Admit and insert happen in one transaction. One rescan at a time per project. |
| 21 | S2 | Export Markdown names and links | Names collided, and links pointed at media missing from the zip. | Full chat id in the name, a counter for memory topics, and links only to entries the zip holds (`PictureStyle.exportEntries`). |
| 22 | S2 | `LinkedFolderWatcher.stop` | Possible use-after-free. | The stream is torn down on its own callback queue. |
| 23 | S2 | Import events | `.finished` could be dropped from a bounded stream. | Unbounded stream. |
| 24 | S2 | Location | Every app activation created a CoreLocation manager. | The coordinator no longer refreshes location on activation; LocationPermission creates the manager only when the location setting is opened. |
| 25 | S2 | Report a problem (GitHub path) | The issue said the log bundle was attached, but nothing showed the user where it was. | The zip is revealed in Finder. |
| – | minor | Memory vectors | Edits, added facts and saved suggestions had no vector until ⌘K ran the backlog. | `MemorySettingsViewModel.fillVectors()` after each of those. |

**Reviewed with no findings:** T01 migrations (guard, backup, migrate, rollback, renumbering, daily gating); memory
gating; FileProtection; ModelsFolderMover; CleanupPlanner; the uninstall waiter's quoting; import
streaming, dedup and caps; project context; share export escaping; the notification policy table and incognito text;
crash reports (nothing sent without a tap); global shortcuts in background runs; the PermissionCoordinator flow; quit
ordering.
