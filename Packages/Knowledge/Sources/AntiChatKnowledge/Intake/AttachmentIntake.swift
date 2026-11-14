// M6.T01 step 4 (R-020 AC1/AC3/AC4; architecture §5.3/§5.4): one file into the chat. Limits are checked before any
// copy (> 20 files → the extra ones are rejected for the `upload.tooMany` toast; > 512 MB → `upload.tooLarge`); then
// the bytes stream (1 MiB chunks, `FileHandle` + CryptoKit SHA-256) into the media store
// `<container>/Media/<yyyy>/<sha256>.<ext>` (dedup by `file_blob.sha256`), the `file_blob(origin: upload)` +
// `attachment` rows go in one transaction (`message_id` nil until the send links it), and `ExtractionService` reads it.
// The extracted Markdown is kept as `<container>/Media/extracted/<sha256>.md` and the unit map in
// `attachment.page_map_json`. Incognito: the copy goes to `NSTemporaryDirectory()/AntiChat-incognito-<uuid>/`, the
// Markdown stays in memory and the rows go to the session's in-memory database only (R-090, architecture §5.4).
import AntiChatFoundation
import AntiChatStorage
import CryptoKit
import Foundation
import GRDB
import PDFKit

/// What a tile shows (components.md AttachmentTile).
public enum IntakeState: Sendable, Equatable {
    /// Copying / extracting; fraction 0…1 (nil = indeterminate).
    case reading(Double?)
    case ready
    /// Couldn't read it: red tile + toast (IS-10). `reason` is for the log, never shown verbatim.
    case failed(reason: String)
    case tooLarge(size: Int64)
    case encrypted
    case unsupported(ext: String)
    /// A password-protected file AntiChat cannot decrypt (Word/Excel/PowerPoint; only PDFs unlock, M6 review #10).
    case locked(ext: String)
    /// M6.T04 (R-271 AC2): a scanned PDF being OCR'd, `page` of `pages` scan pages done (`status.readingScan`). The
    /// attachment row exists and can be sent now (it answers from the pages done so far, `files.stillReading`).
    case scanning(page: Int, pages: Int)
    /// M3.T06 (R-056): an audio file being transcribed in the helper, `percent` 0…100 (real: processed seconds ÷
    /// duration; `status.transcribing`). Not sendable until the transcript is there.
    case transcribing(percent: Double)

    /// The tile can go out with a message (ready, or a scan still being read).
    public var isSendable: Bool {
        switch self {
        case .ready, .scanning: true
        default: false
        }
    }

    public var isTerminalError: Bool {
        switch self {
        case .failed, .tooLarge, .unsupported, .locked: true
        default: false
        }
    }
}

public struct IntakeItem: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var sourceURL: URL
    public var displayName: String
    public var size: Int64
    public var sniff: SniffResult?
    public var state: IntakeState
    /// The `attachment` row, once written.
    public var attachmentID: String?
    /// Where the bytes live now (media store or incognito temp dir).
    public var storedURL: URL?
    public var document: ExtractedDocument?
    /// M3.T06: an audio file's duration (seconds), read at admission.
    public var duration: Double?

    public var kind: AttachmentKind { sniff?.kind ?? .unknown }

    public init(id: UUID = UUID(), sourceURL: URL, displayName: String, size: Int64, sniff: SniffResult?,
                state: IntakeState, attachmentID: String? = nil, storedURL: URL? = nil, document: ExtractedDocument? = nil) {
        self.id = id; self.sourceURL = sourceURL; self.displayName = displayName; self.size = size; self.sniff = sniff
        self.state = state; self.attachmentID = attachmentID; self.storedURL = storedURL; self.document = document
    }
}

