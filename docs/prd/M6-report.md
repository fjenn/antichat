# M6 report: files in and out, charts, File tools sandbox (M6.T21)

**Date:** 2026-11-09 · **Branch:** `m6/sandbox` (M6.T01–T21 + main f8c3949d6) · **Fixtures:** 086a56f
(bare branch `m6/sandbox` = 6524a77 "04 expects denied" merged into main's 7c55ede) · **Host:** MacBook Pro M5 Max
128 GB, macOS 26.6.2, shared with other tracks (load 5–83 during the close; noted per number).
**Scope (D-025, D-026):** every M6 AT, AT-NFR-SEC3 in full, journey 4, the Office-app open checks, headline C4 at T1
on `text-10p.pdf` and C5 reading %; C4 per-tier, C1/R1 re-runs → M9.T05; blind S-14/S-15 scoring → M9.T08; AT-278
(file-aware chips) moved to M11 A10.

## 1. Acceptance tests

Status: **pass** · **miss** · **pending (reason)**. Artefacts are under `build/at/`. "In-process" = the probe /
module-host leg; the XCUITest leg of the same check is pending Q-015 (owner, `docs/prd/M6-owner-steps.md` §1).

| AT | Bar (condensed) | Result | Artefact | Amendments / pending |
|---|---|---|---|---|
| AT-016 | Card + auto-open panel (≤ 40 lines inline / 41 promote), previews, net-probe 0 hits, Copy/Download/versions/Fix, Edit selection v2, Outputs | pass in-process (40/41 threshold, counter.jsx increments, 0 probe connections, v2 span-only); panel auto-open seen in the running app (§4 `s15-cards-panel`) | `build/at/AT-016/` | A-M6-08, A-M6-T13a; `ArtifactsPanelTests` pending (Q-015) |
| AT-017 | Open / Save As byte-identical / Reveal; Files in this chat = DB rows | pass in-process (ChatFilesQueryTests, FilesOutPanelTests); the sheet with attached + produced rows captured in the running app (§4 `s24-files-in-chat`, `s15-files-in-chat`) | `build/at/AT-VQ-M6/2026-11-09/` | `FilesInChatTests` pending (Q-015) |
| AT-018 | Signed on-demand runtime ≤ 90 MB, sha-checked; sandbox, no network, jail, limits, 3 rows, 10-min idle; SEC3 100 % | pass: zip 73.45 MB; Release proof on the merged head, **adhoc and Developer ID each 220 probes / 0 failures** (entitlements = files, every slot sandboxed, jail + cross-slot EPERM); shipped app re-signed with Developer ID passes `verify-signing --pre-notary` | `build/at/AT-018/2026-11-09/release-{adhoc,devid}/` | A-M6-09 (notarisation → M10), A-M6-11, A-M6-T15a, A-M6-T16a, A-M6-T18b (closed), A-M6-T21a |
| AT-020 | 3 attach paths, 100 % formats extract, 512 MB / 20 files, excerpts on doc-300p, error tile + toast | pass in-process (formats 19/19); running app: reading → ready tiles, error tiles + toast for corrupt / encrypted (password field) / legacy .doc / 513 MB | `build/at/AT-020/2026-11-09/formats.json`, `build/at/AT-VQ-M6/2026-11-09/vq-files-attach/` | A-M6-T01a, A-M3-T06a; `FilesIntakeTests` pending (Q-015) |
| AT-021 | VLM gets the image; accuracy ≥ 0.90 at T1 | pass: T1 50/50 = 1.00 (T0 0.98, Evil T1 1.00) | `build/at/AT-021/2026-11-04/` | A-M6-T05a; `ImageUnderstandingTests` pending (Q-015) |
| AT-237 | Helper caption block + label; 0 extra helper calls after compaction | pass: 10/10, helper peak 2.74 GB | `build/at/AT-237/2026-11-04/` | A-M6-T06a |
| AT-270 | 4a decisions; 4b `exact_page_rate ≥ 0.80` at T1 | pass: 4a 200/200 (2026-11-09), 4b 0.98 | `build/at/AT-270/2026-11-09/decisions.json`, `2026-11-04/pagecite.json` | A-M6-T02a; `FilesExcerptTests` pending (Q-015) |
| AT-271 | CER ≤ 3 %; tables ≥ 18/20 | pass: CER 0.127 %, tables 20/20 | `build/at/AT-271/2026-11-09/` | A-M6-T04a; `FilesScanTests` pending (Q-015) |
| AT-272 | `query_data` accuracy ≥ 0.85 at T1, 0 outbound | pass: 50/50 = 1.00, 0 outbound | `build/at/AT-272/2026-11-04/` | A-M6-10, A-M6-T07a, A-M6-T08a |
| AT-273 | create_document/spreadsheet: goldens, 1 repair turn, versions, opens in every installed app, re-open 100 % | pass on the run columns: Numbers 60/60, Preview 30/30, TextEdit 60/60, python re-open 90/90; **pending:** Pages column (Q-M6-02, unblocked by the owner's licence acceptance, needs the computer-use sitting), Word/Excel (Q-M6-01) | `build/at/AT-273/2026-11-04/golden/` | A-M6-01, A-M6-02, A-M6-T09a, A-M6-T10a (full 150-prompt model run → M9.T05) |
| AT-274 | Inline rejected / injected; render + 4 actions + 0 network; plotted = aggregates in **20/20** | **pass:** checks 1–2 pass; check 3 **20/20** at T1 on the final code, twice (run 4 load 4–10, run 5 load 5; in run 5 sc-06's chart call was cut off at the output limit, the model was told and its retry drew the chart). Earlier merged-head runs 16/20, 18/20, 18/20; their misses were fixed generically (A-M6-T21b) | `build/at/AT-274/2026-11-09/summary.json`, `2026-11-09-run5/`, earlier `2026-11-09-run{1,2,3}/` | A-M6-T12a, A-M6-T12b, A-M6-T21b; `ChartCardTests` pending (Q-015) |
| AT-275 | 4 themes, layouts, 31-slide spec rejected, panel preview, opens in Keynote + PowerPoint | pass on the run columns (goldens, Quick Look 25/25, python-pptx 25/25); Keynote (Q-M6-02, as AT-273) and PowerPoint (Q-M6-01) pending | `build/at/AT-275/2026-11-04/` | A-M6-T11a (full 20 → M9.T05) |
| AT-276 | Change + style kept in ≥ 8/9; original untouched 9/9; version card; no-File-tools copy | **pass 3/3 reps** (series 4 after the slot design: main 8/9, 9/9, 8/9; originals 9/9). Held-out (never tuned on, no bar): holdout3 5/5 ×3, holdout4 5/5, 4/5, 5/5 | `build/at/AT-276/2026-11-09/runs/` | A-M6-T20a; `OfficeEditOfferTests` pending (Q-015) |
| AT-277 | 56/64 at M6 close; VO labels + audit 0; drag-out | pass 56/64 (8 Show in Library cells → M5.T13); audit + drag-out pending | `build/at/AT-277/2026-11-05/matrix.json` | A-M6-05; audit Q-015; drag-out Q-021 (owner sitting) |
| AT-279 | p50 follow-up/first TTFT ≤ 0.30; peak ≤ B; release ≤ 2 s | pass: 0.048; peak 8.11 GB; release p50 0.099 s | `build/at/AT-279/2026-11-04*` | — |
| AT-NFR-SEC3 | 8 × 10 fixtures denied/killed; memory ≤ cap + 5 %; 60 s ± 1; CPU p95 ≤ 200 %; bystander ≤ 2 s | **pass:** Debug 80/80 with 2 other chats busy (bystander 0.72 s); **Release adhoc 80/80** (05 peak 1.005 × cap, CPU p95 52 %, bystander 1.20 s), **Release Developer ID 80/80** (1.012 ×, 75 %, 0.31 s); load 35–72 | `build/at/AT-NFR-SEC3/2026-11-09/` | A-M6-07, A-M6-T18a, A-M6-T19a, A-M6-T21a |
| Journey 4 | Attach PDF → reading % → answer with page cite; upload error tile | pass in-process (`FilesJourneyHostTests`) and in the running app (`vq-files-attach`); XCUITest `FilesJourneyTests` pending (Q-015) | `build/at/AT-VQ-M6/2026-11-09/vq-files-attach/probe.json` | — |
| AT-278 | File-aware chips | moved to M11 A10 (D-026) | — | — |

## 2. Independent review

Two independent reviews, both fixed in full: the pre-close review (`reviews/M6-review.md`, M6.T01–T13: 1 P0, 6 P1,
14 P2) and the close review (`reviews/M6-close-review.md`, sandbox + edit in place: 1 P0, 11 P1, 9 P2). The close
review's #5 (per-chat isolation) was fixed by the slot design (lead ruling (c), A-M6-T21a): 3 slot services per
variant, each its own bundle id and App Sandbox container; a chat leases one slot (N = T0/T1 2, T2+ 3), the slot is
wiped and verified empty before a lease moves, chats beyond N wait with `sandbox.waiting`. Proof:
`FileToolsSlotTests` (sandboxed), the Release probe's cross-slot rows, SEC3's bystander with two busy chats.

## 3. Headline numbers

| Number | Result | Bar | Load (1-min) | Source |
|---|---|---|---|---|
| **NFR-C4** prefill, T1 cap (chat-9b-q4), `text-10p.pdf` | **pass:** p50 **2,771 tok/s** (p95 2,922, n = 5), Debug app, Low Power Mode off, AC power, thermal nominal; `gpu-run timing`; quality flag "noisy" (XprotectService used ~2 cores during the run, which can only lower the number) | ≥ 150 tok/s | 3.0–3.4 | `build/perf/report.json` key `C4`, `build/perf/runs/20261109T213444Z-C4-T1.{json,log}` |
| **NFR-C5** real reading % | in the running app: 30 distinct values 2 → 100 % during the document prefill (`status.reading`); in-process FilesJourneyHostTests; XCUITest `FilesExcerptTests/testReadingPercentAlwaysShown` pending (Q-015) | 100 % of prefills > 3 s show a real % | 78 | `build/at/AT-VQ-M6/2026-11-09/vq-files-attach/probe.json` |
| AT-NFR-SEC3 bystander | 0.31–1.20 s (Release), 0.72 s (Debug, 2 busy chats) | ≤ 2 s | 35–72 | §1 |
| AT-276 edit in place (T1) | 8/9, 9/9, 8/9 | ≥ 8/9 | 6–43 | §1 |

## 4. Visual QA (AT-VQ-M6) and the running-app check

`tools/visual/vq-m6.sh` runs the Debug build with `-SearchProbe` in three `vq-files-*` modes (App/AntiChat/VisualQAM6.swift,
ScriptedEngine, fresh dev container each), 1440×900, system Light and Dark, 20 PNGs in `build/at/AT-VQ-M6/2026-11-09/`.
This is also the running-app check of the close. All three legs pass:

| Leg | Screens | Result |
|---|---|---|
| `vq-files-attach` | S-14 drop overlay, reading → ready tiles (PDF / sheet / image), `Reading <file> · N%`, answer with page pill, error tiles + toast; S-24 Files in this chat | pass: 3/3 tiles ready, real reading % (30 values), page pill (file use recorded), every bad upload is an error on its own tile + toast (IS-10), encrypted PDF shows the password field |
| `vq-files-out` | S-15 `create_document` → PDF card + auto-opened panel, `create_chart` → chart card, Files in this chat (produced rows) | pass: both steps done, panel opened on the PDF |
| `vq-files-settings` | S-21 Tools & Connections: Create files, Run code for analysis (install offer), Allow network for code | pass |

**Found and fixed in the captures:** the chart card aspect-fit a small Vega-Lite chart (4 bars, default step width)
to the 520 pt card, so it was blurred and about 3.5× oversized. It is now shown at most at its own size
(`ChartCardView.naturalWidth`, `ChartCardModelTests.aChartIsNeverStretchedPastItsOwnSize`); the final capture is sharp.

**Automated hard checks** (`hard-checks.json`, 20 images): **H7 pass**. H3 flags are text behind the Files in this
chat sheet (sheet-dimmed, exempt under WCAG 1.4.3), OCR noise on chevrons / icons, the onboarding tip and "Got it"
button (M1 tokens), the M7 accent link text "Running code needs File tools" (4.26:1, the S2 carried from M7 to
M9.T08) and the orange Tool access warning (M7.T14, shown because the runner sets "Always offer all"); none is a new
M6 text colour. H5 0.88 coverage: the unmatched lines are timestamps, sizes, fixture names, OCR misreads and file
contents; `copy-sync.py` (in `make audit`) is the exact check and is green. H6 is reported, not gated (as M7).
H4 (accessibility audit) pending Q-015. Not captured here (need other apps, owner sitting §2): drag-out to Finder /
Mail and the Preview / Pages / Numbers / Keynote opens. Blind S-14 / S-15 / S-21 / S-24 scoring → M9.T08.

## 5. Gates (once on the final code)

On `2f675a0c2` (m6/sandbox with main f8c3949d6 merged, after the AT-274 fixes), run once, sequentially:
`make test-unit` **pass** (2,626 Swift Testing tests, 0 failures; childsafety passed), `make test-integration-stub`
**pass** (90 executed, 30 skipped, 0 failures), `BINARIES_SRC=$HOME/AntiChat/Binaries make audit` **EXIT=0**. Logs:
`build/at/M6-gates/2026-11-09-final/`. Later commits are documentation only.

## 6. Open items
- **XCUITest legs** (Q-015, owner): FilesJourneyTests, FilesExcerptTests (C5 UI leg), FileCardTests,
  FileToolsSettingsTests, ArtifactsPanelTests, FilesInChatTests, ChartCardTests, OfficeEditOfferTests, H4 audit.
- **Owner sitting** (`M6-owner-steps.md`): computer use for drag-out (S-15) and the Pages / Keynote open columns
  (Q-M6-02 unblocked), Office (Q-M6-01, optional).
- **Moved:** AT-278 (M11 A10); C4 per tier, C1 / R1 re-runs (M9.T05); blind scoring (M9.T08); AT-273 / AT-275 full
  model runs (M9.T05); notarisation (M10, A-M6-09).
- **M8 note:** Storage must list runtime components (`filetools-runtime`, `video-runtime`) from `SpaceAccountant`.
- Chart card polish (M9): the card keeps its 520 pt frame around a narrow chart.

## 7. Post-close note: run clock across system sleep (2026-11-10, fix/sandbox-timeout)
In two round-43 full integration runs, AT-NFR-SEC3 `06_infinite_loop` reported `wall 619.7 s` (bg-tests, rep 7) and
`652.4 s` (a parallel worktree, rep 5) against the 60 s limit. Both runs straddled one system sleep:
`pmset -g log` shows `21:06:58 Entering Sleep state due to 'Low Power Sleep' … Using Batt (Charge:1%) 613 secs` and a
wake at 21:17:11. That leaves 6.7 s and 39.4 s awake, both under 60 s, so neither run had reached its limit when the
Mac slept. The row also has `watchdogMaxGapMs` 610,474, one gap with nothing running, CPU 1.45 %. Every other 06 row
of the same runs at load 10–13 had gaps ≤ 52 ms and walls of 60.00–60.01 s. So the watchdog was not late under load:
it measured on `Date()`, which keeps counting while the Mac sleeps, and killed the run at once on wake.
**Fix:** the File tools service times runs on `RunClock` (`CLOCK_UPTIME_RAW`, awake time; it does not count sleep and
does not follow wall-clock changes): the watchdog deadline, its gaps, CPU % and `RunResult.wallSeconds`. Sleep during a
run is reported apart in `RunResult.asleepSeconds` (suite rows carry it). The limit is now the time the code could run;
the kernel `RLIMIT_CPU` backstop (repl.py: used + 60 s → SIGXCPU) is unchanged. Unit tests inject a 600 s sleep
(`watchdogDeadlineCountsOnlyAwakeTime`, `simulatedSleepMidRunCountsOnlyAwakeTime`). Under artificial load (16 × `yes`
+ memory pressure, load ≥ 40) the 06 kill stays within the 1 s tolerance: see the fix/sandbox-timeout report.

**STATUS: M6 done, exit conditional — every M6 AT that can run here passes (AT-274 20/20 twice on the final code), AT-NFR-SEC3 passes in Debug and both Release signings, NFR-C4 at T1 is 2,771 tok/s (bar ≥ 150), journey 4 and the running-app captures pass, both reviews are fixed, and the gates are green on the final code; open: XCUITest legs and H4 (Q-015), the owner sitting for drag-out and the Pages / Keynote columns (Q-M6-02), Office columns (Q-M6-01, optional), blind scoring (M9.T08), the moved items above.**
