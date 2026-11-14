# VQ-07 Files (M6.T21, AT-VQ-M6) — screens S-14 (attachments in, reading, excerpts), S-15 (file cards, panel, drag-out), S-21 (Tools & Connections: File tools rows), S-24 (Files in this chat)

Bars (M6.md §M6.T21): ★ **S-14 ≥ 4.5** (L, V, C ≥ 4; error on the tile, IS-10; real reading %, NFR-C5), **S-15 ≥ 4.0**
(drag-out works to Finder and Mail), S-21 ≥ 4.0, S-24 ≥ 4.0, no dimension < 3; hard checks H1, H2 (streaming with
attachments), H4 (accessibility audit 0 issues on S-14/S-15), H5 (copy sync), H6 (grid). Blind scoring of S-14/S-15
moved to M9.T08 (D-025); this runbook produces the captures.

**Who runs it:** an agent with computer use, after the owner granted access (docs/prd/M6-owner-steps.md §2). This is the
only M6 step that brings AntiChat to the front (the visual-QA exception to BackgroundRun).

**Build and container:** `make build-release SIGNING_MODE=adhoc`, then
`build/release/AntiChat.app/Contents/MacOS/AntiChat -ANTICHAT_DEV_CONTAINER /tmp/vq07` (fresh container; window 1440×900,
light mode unless a step says dark). Runtime: Settings → Tools & Connections → Run code for analysis → Install (step 27
does this on camera; run it first off camera if steps 26/28/29 come earlier).

**Capture:** `tools/visual/capture.sh shot vq-07-files <label> [window-id]` and
`tools/visual/capture.sh rec vq-07-files <label> <seconds>` → `build/visual/<version>/vq-07-files/NN_<label>.{png,mov}`.
Every step: do the action, check the expected observation, capture. A missed observation is a finding (test-strategy §11
severity), never a silent retake.

**Fixtures:** `fixtures/docs/...` at the pinned submodule commit (`ANTICHAT_FIXTURES=$PWD/fixtures`).

