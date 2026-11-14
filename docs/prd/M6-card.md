# M6 card: files in and out, charts, File tools sandbox (+ M4.T10/T11 first)

Read `BUILD-BRIEF.md` first, then this card, then only your task sections in `M6.md` (and `M4.md` §M4.T10/T11 for chunk 6). This card doesn't repeat task steps. Where it and `M6.md`/`M4.md` disagree on a repo fact, the card is right (checked against the tree on 2026-11-04, main = `9e890c71`).

## What M6 delivers
Attach and understand PDF, Office, scans, images and spreadsheets; the whole-vs-excerpts rule with real reading %, excerpt notes and page citations; warm documents on follow-ups; OCR; image understanding (VLM or OCR + helper caption); DuckDB `query_data`; create PDF/DOCX/MD/XLSX/CSV/PPTX; charts from `data_ref`; file cards, side panel, Quick Look and drag-out for all 8 formats; the signed File tools runtime and the sandboxed `run_python` (P1); edit an uploaded Office file in place.
**Exit:** `M6.md` §0 "Exit" row minus AT-278 (moved, D-026). Journey 4 must pass. AT-277 is **56/64** at M6 close (M4A column → M3.T06, Show in Library → M5.T13).

## Order (chunks, BUILD-ORDER.md)
[M4.T10 M4.T11 T01 T02 T03 T04] → [T05 T06 T07 T08 T09 T10] → [T11 T12 T13 T15 T16] → [T17 T18 T19 T20 T21]. T14 is in M11 (A10).
Dependencies: M4.T10 → M4.T11 → T13 · T01 → T02 → T03 · T01 → T04 → T06 · T01 → T05 → T06 · T07 → T08 → T12 · T09 → T10 → T11 · T15 → T16 → T17 → T18 → T19 → T20.

## D-026 moves and slims that touch M6
- **M6.T14** (file-aware chips, AT-278) → M11 A10. Nothing in M6 may wait on it; T02's `files.summariseWhole` lives only in the attachment ⋯ menu.
- **M4.T10/T11 run here, first.** `ModelPack.shipped = [.chat]` (`Platform/Catalog/Selection.swift`): there are **no image job results**. Use `fixtures/images/photos-cc0/*.jpg` wherever M4 says "image results"; the `vq-05-image` steps 21/22 run on CC0 photos.
- **Audio:** M3 (`TranscribeFile`) comes after M6. M4A/WAV/MP3 uploads get a tile with transcription `pending`; the AT-020 audio leg and AT-277's M4A column close in **M3.T06** (minor amendment, note in commit body).
- **Show in Library** (`file.library`) stays hidden until **M5.T13** builds the Library. `file_blob.origin = upload` rows are still written.
- **M6.T16** builds the generic `RuntimeInstaller`, the `catalog/runtimes.yaml` format and `sign-runtime.sh`; **M5.T01 adopts them**, so keep them media-agnostic.
- **Never touched (M11 header):** the code-execution sandbox (T15–T19) and AT-NFR-SEC3 stay in full.
- **Verification scope (D-025), T21:** keeps every M6 AT, AT-NFR-SEC3, journey 4, the Office-app open checks, headline C4 at T1 on `text-10p.pdf` and C5 reading %. C4 per-tier repeats, C1/R1 re-runs → M9.T05; blind S-14/S-15 scoring → M9.T08. Still required: `make test-unit` + `make audit`, independent `/code-review` (high), running-app check, 1440×900 light+dark captures with hard checks H3–H7.
- The `M6.md` "Entry: M5 exit" ordering is superseded by D-026. G-026 (Library) and G-036 (STT) are absent; treat them as above.

