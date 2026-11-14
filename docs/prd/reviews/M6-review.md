# M6 (files in/out) review — AntiChat main

Scope: M4.T10, M4.T11, M6.T01–T13 and their follow-ups. The code-exec sandbox (M6.T15–T19) is not covered. This was a read-only review: nothing was built, run or edited.
Every finding below comes from reading the code path. Items marked "(verify)" depend on platform behaviour I could not run.

## P0

1. **HTML attachments fetch remote subresources outside NetworkGate.**
   `Packages/Knowledge/Sources/AntiChatKnowledge/Intake/ExtractionService.swift:50-52` → vendored `RichDocumentAdapter.swift:41` (`NSAttributedString(url:options:[.documentType: .html])`).
   - Defect: AppKit's HTML importer runs WebKit, which loads `<img src>`, `<link rel=stylesheet>`, CSS `url()` and similar. The app has no App Sandbox (its entitlements are only `audio-input`). Those loads never pass through a gated URLSession, a content rule list or a CSP.
   - Scenario: the user attaches a saved web page (`.html`). At intake, the app makes HTTP requests to every image and tracker host in the file. The importer's `.timeout` option shows it waits for those loads. (verify with the network-probe listener)
   - Fix: never feed raw HTML to the AppKit importer. Either parse it with XMLParser / a tag stripper (as `EPUBAdapter.XHTMLText` already does), or strip every `src` / `href` / `srcset` / `url()` / `<link>` / `<base>` first and import from `Data` with no base URL. Add HTML to the network-zero test.

## P1

2. **Zip bombs: our own zip readers inflate without any size limit.**
   - Unbounded calls: `ExtractionService.swift:218-220` (`DOCXHeadings.levels`, runs on every DOCX), `EPUBAdapter.swift:20-23` (every member) and `Packages/Tools/Sources/AntiChatTools/SQL/XLSXDateStyles.swift:15-18` (every XLSX sheet). All three call `ZipArchive.extract`, which is `NSData.decompressed(using: .zlib)` with no output cap (`Vendor/osaurus@2922745/.../Utils/ZipArchive.swift:204`).
   - The vendored XLSX and PPTX adapters use bounded readers (`maxXMLPartBytes`, `BoundedZipReader`). These three paths bypass those bounds.
   - Scenario: a 5 MB `.docx` whose `word/document.xml` inflates to more than 4 GB passes the 512 MB check. It then inflates fully in memory, and the app is killed.
   - Fix: share one bounded inflate (streaming, per-part cap of about 64 MB plus a total cap, checking the actual output and not the declared `uncompressedSize`). Reuse `BoundedZipReader`.

3. **The app crashes on model-supplied formula or chart cell references.**
   `Packages/Tools/Sources/AntiChatTools/FileOut/XLSXWriter.swift:56-63` (`cell`), called from `CreateSpreadsheetTool.swift:36` and `:49` during validation.
   - Defect: `UInt32(r - 1)` and `UInt16(c - 1)` trap when the value is out of range. The letter check uses `Character.isLetter`, which accepts any Unicode letter.
   - Scenario: `"formulas": {"A99999999999": "1"}` overflows UInt32. `{"合计B14": "SUM(B2:B13)"}` gives column ≈ 15 M and overflows UInt16. Either way the app process traps during `problems()`, before the repair turn.
   - Fix: accept only ASCII A–Z, column ≤ 16384, row ≤ 1,048,576. Use `UInt32(exactly:)` / `UInt16(exactly:)`.

4. **Incognito outputs leave disk traces: thumbnails and drag/share copies.**
   - Thumbnails: `ActivityLine+FileOut.swift:138` and `FileCardVersionSwitcher.swift:32` build `FileCard` without `incognito`, so it defaults to false (`FileCard.swift:23`). `FileThumbnail` → `ThumbnailCache.thumbnail` then writes a PNG to `~/Library/Caches/AntiChat/thumbnails` (`Thumbnail.swift:48`).
   - Drag/share copies: `DragOut.namedCopy` (`DragOut.swift:10-30`) and `FileCardViewModel.sharedURL` (`FileCardModel.swift:178-183`) copy the file into `$TMPDIR/AntiChat-dragout/`. That folder is not an `AntiChat-incognito-*` directory, so the launch sweep never removes it.
   - Scenario: an incognito `create_document` produces a PDF card. A thumbnail of the PDF page stays in Caches after the session ends, and so does a named copy if the user dragged or shared the file.
   - Fix: carry the incognito flag into `FileCardItem` (or detect the `AntiChat-incognito-` path, as `AttachmentTileView.swift:211` does). Stage incognito copies under the session's incognito temp dir.

