# M8 report: memory, projects, import/export, privacy, storage, diagnostics, Mac integration (M8.T16)

**Date:** 2026-11-08 · **Branch:** `integration/m0` (READY for the lead's merge round; the earlier READY sha
`d027444aa` covered T12–T14) · **Host:** MacBook Pro M5 Max 128 GB, macOS 26.6.2, a shared Mac with 4–5 tracks
running (load 15–250).

**Verdict: M8 exit is conditional.** Every AT that can run without the owner passes on the final build. This includes
the Tart install suite (AT-226, AT-NFR-D7), the PR3 and S2 re-runs, and all 25 findings of the independent review. The
remaining open items need an owner grant: XCUITest automation mode (Q-015), computer use for AT-VQ-M8, and one real
notification and permission-dialog pass. They are listed in [`M8-owner-steps.md`](M8-owner-steps.md). The README row
stays `in progress` until those steps have run.

## 1. Acceptance tests

| AT | What | Result | Artefact | Notes / amendment |
|---|---|---|---|---|
| AT-301 | Migrations: backup, guard, restore | pass | `build/at/AT-301/2026-11-08.log` | A-M8-T01a; `MigrationUITests` pending (Q-015) |
| AT-242 / AT-243 | Memory core (real model) | pass (paraphrase update 0.98, distinct add 1.00) | `build/at/AT-242/2026-11-04.json` | A-M8-T02a |
| AT-060 / AT-246 | Memory UI, review suggestions | pass (unit and host) | `make test-unit FILTER=MemoryViewModelTests,MemoryReviewServiceTests` | A-M8-T03a; visual QA → AT-VQ-M8 |
| AT-064 | Projects | pass (unit) | `make test-unit FILTER=ProjectStoreTests,ProjectFileIndexerTests,ProjectLayerTests` | A-M8-T04a; `ProjectsUITests` pending (Q-015) |
| AT-245 | Project context (qa-50, T1) | pass 50/50 with citation, small 10/10 | `build/at/AT-245/2026-11-05.json` | A-M8-T05a |
| AT-092 | ChatGPT / Claude import (1 GB) | pass: 82.2 s, peak RSS +24 MB, cancel 22 ms | `build/at/AT-092/2026-11-05-deferred-fts.json` | A-M8-T06a |
| AT-093 / AT-019 | Export all + round trip, single-chat share | pass (round trip: 0 canonical diff lines) | `build/at/AT-093/2026-11-08.log`, `build/at/AT-019/` | A-M8-T07a |
| AT-091 / AT-NFR-PR4 | Privacy & Data, data at rest | pass (unit and host) | `make test-unit FILTER=PrivacyDataViewModelTests,FileProtectionTests` | A-M8-T08a; the TCC count leg needs the signed dev build |
| AT-218 / AT-NFR-PR2 | Diagnostics | pass (`sent_without_tap=0`, `content_hits=0`) | `build/at/AT-218/2026-11-08.log` | A-M8-T09a |
| AT-205 / AT-NFR-D8 | Storage dashboard | pass (bar vs `du` delta 0.0 %) | `build/at/AT-205/`, `build/at/AT-NFR-D8/2026-11-05.json` | A-M8-T10a |
| AT-NFR-D7 | Remove everything (Tart VM) | **pass** (zero files, Keychain, defaults) | `build/at/AT-NFR-D7/2026-11-08-remove-everything-tart.log` | A-M8-T16b (a, b) |
| AT-226 | Uninstall + reinstall (Tart VM) | **pass** (zero files, app in the Trash, no enabled login item, clean reinstall) | `build/at/AT-226/2026-11-08-{uninstall,reinstall}-tart.log` | A-M8-T11a, A-M8-T16b (a–c) |
| AT-108 / AT-042 | Notifications, background video | pass (probe) | `build/at/AT-108/`, `build/at/AT-042/probe.json` | A-M8-T12a; real delivery is owner step 3 |
| AT-105 / AT-106 | Menu bar, quick panel | pass (probe) | `build/at/AT-105/`, `build/at/AT-106/probe.json` | A-M8-T13a; ⌥Space over Finder is owner step 5 |
| AT-NFR-U9 | Quick panel ≤ 150 ms p95 | **deferred to M9.T05** (machine busy; indicative in-process p95 65 ms) | `build/perf/runs/20261108T101211Z-U9-T1.json`, `build/at/AT-106/probe.json` | A-M8-T13a (f) |
| AT-109 | JIT permission matrix | pass (probe, faked states) | `build/at/AT-109/` | A-M8-T14a; real dialogs are owner step 4 |
| AT-090 (M1, re-run) | Incognito journey 8 | **pass**, all probe legs incl. ⇧⌘N, toolbar, palette | `build/at/AT-090/` | A-M8-T16b (d, e); fs_usage leg needs sudo (Q-028) |
| AT-NFR-PR3 | Incognito disk diff with M8 present (real XPC helper + `chat-0.8b`) | **pass**: 0 violations (1 entry: the preferences plist, no content); every probe leg incl. the M8 checks (0 memory rows, 0 suggestions, notifications without title or chat id) | `build/at/AT-NFR-PR3/` | A-M8-T16b (d–f); fs_usage leg needs sudo (Q-028) |
| AT-NFR-S2 | Kill mid-stream → interrupted + Retry (window + quick-panel chat) | pass (probe, 3/3 legs) | `build/at/AT-NFR-S2/` | `J13CrashRecoveryTests` pending (Q-015/Q-023) |
| AT-296 | Import keeps the message tree (M1 promise) | pass | `build/at/AT-296/` | — |
| AT-VQ-M8 | Visual QA, 1440×900 light/dark | **pending** (computer-use grant) | runbooks `tools/visual/vq-10/11/13/14` | owner step 2 |
| Journeys 6/13/15/16 | XCUITest | **pending** (automation mode, Q-015) | `App/UITests/` | owner step 1 |