## Repo reality (the PRD text is older than the code)
- **Migrations** are one file, `Packages/Storage/Sources/AntiChatStorage/Database/Migrations.swift`, currently `v1_core … v12_pending_request`. Not `Migrations/v<N>_*.swift`. Append only. **There is no `artifact` / `artifact_version` table** (M1 never made one): M4.T10 adds `v13_artifact` (architecture.md §5.1 row: `artifact{id, chat_id, kind, title}`, `artifact_version{artifact_id, n, blob_id, spec_json, created_by_message_id}`), so M6.T01's `v14_files_m6` adds `parent_version_id` and the extra `kind` values. `file_blob` / `attachment` exist (v1; `attachment.ocr_state`, `excerpt_policy` already there). `AttachmentRepository` already dedups by sha256.
- **Vendored Osaurus document code compiles** in the root `OsaurusVendored` target (adapters, OOXML editors, emitters, `PDFTableDetector`, `FileReadImageSupport`, `ZipArchive`); `AntiChatKnowledge`, Harness, UI and Engines already depend on it. Check `Vendor/osaurus-allowlist.tsv` before adding a file; regenerate the source list with `tools/vendor-sync materialize osaurus`.
- **Knowledge** has only `Index/` (`HybridRetriever`, M2.T16) + `Knowledge.swift`. `Intake/` and `OCR/` are new. Chunk tables come from `Storage/Index/ChunkTables.swift` (v11); T02 adds `chunk.page_ref`.
- **Fixtures are empty** for M6: `fixtures/docs/{pdf,office,golden-out}` hold only `SOURCES.md`; `fixtures/images/upload-errors` too; `fixtures/web/network-probe.html` doesn't exist. The first task that needs a file creates it (generator in `tools/fixtures/`, `SOURCES.md` row, `fixtures/fixtures.lock.json`), then pushes the submodule. `photos-cc0/001–040.jpg` exist.
- **Tools env:** `tools/pyproject.toml` has numpy + pillow only. Add `reportlab, openpyxl, python-docx, python-pptx, pypdf, pandas, xlwt` (exact versions, `uv lock`) in the first task that generates Office/PDF fixtures (M4.T10). Run as `tools/.venv/bin/python3 -I …`.
- **Catalog** has `context_default` / `context_max`, **no `context_tokens`, no `prefill_tps`**. T02 maps `context_tokens` → the effective context (`context_default` unless the scheduler raised it) and adds `prefill_tps` to `catalog/models.yaml` from measured values (minor amendment, K-NEW-FILES-2).
- **UI:** no `Artifacts/` folder, no Quick Look code yet. Composer has `PasteAttachmentCard` (M1 pasted-text cards) and `AddMenu`; reuse them for tiles. Conversation has `VersionSwitcher` (message versions, not artifacts).
- **Launch args** in `Foundation/Debug/LaunchOptions.swift`; `-FakeHardware`, `-UseScriptedEngine`, `ANTICHAT_DEV_CONTAINER` exist. `ScriptedEngine` is `Engines/LLM/ScriptedEngine.swift`.
- **Strings:** `App/AntiChat/Localizable.xcstrings` + `docs/research/10-architecture/design-system/copy-deck.md` in the same commit, then `tools/ci/copy-sync.py`.
- **XCUITest can't start here (Q-015):** write the UI test, run the in-process probe path (`tools/at/*-probe.sh`, `tools/at/run.sh <AT> -- <probe>`), record the XCUITest leg `pending (Q-015)`. Same for computer-use legs (Q-021) and the Office open checks (Q-M6-01 if Microsoft apps are absent).
- Host is shared and often loaded: note `uptime` load average next to every timing number; never kill other processes.

## Per-task essentials (chunk 6; later chunks: read the task)
- **M4.T10** `UI/Artifacts/{FileCard, QuickLookPreview, Thumbnail, DragOut}.swift`. Open (`NSWorkspace.open`), Save As (`NSSavePanel`), Show in Finder (`file.reveal` replaces `library.reveal` in T13; add `library.reveal` now), Quick Look on click/Space, `.draggable` file-URL copy named `display_name`, thumbnails cached in `~/Library/Caches/AntiChat/thumbnails/` (never incognito). Checks: `FileCardViewModelTests`, `DragOutProviderTests`, `FileCardTests` (Q-015), snapshot per state. No AT owned.
- **M4.T11** `UI/Artifacts/{SidePanel, VersionPicker, SandboxedWebPreview, EditSelection}.swift` + `UI/Resources/ContentRules/block-all.json`. Non-persistent data store, block-all rule list except `about:` + own `file://`, JS off for SVG, navigation cancelled. Checks: `SandboxedWebPreviewTests` (zero network on `network-probe.html`), `SidePanelTests`, `make test-offline FILTER=SandboxedWebPreview`.
- **T01 / AT-020** intake actor, `TypeSniffer` magic table (HEIC-as-.jpg → `isLying`), limits 512 MB / 20 files, media store `…/Media/<yyyy>/<sha256>.<ext>`, incognito → temp dir + in-memory DB, `ExtractionService` over vendored adapters + new `EPUBAdapter`, tiles (reading / ready / error + toast / too large / encrypted), `<document … untrusted="true">`. XLS shows `upload.unsupported` until T07.
- **T02 / AT-270** `DocumentBudget` = R-270 AC1 formula exactly; new EngineProtocol `CountTokens` (version bump + handshake); `tier-budgets.json`; `DocumentIndexer` with `page_ref`; excerpt note, `PageCitePill`, `[Read whole file]` only when `fitsContext && !fitsTime`; map-reduce with real %; D-09 patch (`UP-###`). 4a = 200/200 decisions; 4b `exact_page_rate ≥ 0.80` at T1.
- **T03 / AT-279** `prefixPin` on `ChatRequest` (version bump), `PrefixCachePolicy` (evict on pressure ≤ 2 s, keep-alive, budget B; never save for incognito). p50 `ttft_followup / ttft_first ≤ 0.30` over 20 runs at T2 cap.
- **T04 / AT-271** `ScanDetector` (< 20 chars → OCR), `RecognizeDocumentsRequest` → Markdown incl. tables, `VNRecognizeTextRequest(.accurate)` fallback, images always get `ocr_text`, `OCRQueue` off-main, send-before-finish with `files.stillReading`. CER ≤ 3% over `ocr-30p`; ≥ 18/20 tables shape-exact.

