# M6 close review (M6.T21, 2026-11-08)

Independent fresh-agent review, high effort (`/code-review high` plus a manual trace), read-only, of the parts the
pre-close review (`M6-review.md`, M6.T01–T13) did not cover: the code sandbox (M6.T15–T19) and edit in place (M6.T20).
The same reviewer re-checked all 21 pre-close findings: **all fixed** (two small leftovers noted under "Not changed").

Every finding below was checked against the code before fixing. "Proof" names the test that fails without the fix
(or exercises the attack) and passes with it.

## Sandbox (M6.T15–T19)

| # | Sev | Finding | Fix | Proof |
|---|---|---|---|---|
| 1 | P0 | The user's code shares the REPL process, so it can write a forged reply to the protocol pipe. The service then stopped measuring while the code kept running with no memory or wall-clock limit. | Between runs the interpreter's process group is stopped (SIGSTOP) and only continued for the next request. The next run's watchdog measures the leftover and ends it. | `FileToolsJailTests.testCodeThatOutlivesItsReplyIsFrozenAndThenKilled` (sandboxed: state T, no growth, next run killed, then fresh); `SessionPoolTests.betweenRunsTheInterpreterIsStopped` |
| 2 | P1 | A line on the protocol stream that was not the reply hit `continue` before the watchdog check, so a flood starved it. | Any line other than the run's own reply ends the session (`.crash`). The watchdog check also runs at the reply. | `testProtocolNoiseEndsTheSession` (sandboxed), `SessionPoolTests.protocolNoiseEndsTheSession` |
| 3 | P1 | Background threads ran unwatched between runs. | Same freeze as #1. | as #1 |
| 4 | P1 | ctypes `fork()` plus a double fork plus `setsid()` escaped the process group and the watchdog (the audit hook covers only the Python APIs). | The service starts Python with a bootstrap that sets RLIMIT_NPROC to 1, soft and hard, before the REPL runs. Every fork then fails with EAGAIN. The kernel checks the user's process count against the calling process's own limit, so other apps are unaffected. No runtime rebuild was needed: the bootstrap is part of the service's argv. | `testForkThroughLibcIsRefusedByTheKernel` (sandboxed: −1, EAGAIN, limit (1, 1)); `SessionPoolTests.theInterpreterCannotFork` |
| 5 | P1 | Every chat's jail lives in one service container, so code in chat A could list and read chat B's uploads. | **Fixed (lead ruling (c), A-M6-T21a (a)):** 3 slot services per variant, each its own bundle id and App Sandbox container; `FileToolsSlots` leases one slot per chat and wipes every variant the slot served (scratch verified empty, protocol v2) before a lease moves; a slot writes only its scratch folder (new sbpl deny rule: no other container path, no darwin user/temp/cache folder). Chats run in parallel up to N (T0/T1 2, T2+ 3); beyond N they wait with `sandbox.waiting`. Within a slot only the leased chat has a jail (the interim fix stays). | `FileToolsSlotTests` (sandboxed): `testAChatInOneSlotCannotReadAnotherSlotsChat` (EPERM on every path of A's slot), `testALeaseMovesOnlyAfterTheSlotIsWiped`, `testBystanderAnswersWhileTwoOtherChatsRunCode`, `testBeyondTheCapacityAChatWaitsWithTheWaitingState`; `FileToolsJailTests.testRuntimeIsReadOnlyAndWritesOutsideTheJailAreDenied` (container/darwin writes EPERM); `FileToolsSlotsTests` (leaser); release probe cross-slot rows; AT-NFR-SEC3 bystander with 2 other chats busy |
| 6 | P1 | Jails outlived deleted and incognito chats. A killed session's `in/` and `out/` stayed until reset, and nothing reset after `edit_office_file`. | A jail is deleted with its session (kill, reset, idle-out), at service launch and before the idle exit. The app resets chats that ran code when they are deleted, bulk-deleted, wiped by Evil mode or end incognito (`FileToolsClient.release`). | `SessionPoolTests.aCrashEndsTheSessionAndTheNextRunIsFresh`, `testAnotherChatsFilesAreNeverVisible` (killed run leaves no jail) |
| 7 | P2 | Two runs of the same chat could start two interpreters at once. | Runs are serialised by the per-service run lock (one chat per slot). | by construction (`runLock` held for the whole run) |
| 8 | P2 | While gated, every 2 ms slice re-read the whole process table, which could push heavy jobs into the timeout. | The process table is refreshed every 50 ms, gated or not. New processes are impossible (#4) and the group stop covers threads. | AT-NFR-SEC3 suite (memory fixture 05) in the Release proof |
| 9 | P2 | The runtime installer checked for zip-slip only after `ditto` had extracted. | A preflight reads the central directory first and refuses any absolute path, `..` component, or entry below a symlink entry. | `RuntimeInstallerTests.hostileEntriesAreRefusedBeforeExtraction` (3 cases) |
| 10 | P2 | `runScript` (M7 skills hook) escaped slashes, so `in\/name` never matched. | Python literals never escape slashes. | covered by `operationTextReachesPythonUnchanged` (same helper) |
| 11 | P2 | Re-registering `run_python` made a new idle reaper, and the old one later reset a chat that was still in use. | One shared `SessionIdleReaper`. | by construction |

## Edit in place (M6.T20)

| # | Sev | Finding | Fix | Proof |
|---|---|---|---|---|
| 12 | P1 | Every `/` in an operation value arrived in Python as `\/` (dates, formulas, "A / B"). | `pythonLiteral` never escapes slashes. | `EditOfficeFileToolTests.operationTextReachesPythonUnchanged` |
| 13 | P1 | The formatting check reported on stdout. The 64 KB cap could cut it off (fail open), and code could print a lookalike line. | The report is a file in `out/` with a per-call name. An edited file without a report is not saved. The outline is capped. | `anEditWithoutTheChecksReportIsNotSaved`; a printed lookalike is ignored (`aLossyEditIsNotSavedUnlessTheUserAskedForIt`) |
| 14 | P1 | [Re-create the file] forced the very tool its steering forbids, which looped back to the offer card. | A regenerate with `recreateSteering` neither offers nor forces `edit_office_file`. | `OfficeEditIntentTests.recreateNeverForcesTheEditTool` (fails without the fix) |
| 15 | P2 | One refusal unlocked `accept_changes` for good. | The key is cleared once a version is saved. | `aLossyEditIsNotSavedUnlessTheUserAskedForIt` |
| 16 | P1 | Formatting-only, table and header edits showed an empty change list and were refused as "identical". | The change list now includes cell font, fill and number format; docx run formatting; table cells; header and footer text. | scratch check on the fixtures (bold B2 and bold paragraph 2 are listed) |
| 17 | P1 | `paragraph: N` was aliased to `text`, so the limit was dropped. | The alias applies only to a text value. | applier check: a replace limited to paragraph 3 no longer edits elsewhere |
| 18 | P1 | replace_text without `all` replaced every match inside a run, paragraph or cell, and in the table fallback. | First occurrence only, unless `all: true`. | applier check (memo: one "the" replaced) |
| 19 | P2 | set_text with fewer lines was always refused. | The "paragraphs removed" check skips a body replaced by set_text. Merged bullets are still flagged. | applier check (pitch slide 2 → one line: saved) |
| 20 | P2 | `{Amount}` placeholders were not replaced (headers are lowercased). | Placeholders match case-insensitively. | applier check (`={Amount}*0.1` → `=D2*0.1`) |
| 21 | P2 | `_ac_value` turned '00501', 'inf' and 'nan' into numbers. | Only plain decimals become numbers. | applier check |

## Not changed
- Pre-close #17 leftover (formats that depend on the preview aren't greyed out before it renders; a failure toast is shown instead) and #19 leftover (an attachment with no message yet doesn't resolve). Both are UX polish with no data or security effect, left for M9 polish.
- #13, remaining risk: code passed through the `code` fallback runs in the same interpreter as the checker and could monkeypatch it. The impact is limited to a bad new *version*: the original upload is never modified (re-hashed after every run) and earlier versions stay.