5. **Per-chat DuckDB databases and query results are never released.**
   - `SheetSessions.close` (`Packages/Harness/Sources/AntiChatHarness/Attachments/SheetIntake.swift:77-81`) is never called anywhere.
   - As a result, `DuckDBStore.registry` (`DuckDBStore.swift:70-79`, up to `memory_limit` 256–2048 MB per chat) and `DataRefStore` (`DataRefStore.swift:31-35`, up to 100,000 rows of strings per query, never evicted) grow for the life of the process.
   - Scenario: deleted chats and incognito sessions keep their sheet data in memory. A tool loop that runs 20 queries over a 100k-row sheet keeps 2 M rows of strings. Opening a sheet in several chats multiplies the DuckDB budget.
   - Fix: call `close(chatID:)` on chat close, chat delete and incognito end. Add an LRU cap on stores and on refs per chat (for example the last 20).

6. **"Open" hands the content-addressed blob itself to external apps.**
   `Packages/UI/Sources/AntiChatUI/Artifacts/FileCardModel.swift:185-188` calls `actions.open(item.url)` → `NSWorkspace.open(<Media>/<yyyy>/<sha>.<ext>)`.
   - Defect: blobs are deduplicated by sha256 across versions, chats and attachments (`ArtifactStore.swift:61-66`, `AttachmentIntake.swift:303`), and they are writable.
   - Scenario: the user opens version 1 of a PDF in Preview and annotates or rotates it. Preview autosaves in place. Version 1, plus every attachment or artifact sharing that sha, changes silently. Its sha256 no longer matches, and `extracted/<sha>.md` and the chunks are now stale.
   - Fix: open a named copy, as Copy/Share already do, or make blobs read-only after writing them (chmod 0444).

7. **Scan OCR never resumes after a quit, so the attachment says "still reading" forever.**
   - Defect: `readScans` is only reached from `ingest` (`AttachmentIntake.swift:186-188`), and nothing at launch handles rows left with `ocr_state = 'pending'`.
   - Scenario: the user attaches a 300-page scan and quits at page 40. On every later turn:
     - `DocumentContextAssembler.swift:92-94` reports `stillReadingPage`;
     - `persist` (line 145) forces `token_count` to NULL, so the file is recounted every turn;
     - pages 41–300 are never read.
   - Fix: at launch, resume pending OCR (from the page map), or mark it failed with a "Read again" action.

## P2

8. **The preview sandbox fails open, and the injected CSP can land in the wrong place.**
   File: `Packages/UI/Sources/AntiChatUI/Artifacts/SandboxedWebPreview.swift`.
   - Fail-open: `ruleList` (lines 95-101) swallows compile errors and returns nil. `init` then installs nothing (line 129), and the preview still loads. SVG mode has no CSP at all; HTML mode is left with only the CSP.
   - Rule-list build-up: one rule list per previewed path is compiled into WebKit's persistent `WKContentRuleListStore.default()` and never removed. That includes incognito temp paths.
   - CSP placement: `withCSP` (line 306) and `reactHTML` (line 356) insert the CSP meta after the first `<head[^>]*>` match, and that pattern also matches `<header>`. In a page with no `<head>`, the meta ends up in `<body>`, where WebKit ignores it.
   - Fix: refuse to render (error state) when the rules are nil. Use one static block-all list and rely on `allowingReadAccessTo` for the file. Change the regex to `<head(\s[^>]*)?>`.

9. **The shared `<sha>.md` can drift away from each attachment's unit map.**
   - Defect: the extracted Markdown is one file per sha, but `page_map_json` is per attachment (`AttachmentIntake.swift:180`, `:259-262`). `reusableOCR` only matches `'done'` rows.
   - Scenario: the same scan is attached in two chats while the first is still being OCR'd. Two OCR jobs overwrite the same `.md`, each with its own offsets. `ExtractedDocument.text(of:)` then slices the wrong ranges. `DocumentIndexer.index` (append-only per page) keeps the wrong chunks and page refs under that sha for good, so citations go wrong.
   - Fix: run one OCR job per sha and have later attachments join it, or key the extracted Markdown by attachment.

10. **Password-protected DOCX/XLSX/PPTX is a dead end.**
    `TypeSniffer.swift:133` marks them encrypted, so `admit` shows the password field. But `ingest` can only unlock PDFs (`AttachmentIntake.swift:152-156` → `unlockedPDF`). Every password, including the correct one, returns `.encrypted` with no message. Fix: show unsupported copy for encrypted OOXML, or implement decryption.

11. **Edit selection from an older version records the wrong parent.**
    - Defect: `SidePanelModel.swift:128-135` sends the source of the version on screen, but `ArtifactStore.save` (lines 81-85) always uses max(n) as the parent.
    - Scenario: the user views v1 while v3 exists and runs Edit selection. The result is v4 with `parent_version_id` = v3, although it was built from v1.
    - Fix: pass the base version id through `revises`.

12. **Page citations can point to the wrong file.**
    - Defect: `PageCitePill.owner` (`PageCitePill.swift:17-26`) returns the first file whose page range contains N.
    - Scenario: two whole PDFs are attached, and "(p. 5)" always opens the first one. Also, `writeRows` stores `pages = pageCount ?? slideCount` (`AttachmentIntake.swift:312`), so a PPTX gets page pills that open `PDFPageSheet` on a non-PDF and show a blank sheet.
    - Fix: link only when exactly one file matches (or ask the model to cite with the file name), and validate whole-file page cites only for PDFs.