## Cross-task contracts
1. **Import edges** as M2: Harness never imports Platform/Network; helper Engines never imports Platform. Knowledge may import Storage + OsaurusVendored only.
2. **Every byte through `NetworkGate`.** No `URLSession` in previews; web previews provably offline.
3. **Untrusted content:** every extracted document, excerpt, OCR and caption text is wrapped `untrusted="true"` (NFR-SEC5).
4. **Incognito:** no disk copies outside the temp dir, no thumbnails cache, no KV saves, no index/embed jobs.
5. **One `artifact_version` chain** for every produced file (T09–T13, images later); version labels `file.version`.
6. **No filtering** besides `ChildSafetyCheck` (D-006): none in intake, OCR, captions or the sandbox.
7. **Sandbox (T15–T19):** app never writes into the XPC container (A-M6-11); thread caps per A-M6-07; idle-out 10 min (A-M6-03).
8. **Conflicts A-M6-01…11** in `M6.md` §0.2 are pre-resolved; record each in `PRD-AMENDMENTS.md` on first touch only if not already there.

## Pins and IDs to grep
`osaurus@2922745`, TPPDF 2.6.1 `975049c0e1`, libxlsxwriter v1.2.4 `2894634d65`, libxls (latest tag, A-M6-10), react/react-dom 18.3.1 UMD, `cetus@110b385540`; P-files-tools-01…07, -09; blueprint C §C.1–§C.7; screens S-14, S-15; IS-6, IS-8, IS-10; NFR-C1, C4, C5, D2, R1, SEC3, SEC5, PR3; Q-007, Q-015, Q-021, Q-M6-01; D-006, D-025, D-026.

## Handoff: M6.T21 close (2026-11-09, branch `m6/sandbox`)
**Done on the branch (after cb3310c2b):**
- **#5 slots (lead ruling (c)) applied** — 4d8a326cc, 7d7dcf2f3. 3 slot bundles per variant (`AntiChatFileTools[Net]Slot1…3`,
  ids `app.antichat.AntiChat.FileTools[.Net].slot<k>`, project.yml template `FileToolsSlot`), `FileToolsSlots` leaser
  (Packages/Tools/.../FileTools/FileToolsSlots.swift), protocol v2 (`wipeSlot`, `scratchEmpty`), sbpl: a slot writes only
  `Data/scratch` in its container and nothing in its darwin dirs (the `application_container` param is the Data folder,
  measured), N per tier T0/T1 2, T2+ 3 (`FileToolsTools.slotCount`; T0 = 2 because SEC3's bystander has no tier
  exception; reasoning in A-M6-T21a), `sandbox.waiting` on the ActivityLine (5 languages). Generator/sign.sh/
  signing-ids/probe cover every slot id. Evidence: FileToolsSlotTests + FileToolsJailTests + SecuritySuiteTests green
  (SEC3 80/80, bystander 0.72 s with 2 other chats busy, load 37).
- fcbad802c: journey 4 (FilesJourneyTests pending Q-015; FilesJourneyHostTests in-process, green), vq-07-files runbook,
  M6-owner-steps.md, `make perf ... DOC=<pdf>` (tools/perf/run.py `--doc`).
- Fixture 04 expects denied: fixtures 59fa95a (bare repo branch `m6-sandbox`), pinned.

**Next, in order:** AT-276 3×3 (series 4 runner: scratchpad `reps4.sh` pattern = old reps.sh through
`~/AntiChat-tools/gpu-run.sh shared`; evidence `build/at/AT-276/<date>/runs/s4-<set>-<rep>/`) → merge main (≥ ec0f66c34)
→ gates (`make test-unit`, `make test-integration-stub`, `BINARIES_SRC=$HOME/AntiChat/Binaries make audit`) →
`make build-release` → `tools/at/ft-release-probe.sh --mode adhoc --suite 10` and `--mode devid --suite 10` → C4
(`make perf METRIC=C4 TIER=T1 DOC=fixtures/docs/pdf/text-10p.pdf` via gpu-run.sh timing; DEFERRED → M9.T05) and C5
(engine prefillProgress mapping is covered in-process by FilesJourneyHostTests; the UI leg pending Q-015) →
M6-report.md, README row, STATUS.md → `READY: m6/sandbox @<sha>`.

**Gotchas.**
- `Packages/*` has no Package.swift of its own: run `swift test --filter …` from the repo root.
- Never edit sources while a build or GPU job runs. Kill only your own PIDs.
- UI module host tests that finish a reply need `_ = NSApplication.shared` (StreamAnnouncer posts to NSApp).
- A new file under App/ needs `make xcodeproj` (pbxproj is committed).