/// M6 review #9: the scan OCR jobs running in this process, by where their Markdown lives (`jobKey`) → the document as
/// read so far. Joining a job, each page's write and the job's end all happen under this lock, so a row inserted while
/// a job runs always carries the job's latest page map.
final class OCRJobs: @unchecked Sendable {
    static let shared = OCRJobs()
    private let lock = NSLock()
    private var jobs: [String: ExtractedDocument] = [:]
    func locked<R>(_ body: (inout [String: ExtractedDocument]) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&jobs)
    }
}

public actor AttachmentIntake {
    public let database: AppDatabase
    /// `<container>/Media` (the on-disk store), or the incognito temp dir.
    public let mediaRoot: URL
    public let incognito: Bool
    private let extraction = ExtractionService()
    /// M3.T06: the helper's file transcription (nil = no Voice pack: audio tiles keep `tile.transcriptPending`).
    public let transcriber: (any AudioTranscribing)?
    /// M6.T04: the scan-page queue (paused while a turn generates on T0/T1) and the hardware tier for its level.
    public let ocrQueue: OCRQueue
    public let tier: String

    public init(database: AppDatabase, mediaRoot: URL, incognito: Bool, tier: String = "T1", ocrQueue: OCRQueue = OCRQueue(),
                transcriber: (any AudioTranscribing)? = nil) {
        self.transcriber = transcriber
        self.tier = tier
        self.ocrQueue = ocrQueue
        self.database = database
        self.mediaRoot = mediaRoot
        self.incognito = incognito
    }

    /// The app's intake: `<container>/Media`.
    public static func defaultMediaRoot() -> URL {
        AppDatabase.containerURL().appendingPathComponent("Media", isDirectory: true)
    }

    /// A fresh incognito temp dir (removed with the session; nothing else on disk), created now with this process as
    /// its owner so another AntiChat process's launch sweep never deletes it while it is in use (IncognitoTemp).
    public static func incognitoRoot() -> URL { IncognitoTemp.make() }

    // MARK: limits (synchronous part, before any copy)

    public struct Admission: Sendable {
        /// Tiles to show (some already in an error state: too large / unsupported).
        public var items: [IntakeItem]
        /// Files beyond the 20-file limit (the `upload.tooMany` toast).
        public var rejected: [URL]
    }

    /// Step 4, first bullet: count and size limits, then the sniff. `existing` = tiles already in the tray.
    public nonisolated static func admit(_ urls: [URL], existing: Int = 0) -> Admission {
        var a = admitLimits(urls, existing: existing)
        a.items = a.items.map(sniffed)
        return a
    }

    /// The limits only (file count, size from the file's metadata): cheap enough for the main actor. The sniff (which
    /// opens PDFs and scans OLE files) runs in `ingest`, on the intake actor (M6 review #15).
    public nonisolated static func admitLimits(_ urls: [URL], existing: Int = 0) -> Admission {
        let room = max(0, AttachmentLimits.maxFiles - existing)
        let accepted = Array(urls.prefix(room))
        let items = accepted.map { url -> IntakeItem in
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]))?.fileSize ?? 0)
            var item = IntakeItem(id: UUID(), sourceURL: url, displayName: url.lastPathComponent, size: size, sniff: nil,
                                  state: .reading(nil))
            if size > AttachmentLimits.maxFileBytes { item.state = .tooLarge(size: size) }
            return item
        }
        return Admission(items: items, rejected: Array(urls.dropFirst(room)))
    }

    /// The sniff step of `admit` for an item that passed the limits.
    public nonisolated static func sniffed(_ admitted: IntakeItem) -> IntakeItem {
        var item = admitted
        guard item.sniff == nil, item.state == .reading(nil) else { return item }
        guard let sniff = try? TypeSniffer.sniff(item.sourceURL) else {
            item.state = .failed(reason: "unreadable")
            return item
        }
        item.sniff = sniff
        // M3.T06 step 1: audio over 3 h is refused like a file over 512 MB, before any transcription.
        if sniff.kind.isAudio {
            item.duration = AudioIntakeAdapter.duration(item.sourceURL)
            if AudioIntakeAdapter.isTooLarge(size: item.size, duration: item.duration) {
                item.state = .tooLarge(size: item.size)
                return item
            }
        }
        if !ExtractionService.readsNow(sniff.kind) { item.state = .unsupported(ext: sniff.ext) }
        else if sniff.isEncrypted { item.state = sniff.kind == .pdf ? .encrypted : .locked(ext: sniff.ext) }
        return item
    }

    // MARK: ingest

    /// The tile fraction for an extraction fraction: 0.3 (copied) … 0.9 (extracted); `ready` is the only 100 %.
    public nonisolated static func extractionShare(_ f: Double) -> Double { 0.3 + 0.6 * min(1, max(0, f)) }

    /// Copy + rows + extraction for an admitted item; `onUpdate` sees each state change. Errors end in `.failed`.
    /// An encrypted PDF waits for `password` (kept in memory only, never stored).
    public func ingest(_ admitted: IntakeItem, password: String? = nil,
                       onUpdate: @escaping @Sendable (IntakeItem) -> Void = { _ in }) async -> IntakeItem {
        var item = Self.sniffed(admitted)
        guard let sniff = item.sniff else { onUpdate(item); return item }
        switch item.state {
        case .tooLarge, .unsupported, .failed, .locked: onUpdate(item); return item
        case .encrypted where password == nil: onUpdate(item); return item
        default: break
        }
        item.state = .reading(0)
        onUpdate(item)
        do {
            let (sha, stored) = try copyIntoStore(item.sourceURL, kind: sniff.kind)
            item.storedURL = stored
            let size = Int64((try? stored.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int(item.size))
            item.size = size
            item.state = .reading(0.3)
            onUpdate(item)
            var doc: ExtractedDocument
            if sniff.isEncrypted {
                guard let password, let unlocked = Self.unlockedPDF(stored, password: password) else {
                    item.state = .encrypted
                    return item
                }
                doc = unlocked
            } else {
                let progress: @Sendable (ExtractionProgress) -> Void = { [item] p in
                    var shown = item
                    // VQ-M10 S-14: extraction is 30…90 %; the text recognition and row writes after it are the
                    // last 10 %. Before, extraction alone reached 100 % and the tile read "Reading… 100%" while
                    // the rows were still being written.
                    shown.state = .reading(Self.extractionShare(p.fraction))
                    onUpdate(shown)
                }
                doc = try await extraction.extract(url: stored, kind: sniff.kind, onProgress: progress)
                item.state = .reading(Self.extractionShare(1))
                onUpdate(item)
            }
            // M6.T04 step 3 (R-271 AC1): an image always gets its OCR text (hidden context "Text found in image").
            var ocrText: String?
            if sniff.kind.isImage, let (image, orientation) = VisionOCR.image(at: stored) {
                ocrText = await VisionOCR().recognize(image, orientation: orientation)
            }
            // Step 1: scanned pages of a PDF (text layer below 20 characters) are OCR'd below, after the row exists.
            var scans = sniff.kind == .pdf ? ScanDetector.scanPages(doc) : []
            var reused = false
            if !scans.isEmpty, let earlier = reusableOCR(sha: sha) {  // the same scan was read before (dedup by sha256)
                doc = earlier
                scans = []
                reused = true
            }
            // M6 review #20: a tile removed while it was read writes no row.
            try Task.checkCancellation()
            // M3.T06 step 2–3: an audio file's text is its timestamped transcript, made in the helper with a real %.
            if sniff.kind.isAudio, let transcriber, await transcriber.isAvailable() {
                item.state = .transcribing(percent: 0)
                onUpdate(item)
                let shown = item
                let t = try await transcriber.transcribe(stored) { p in
                    var u = shown
                    u.state = .transcribing(percent: min(100, max(0, p)))
                    onUpdate(u)
                }
                doc = ExtractedDocument(markdown: t.text)
            }
            let ocrState: OCRState = !scans.isEmpty ? .pending : reused ? .done
                : sniff.kind.isImage ? (ocrText == nil ? .failed : .done) : .none
            let text = ocrText.flatMap { $0.isEmpty ? nil : $0 }
            if scans.isEmpty {
                item.document = doc
                try saveMarkdown(doc.markdown, sha: sha)
                item.attachmentID = try writeRows(item, sha: sha, size: size, stored: stored, doc: doc, ocrState: ocrState,
                                                  ocrText: text)
            } else {
                // M6 review #9: one OCR job per `<sha>.md`. A scan already being read is joined (this row takes the job's
                // current page map; the job keeps every pending row of the sha in step) instead of a second job writing
                // the same Markdown with its own offsets. Join-or-start and the row insert happen under the job lock.
                let key = jobKey(sha)
                let (id, started) = try OCRJobs.shared.locked { jobs -> (String, Bool) in
                    var started = false
                    if let running = jobs[key] {
                        doc = running
                    } else {
                        jobs[key] = doc
                        started = true
                        try saveMarkdown(doc.markdown, sha: sha, overwrite: true)
                    }
                    let id = try writeRows(item, sha: sha, size: size, stored: stored, doc: doc, ocrState: .pending,
                                           ocrText: text)
                    return (id, started)
                }
                item.document = doc
                item.attachmentID = id
                if started {
                    item.document = await readScans(doc, pages: scans, url: stored, sha: sha, attachmentID: id, item: item,
                                                    onUpdate: onUpdate)
                }
            }
            item.state = .ready
        } catch {
            item.state = .failed(reason: String(describing: error))
        }
        onUpdate(item)
        return item
    }

    /// The extracted Markdown of a stored blob (incognito: memory).
    public func markdown(sha256: String) -> String? {
        if let m = ExtractedTextStore.shared.memory(sha256) { return m }
        return try? String(contentsOf: extractedURL(sha256), encoding: .utf8)
    }

    public nonisolated func extractedURL(_ sha: String) -> URL {
        mediaRoot.appendingPathComponent("extracted", isDirectory: true).appendingPathComponent("\(sha).md")
    }

    // MARK: steps

    /// Streams the source into the store as `<yyyy>/<sha256>.<ext>`; an identical file already there is reused.
    func copyIntoStore(_ src: URL, kind: AttachmentKind, now: Date = Date()) throws -> (sha: String, url: URL) {
        let ext = kind.canonicalExtension ?? src.pathExtension.lowercased()
        let year = String(Calendar(identifier: .gregorian).component(.year, from: now))
        let dir = incognito ? mediaRoot : mediaRoot.appendingPathComponent(year, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".intake-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let input = try FileHandle(forReadingFrom: src)
        let output = try FileHandle(forWritingTo: tmp)
        var hasher = SHA256()
        do {
            defer { try? input.close(); try? output.close() }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        let sha = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let dst = dir.appendingPathComponent(ext.isEmpty ? sha : "\(sha).\(ext)")
        if FileManager.default.fileExists(atPath: dst.path) {
            try? FileManager.default.removeItem(at: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: dst)
        }
        return (sha, dst)
    }

    /// M6.T04 steps 2/4/5: OCR of the scan pages in page order. After each page: the Markdown + unit map are updated
    /// (a turn sent now reads the pages done so far), the registry holds the last page read in order
    /// (`files.stillReading`), the tile shows `status.readingScan` page n of N. At the end: `ocr_state` done (failed if
    /// cut short), the cached token count is dropped so the next turn counts (and indexes) the whole text.
    /// M6 review #9: the caller registered the job (`OCRJobs`); every pending attachment row of the sha follows each
    /// page (rows that joined the job included), and the job ends under the same lock.
    func readScans(_ doc: ExtractedDocument, pages: [Int], url: URL, sha: String, attachmentID: String, item: IntakeItem?,
                   onUpdate: @escaping @Sendable (IntakeItem) -> Void) async -> ExtractedDocument {
        let key = jobKey(sha)
        var texts: [Int: String] = [:]
        var current = doc
        let registry = OCRProgressRegistry.shared
        registry.set(attachmentID, page: (pages.first ?? 1) - 1)
        var shown = item
        shown?.state = .scanning(page: 0, pages: pages.count)
        shown.map(onUpdate)
        let total = doc.pageCount ?? pages.count
        let pendingOfSha = """
            UPDATE attachment SET page_map_json = ?, token_count = NULL
            WHERE ocr_state = 'pending' AND blob_id IN (SELECT id FROM file_blob WHERE sha256 = ?)
            """
        for await p in ocrQueue.run(url: url, pages: pages, level: OCRQueue.level(tier: tier, pages: total)) {
            texts[p.page] = p.markdown
            current = doc.replacingPages(texts)
            let snapshot = current
            OCRJobs.shared.locked { jobs in
                jobs[key] = snapshot
                try? saveMarkdown(snapshot.markdown, sha: sha, overwrite: true)
                _ = try? database.write { db in try db.execute(sql: pendingOfSha, arguments: [snapshot.unitsJSON, sha]) }
            }
            registry.set(attachmentID, page: pages.dropFirst(p.done).first.map { $0 - 1 } ?? total)
            shown?.document = current
            shown?.state = .scanning(page: p.done, pages: p.total)
            shown.map(onUpdate)
        }
        let complete = texts.count == pages.count
        let final = current
        OCRJobs.shared.locked { jobs in
            jobs[key] = nil
            _ = try? database.write { db in
                try db.execute(sql: """
                    UPDATE attachment SET ocr_state = ?, page_map_json = ?, token_count = NULL
                    WHERE ocr_state = 'pending' AND blob_id IN (SELECT id FROM file_blob WHERE sha256 = ?)
                    """, arguments: [(complete ? OCRState.done : .failed).rawValue, final.unitsJSON, sha])
            }
        }
        registry.set(attachmentID, page: nil)
        return current
    }

    /// The `OCRJobs` key: where this store keeps the sha's Markdown (incognito: process memory, keyed by sha).
    nonisolated func jobKey(_ sha: String) -> String {
        incognito ? "memory|\(sha)" : extractedURL(sha).path
    }

    // MARK: launch (M6 review #7)

    /// Launch: resumes the OCR of every scan left `pending` by a quit or crash, in the background (the app store).
    public nonisolated static func resumePendingOCR(database: AppDatabase, mediaRoot: URL = defaultMediaRoot(), tier: String) {
        Task.detached(priority: .utility) {
            await AttachmentIntake(database: database, mediaRoot: mediaRoot, incognito: false, tier: tier).resumePendingOCR()
        }
    }

    /// Every scan whose OCR was cut short (`ocr_state = 'pending'` with no job running) continues from the pages still
    /// without text (the saved Markdown + page map); one whose file or text is gone is marked failed, so it never
    /// stays "still reading". Returns the attachment ids it resumed or settled.
    @discardableResult
    public func resumePendingOCR() async -> [String] {
        let rows: [(id: String, map: String?, sha: String, path: String)] = (try? database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.id, a.page_map_json, b.sha256, b.path FROM attachment a JOIN file_blob b ON b.id = a.blob_id
                WHERE a.ocr_state = 'pending' ORDER BY a.created_at
                """).map { ($0["id"], $0["page_map_json"], $0["sha256"], $0["path"]) }
        }) ?? []
        var settled: [String] = []
        var seen = Set<String>()
        for r in rows where seen.insert(r.sha).inserted {
            let key = jobKey(r.sha)
            let url = URL(fileURLWithPath: r.path)
            let units = r.map.flatMap { try? JSONDecoder().decode([ExtractedDocument.Unit].self, from: Data($0.utf8)) }
            let doc = markdown(sha256: r.sha).flatMap { md in units.map { ExtractedDocument(markdown: md, units: $0) } }
            let scans = doc.map(ScanDetector.scanPages) ?? []
            let usable = doc != nil && FileManager.default.fileExists(atPath: url.path)
            let start: Bool = OCRJobs.shared.locked { jobs in
                guard jobs[key] == nil else { return false }  // a job is reading it now
                if usable, !scans.isEmpty, let doc { jobs[key] = doc; return true }
                _ = try? database.write { db in
                    try db.execute(sql: """
                        UPDATE attachment SET ocr_state = ?, token_count = NULL
                        WHERE ocr_state = 'pending' AND blob_id IN (SELECT id FROM file_blob WHERE sha256 = ?)
                        """, arguments: [(usable ? OCRState.done : .failed).rawValue, r.sha])
                }
                return false
            }
            settled.append(r.id)
            if start, let doc {
                _ = await readScans(doc, pages: scans, url: url, sha: r.sha, attachmentID: r.id, item: nil, onUpdate: { _ in })
            }
        }
        return settled
    }

    /// An earlier attachment of the same blob whose OCR finished: its Markdown and unit map.
    func reusableOCR(sha: String) -> ExtractedDocument? {
        guard let row = try? database.read({ db in
            try AttachmentRecord.filter(sql: """
                ocr_state = 'done' AND page_map_json IS NOT NULL AND blob_id IN (SELECT id FROM file_blob WHERE sha256 = ?)
                """, arguments: [sha]).fetchOne(db)
        }), let json = row.pageMapJSON, let md = markdown(sha256: sha),
              let units = try? JSONDecoder().decode([ExtractedDocument.Unit].self, from: Data(json.utf8)) else { return nil }
        return ExtractedDocument(markdown: md, units: units)
    }

    func saveMarkdown(_ md: String, sha: String, overwrite: Bool = false) throws {
        if incognito { ExtractedTextStore.shared.putMemory(sha, md); return }
        let url = extractedURL(sha)
        guard overwrite || !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(md.utf8).write(to: url, options: .atomic)
    }

    /// `file_blob` (reused by sha256) + `attachment` in one transaction.
    func writeRows(_ item: IntakeItem, sha: String, size: Int64, stored: URL, doc: ExtractedDocument,
                   ocrState: OCRState? = nil, ocrText: String? = nil, now: Date = Date()) throws -> String {
        let kind = item.kind
        return try database.write { db in
            let blob: FileBlobRecord
            if let existing = try FileBlobRecord.filter(Column("sha256") == sha).fetchOne(db) {
                blob = existing
            } else {
                blob = FileBlobRecord(sha256: sha, size: size, path: stored.path, createdAt: now, origin: .upload)
                try blob.insert(db)
            }
            var record = AttachmentRecord(
                messageID: nil, blobID: blob.id, displayName: item.displayName,
                uti: item.sniff?.uttype.identifier ?? kind.utType.identifier,
                pages: doc.pageCount ?? doc.slideCount, ocrState: ocrState ?? (kind.isImage ? .pending : .none),
                createdAt: now, extractState: .ready, pageMapJSON: doc.units.isEmpty ? nil : doc.unitsJSON)
            record.ocrText = ocrText
            try record.insert(db)
            return record.id
        }
    }

    /// An encrypted PDF opened with the user's password: page text through PDFKit (the adapter cannot unlock).
    static func unlockedPDF(_ url: URL, password: String) -> ExtractedDocument? {
        guard let pdf = PDFDocument(url: url), pdf.unlock(withPassword: password), !pdf.isLocked else { return nil }
        var md = MarkdownBuilder()
        for i in 0..<pdf.pageCount {
            md.unit(.page, index: i + 1, (pdf.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return md.build()
    }
}