13. **Untrusted document content can close its own wrapper (NFR-SEC5).**
    `ExtractedDocument.promptBlock` (`ExtractedDocument.swift:63`) and `DocumentContextAssembler.excerpt` (line 204) insert the content unescaped. A file containing `</document>` or `</excerpt>` followed by text produces content that sits outside the untrusted block. Fix: neutralise closing tags inside the body.

14. **Image and page OCR decode without size limits.**
    - `VisionOCR.image` (`VisionOCR.swift:38-44`) fully decodes any attached image. A 40000×40000 PNG, small on disk, needs about 6 GB.
    - `VisionOCR.render` (lines 22-35) sizes the bitmap as mediaBox × 4.17 with no cap. A 14400 pt page gives a 60000² buffer of about 3.6 GB.
    - Fix: decode through a thumbnail with a maximum pixel size (about 4–6k), and cap the render size.

15. **File sniffing runs on the main actor.**
    `IntakeTray.add` / `readmit` (`AttachmentTray.swift:32`, `:46`) call `AttachmentIntake.admit` → `TypeSniffer.sniff` on the main actor. That means `PDFDocument(url:)` for every PDF (`TypeSniffer.swift:142`), and for OLE files `oleKind` scans the whole mapped file up to 3 times. Dropping a few hundred-MB files hangs the UI for seconds. Fix: sniff inside the intake actor.

16. **Incognito extracted text is never dropped.**
    `ExtractedTextStore.forget` has no callers, so incognito document text stays in process memory after the session ends (R-090 says it is "dropped with the session"). Fix: call `forget` when the incognito session ends.

17. **Panel Download fails silently.**
    `ArtifactExport.download` returns nil when there is no data (for example `.pdf` / `.svg` / `.png` while `web` is nil or not loaded yet) or when the write fails (`ArtifactExport.swift:112-123`). `SidePanel.swift:114` ignores the result, so nothing happens and nothing is shown. Fix: show a toast on nil, and disable web-dependent formats until the preview has rendered.

18. **Long non-Latin titles break drag-out.**
    - Defect: `FileOutNames.filename` caps titles at 120 *characters*, and `DragOut.safeName` has no cap at all. A 120-character CJK title is about 360 bytes, over APFS's 255-byte limit.
    - Scenario: `copyItem` fails, so the drag carries an empty `NSItemProvider` and Copy/Share fall back to the `<sha>.ext` blob name.
    - Fix: cap names by UTF-8 bytes (≤ 240).

19. **Image refs resolve across chats.**
    `ArtifactStore.imageData(ref:)` (`ArtifactStore.swift:98-111`) and the matching existence check accept any attachment or artifact id in the database, with no chat filter. A model that learns an id from another chat (memory, injection) can embed that chat's image in a document. Fix: scope the lookup to `chatID`.

20. **A removed tile can still write its attachment row.**
    `IntakeTray.remove` (`AttachmentTray.swift`) only deletes a row whose id is already known. `ingest` checks cancellation only during the copy, so extraction carries on and `writeRows` inserts the row after removal. The result is an orphan draft attachment that is never cleaned up. Fix: check `Task.isCancelled` before `writeRows`, and delete the row after `ingest` if the item is gone.

21. **"Files in this chat" shows the wrong date for attached files.**
    `ChatFilesQuery.swift:37-43` uses `file_blob.created_at`, which is the first upload of that sha anywhere. Re-attaching an old file today shows and sorts it under its original date. Fix: use `attachment.created_at`.

## Checked, no finding

- **RenderHost:** static rules, scheme handler with path checks, CSP, guard script, no message handlers.
- **query_data guard and DuckDB settings:** the single-SELECT check runs on a prepared statement; `enable_external_access` and extensions are off and `lock_configuration` is set last; table and column identifiers are quoted.
- **v13/v14 migrations:** `UNIQUE(artifact_id, n)`, the FK additions are valid, and versions are created in one transaction.
- **create_document:** rejects remote images; produced file extensions are fixed by format.
- **Vega charts:** reject `data.url`.
- **Preview navigation:** `decidePolicyFor` cancels everything after the first load.
- **Other paths:** DragOut strips `/`, `:` and leading dots from names; the XLSX/PPTX vendored adapters are bounded; the image preparer downsamples.

## Overall
The sandboxing work is careful (RenderHost, the DuckDB lockdown, the preview rule lists). The serious gaps are on intake: the AppKit HTML importer can reach the network, and our own zip and image paths have no resource limits.
Incognito promises are not kept everywhere: thumbnail cache, drag-out staging and in-memory text/DuckDB are never cleared. The content-addressed blob store can be mutated through "Open".
Fix P0 #1 and P1 #2, #3 and #6 before calling M6 done. The rest are bounded-impact clean-ups.