| # | Action | Expected observation | Capture |
|---|---|---|---|
| 1 | New chat; drag `fixtures/docs/office/report.docx` over the window, hold | Drop overlay `files.drop` over the conversation | shot `s14-dragover` |
| 2 | Drop `pdf/text-10p.pdf`, `office/budget.xlsx`, `formats-8/photo.jpg`, `formats-8/memo.m4a` at once | Four tiles in the composer, each "Reading…" with a real % | rec 10 s `s14-reading`; shot `s14-reading` |
| 3 | Wait | Ready tiles: PDF thumbnail, `tile.sheet`, image thumbnail, `tile.audio` with transcription `pending` (M3.T06) | shot `s14-ready` |
| 4 | Drop `pdf/scan-60p-contract.pdf` | "Reading scan · page n of N" counts up (OCR off-main, the window stays responsive) | rec 15 s `s14-ocr` |
| 5 | File-aware chips | **Not in M6** (M6.T14 → M11 A10, D-026): record "n/a (M11)" | — |
| 6 | Drop `pdf/corrupt.pdf`, a 0-byte file, `office/legacy.doc`, a 513 MB sparse file (`mkfile -n 513m /tmp/big.bin`), `pdf/encrypted.pdf` | Error on the tile itself + toast (IS-10); `upload.unsupported`; too large; password field on the encrypted tile | shots `s14-error`, `s14-toolarge`, `s14-encrypted` |
| 7 | Attach `budget-40/doc-300p.pdf`, ask "Summarise chapter 3" | ActivityLine `status.reading` with a real, increasing % (never a spinner only) | rec 20 s `s14-reading-pct` (frametime check: `tools/visual/layout-jump.py`) |
| 8 | Expand the answer's excerpt note | `files.usedExcerpts` lists the excerpts with page numbers | shot `s14-excerpts` |
| 9 | Click a "(p. 41)" pill; then send a message while step 4's OCR still runs | Side panel opens at page 41; the send goes out with `files.stillReading` | shots `s14-pagepill`, `s14-stillreading` |
| 10 | Relaunch with `-FakeHardware T0`, attach `doc-300p.pdf`, ask a whole-document question | `[Read whole file]` with its time estimate (only when it fits the context but not the time) | shot `s14-readwhole-t0` |
| 11 | Attach `formats-8/photo.jpg`, ask "What is in this picture?"; relaunch with `-FakeHardware t0-novision` and repeat | An answer about the photo; on t0-novision the vision-unavailable card | shots `s14-image-answer`, `s14-novision` |
| 12 | Same image on a model without vision but with the helper | Helper caption label under the answer | shot `s14-helper` |
| 13 | Attach `office/budget.xlsx`, ask "Total by region" | `query_data` ActivityLine; collapsed, then expanded with the SQL and rows | shots `s15-query-collapsed`, `s15-query-expanded` |
| 14 | "Make this a PDF"; then a ScriptedEngine run with a malformed spec (`-UseScriptedEngine file-out-malformed`) | FileCard generating → ready; malformed spec → error card with [Try again] | shots `s15-card-generating`, `s15-card-ready`, `s15-card-error` |
| 15 | "Add a column with the share of the total" on the XLSX card | Version switcher shows v2 | shot `s15-v2` |
| 16 | Open the PDF, DOCX and XLSX cards (Open) | Preview / Pages / Numbers open each file, no repair dialog (Word/Excel too if installed, Q-M6-01) | one shot per app `s15-open-<app>` |
| 17 | "Make a 5-slide deck of this" | Deck card, panel preview, Keynote opens it without a repair dialog | shots `s15-deck-card`, `s15-deck-panel`, `s15-deck-keynote` |
| 18 | "Chart sales by month" on the sheet; View data; a ScriptedEngine bad chart spec | Chart card rendering → ready; data table; spec error card | shots `s15-chart-rendering`, `s15-chart-ready`, `s15-chart-data`, `s15-chart-error` |
| 19 | Ask for a long code answer (> 40 lines) | Artifact card; the panel opens in ≤ 320 ms | rec 1 s `s15-code-panel` |
| 20 | Previews of an HTML, an SVG, a Mermaid artifact and `fixtures/web/preview/broken.html` | Offline previews render; broken.html shows [Fix with AntiChat] | shots `s15-preview-html`, `-svg`, `-mermaid`, `-broken` |
| 21 | Select a sentence in the panel → edit popover → "make it shorter" | Popover, then v2 of the artifact | shots `s15-edit-popover`, `s15-edit-v2` |
| 22 | Scroll to the outputs list of the chat | All produced files listed with versions | shot `s15-outputs` |
| 23 | Chat ⋯ → Files in this chat | Sheet with uploads and outputs (S-24) | shot `s15-files-in-chat` |
| 24 | Drag the XLSX card onto a Finder window | A file named after the card's display name appears | rec 5 s `s15-drag-finder`; shot `s15-drag-finder` |
| 25 | Drag the PDF card into a Mail compose window (TextEdit if Mail has no account) | The PDF lands as an attachment | rec 5 s `s15-drag-mail`; shot `s15-drag-mail` |
| 26 | `run_python` with `while True: pass`; then one that opens a socket | `sandbox.timeout` after 60 s; `sandbox.networkOff` with the Settings link | shots `s15-sandbox-timeout`, `s15-sandbox-networkoff` |
| 27 | Settings → Tools & Connections: Create files, Run code for analysis (Install → progress → On), Allow network for code; light and dark | Three rows with their defaults; install progress; instant save (S-21) | shots `s21-tools-light`, `s21-install`, `s21-tools-dark` |
| 28 | Analysis prompt on `office/budget.xlsx` ("plot the totals") | Figure card from `run_python` | shot `s15-figure` |
| 29 | With Run code off, attach `office/report.docx`, "make the title bold"; then with it on | Office edit offer card; then v2 after the in-place edit | shots `s15-office-offer`, `s15-office-v2` |
| 30 | Repeat steps 1–8, 14, 18, 23 in dark mode and at 1180×820; Reduce Transparency on for steps 2 and 14. Also: start `run_python` loops in 3 chats at once (T2+: 3 slots) and send a 4th chat's analysis | Dark/compact captures; the 4th chat's line reads `sandbox.waiting` ("Waiting for a free sandbox…") until a slot frees, then runs | shots suffixed `-dark`, `-compact`, `-rt`; shot `s15-sandbox-waiting` |

**Afterwards:** `make audit` (H5 copy sync), the accessibility audit on S-14/S-15 (H4), the grid check (H6), then hand
the folder to two blind scorers (M9.T08) → `build/visual/parity-M6.md`.