Moved to M11 (D-026): AT-051, AT-055, AT-061, AT-063, AT-107, AT-110.

## Gates (once on the final code, 2026-11-08)
- `make test-unit`: main passed, childsafety passed (`build/test-unit/`).
- `make test-integration-stub`: TEST SUCCEEDED (67 tests, 17 skipped, 0 failures).
- `BINARIES_SRC=$HOME/AntiChat/Binaries make audit`: EXIT=0. The VM step's `open` became `open -g` for the no-focus-steal audit.

## 2. Independent review

25 findings (4 S0, 6 S1, 15 S2), all confirmed and fixed: [`reviews/M8-review.md`](reviews/M8-review.md),
A-M8-T16a.

The close work found and fixed four more problems. All are in A-M8-T16b.
1. Removal left an empty preferences plist. Remove everything wrote the default shortcuts back after deleting the
   domain.
2. A Debug build left `Logs/AntiChat` behind.
3. **A second main window opened at launch** on a busy Mac. This also caused the PR3 entry-point failures and the
   incognito-session count that stayed above zero.
4. The PR3 disk diff counted another track's model download as a violation.

## 3. NFRs

| NFR | Result | Source |
|---|---|---|
| D7 Remove everything leaves nothing | pass (Tart VM) | `build/at/AT-NFR-D7/` |
| D8 Storage bar ±1 % of `du` | pass (0.0 %) | `build/at/AT-NFR-D8/2026-11-05.json` |
| PR2 nothing sent without a tap | pass | `build/at/AT-218/` |
| PR3 incognito leaves no file | pass (real helper, 0 violations) | `build/at/AT-NFR-PR3/` |
| PR4 data at rest | pass (unit and host) | A-M8-T08a |
| S2 autosave on kill | pass (probe) | `build/at/AT-NFR-S2/` |
| U9 quick panel ≤ 150 ms p95 | deferred to M9.T05 | A-M8-T13a (f) |

**Regression check against M7 (`make perf-compare BASE=main`, `build/perf/compare.json`):** 0 S1, 0 S2. 91 entries were compared and 4 were noisy (not comparable). Every compared entry is ±0 %, because `build/perf/report.json` has not changed since the M7 merge (b6d9d7bc5): M8 adds no perf entry that ran cleanly. The fresh M1 and C7 runs at T1 were refused by the perf load gate (load1 42 on 18 CPUs, 5.1 cores used by other tracks; run record `build/perf/runs/20261108T134922Z-M1-T1.json`). Following HANDOFF, they are **deferred to M9.T05**, and no bar was relaxed.

Tooling note for the lead: `gpu-run.sh timing` holds `/tmp/antichat-gpu.lock` for the whole command. `tools/perf/run.py` treats that held lock as "another job" and refuses. Its probes also take the same lock with `lockf`, so under `gpu-run.sh timing` a perf run either refuses or would wait on its own lock. The U9 run in A-M8-T13a (f) hit the same refusal. `make perf` therefore has to run on its own (`PERF_WAIT=<s>`) on a quiet machine.

## 4. Open items
- Owner steps 1–5 in [`M8-owner-steps.md`](M8-owner-steps.md): XCUITest suites and journeys 6/13/15/16, AT-VQ-M8
  (then two blind scorers; parity scoring of S-20…S-23 moves to M9.T08), real notification delivery, real
  microphone and location dialogs, and ⌥Space over another app.
- AT-090 fs_usage leg (sudo, Q-028).
- Deferred to M9.T05: NFR-U9 timing.
- Open S2s: none from the review. A-M8-T08a (d): the search pipeline does not send the city-level location hint yet
  (owned by M7 search).

## 5. Amendments of M8
A-M8-T01a, T02a, T03a, T04a, T05a, T06a, T07a, T08a, T09a, T10a, T11a, T12a, T13a, T14a, T16a, T16b (all minor).
