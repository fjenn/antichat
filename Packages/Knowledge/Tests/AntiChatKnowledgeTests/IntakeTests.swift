// AT-020 checks 1/3 (R-020 AC1/AC3; M6.T01 step 4): limits before any copy (21 files → 20 + rejected; 513 MB sparse
// file → too large), the media store path `<yyyy>/<sha256>.<ext>`, dedup by sha256 (one blob, two attachments), the
// rows (file_blob origin upload + attachment with extract_state ready + page map), the extracted Markdown blob, the
// encrypted tile and its password, a corrupt PDF ending in `.failed`, and incognito writing only to its temp dir.
//   make test-unit FILTER=IntakeTests
import AntiChatStorage
import Foundation
import GRDB
import Testing
@testable import AntiChatKnowledge

@Suite struct IntakeTests {
    @Test func twentyOneFilesAdmitTwenty() {
        let urls = (0..<21).map { _ in IntakeFixtures.url("docs/text/sample.txt") }
        let a = AttachmentIntake.admit(urls)
        #expect(a.items.count == 20)
        #expect(a.rejected.count == 1)
        #expect(AttachmentIntake.admit(urls, existing: 19).items.count == 1)
    }

    @Test func tooLargeIsRefusedBeforeCopying() throws {
        let dir = try IntakeFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("big.pdf")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let h = try FileHandle(forWritingTo: big)
        try h.truncate(atOffset: UInt64(513 * 1024 * 1024))  // sparse: no real 513 MB on disk
        try h.close()
        let a = AttachmentIntake.admit([big])
        #expect(a.items.first?.state == .tooLarge(size: 513 * 1024 * 1024))
        let exactly = dir.appendingPathComponent("edge.txt")
        FileManager.default.createFile(atPath: exactly.path, contents: nil)
        let e = try FileHandle(forWritingTo: exactly)
        try e.truncate(atOffset: UInt64(AttachmentLimits.maxFileBytes))
        try e.close()
        if case .tooLarge = AttachmentIntake.admit([exactly]).items.first?.state { Issue.record("512 MB exactly is allowed") }
    }

    @Test func ingestCopiesDedupsAndWritesRows() async throws {
        let dir = try IntakeFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite"))
        let media = dir.appendingPathComponent("Media", isDirectory: true)
        let intake = AttachmentIntake(database: db, mediaRoot: media, incognito: false)
        let src = IntakeFixtures.url("docs/pdf/text-10p.pdf")
        let adm = AttachmentIntake.admit([src, src])
        let seen = UpdateLog()
        let first = await intake.ingest(adm.items[0]) { seen.add($0.state) }
        let second = await intake.ingest(adm.items[1])
        #expect(first.state == .ready)
        #expect(second.state == .ready)
        #expect(seen.states.first == .reading(0) && seen.states.last == .ready)
        let year = String(Calendar(identifier: .gregorian).component(.year, from: Date()))
        let stored = try #require(first.storedURL)
        #expect(stored.deletingLastPathComponent().lastPathComponent == year)
        #expect(stored.pathExtension == "pdf" && stored.deletingPathExtension().lastPathComponent.count == 64)
        #expect(first.storedURL == second.storedURL)
        try db.read { d in
            #expect(try FileBlobRecord.fetchCount(d) == 1)
            let rows = try AttachmentRecord.order(Column("created_at")).fetchAll(d)
            #expect(rows.count == 2)
            #expect(rows.allSatisfy { $0.messageID == nil && $0.extractState == .ready && $0.pages == 10 })
            #expect(rows.first?.pageMapJSON?.contains("\"kind\":\"page\"") == true)
            #expect(try FileBlobRecord.fetchOne(d)?.origin == .upload)
        }
        let sha = stored.deletingPathExtension().lastPathComponent
        #expect(FileManager.default.fileExists(atPath: media.appendingPathComponent("extracted/\(sha).md").path))
        #expect(await intake.markdown(sha256: sha)?.isEmpty == false)
    }

    @Test func heicNamedJPGIsStoredAsHEIC() async throws {
        let dir = try IntakeFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let intake = AttachmentIntake(database: try AppDatabase.inMemory(), mediaRoot: dir, incognito: true)
        let adm = AttachmentIntake.admit([IntakeFixtures.url("images/upload-errors/heic-named.jpg")])
        let item = await intake.ingest(adm.items[0])
        #expect(item.state == .ready)
        #expect(item.storedURL?.pathExtension == "heic")
        #expect(item.sniff?.isLying == true)
    }

    @Test func encryptedWaitsForThePassword() async throws {
        let dir = try IntakeFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let intake = AttachmentIntake(database: try AppDatabase.inMemory(), mediaRoot: dir, incognito: true)
        let adm = AttachmentIntake.admit([IntakeFixtures.url("docs/pdf/encrypted.pdf")])
        #expect(adm.items[0].state == .encrypted)
        #expect(await intake.ingest(adm.items[0]).state == .encrypted)
        #expect(await intake.ingest(adm.items[0], password: "wrong").state == .encrypted)
        let open = await intake.ingest(adm.items[0], password: "antichat")
        #expect(open.state == .ready)
        #expect(open.document?.pageCount == 2)
        #expect(open.document?.markdown.contains("Encrypted fixture page 1") == true)
    }

    @Test func corruptPDFEndsFailed() async throws {
        let dir = try IntakeFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase.inMemory()
        let intake = AttachmentIntake(database: db, mediaRoot: dir, incognito: true)
        let adm = AttachmentIntake.admit([IntakeFixtures.url("docs/pdf/corrupt.pdf")])
        let item = await intake.ingest(adm.items[0])
        guard case .failed = item.state else { Issue.record("expected failed, got \(item.state)"); return }
        #expect(try db.read { try AttachmentRecord.fetchCount($0) } == 0)
    }

    @Test func incognitoWritesOnlyItsTempDir() async throws {
        let root = AttachmentIntake.incognitoRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(root.lastPathComponent.hasPrefix("AntiChat-incognito-"))
        let db = try AppDatabase.inMemory()
        let intake = AttachmentIntake(database: db, mediaRoot: root, incognito: true)
        let item = await intake.ingest(AttachmentIntake.admit([IntakeFixtures.url("docs/office/report.docx")]).items[0])
        #expect(item.state == .ready)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }  // + `.owner`
        #expect(files.count == 1 && files[0].hasSuffix(".docx"), "\(files)")  // no extracted/ folder: Markdown in memory
        let sha = String(files[0].dropLast(5))
        #expect(await intake.markdown(sha256: sha)?.isEmpty == false)
        #expect(db.isInMemory)
    }
}

final class UpdateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var s: [IntakeState] = []
    func add(_ x: IntakeState) { lock.withLock { s.append(x) } }
    var states: [IntakeState] { lock.withLock { s } }
}
