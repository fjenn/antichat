// M6 review #7 (scan OCR resumes after a quit), #9 (one OCR job per sha; joiners follow its page map), #10
// (password-protected Office files end as `locked`, not a password field that can never work), #20 (a tile removed
// while it is read writes no row).
//   make test-unit FILTER=IntakeReviewTests
import AntiChatStorage
import Foundation
import GRDB
import PDFKit
import Testing
@testable import AntiChatKnowledge

@Suite(.serialized) struct IntakeReviewTests {
    struct Rig {
        let dir: URL, db: AppDatabase, media: URL, intake: AttachmentIntake
        init() throws {
            dir = try IntakeFixtures.scratch()
            db = try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite"))
            media = dir.appendingPathComponent("Media", isDirectory: true)
            intake = AttachmentIntake(database: db, mediaRoot: media, incognito: false)
        }
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
        /// The first `pages` pages of the 60-page scan fixture (image-only pages).
        func scan(_ name: String = "scan.pdf", pages: Int = 3) throws -> URL {
            let src = try #require(PDFDocument(url: IntakeFixtures.url("docs/pdf/scan-60p-contract.pdf")))
            let out = PDFDocument()
            for i in 0..<pages { out.insert(src.page(at: i)!.copy() as! PDFPage, at: i) }
            let url = dir.appendingPathComponent(name)
            #expect(out.write(to: url))
            return url
        }
        func rows() throws -> [AttachmentRecord] { try db.read { try AttachmentRecord.order(Column("created_at")).fetchAll($0) } }
    }

    @Test func pendingScanResumesAfterAQuit() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let item = await rig.intake.ingest(AttachmentIntake.admit([try rig.scan()]).items[0])
        let full = try #require(item.document)
        let sha = try #require(item.storedURL).deletingPathExtension().lastPathComponent
        #expect(ScanDetector.scanPages(full).isEmpty, "the scan was read")
        // The state a quit after page 1 leaves: pages 2–3 without text, the row pending.
        let cut = full.replacingPages([2: "", 3: ""])
        try Data(cut.markdown.utf8).write(to: rig.media.appendingPathComponent("extracted/\(sha).md"))
        try rig.db.write { db in
            try db.execute(sql: "UPDATE attachment SET ocr_state = 'pending', page_map_json = ?", arguments: [cut.unitsJSON])
        }
        // A new launch: nothing but the resume touches the row.
        let relaunched = AttachmentIntake(database: rig.db, mediaRoot: rig.media, incognito: false)
        #expect(try rig.rows().first?.ocrState == .pending)
        #expect(await relaunched.resumePendingOCR().count == 1)
        let row = try #require(try rig.rows().first)
        #expect(row.ocrState == .done)
        let md = try String(contentsOf: rig.media.appendingPathComponent("extracted/\(sha).md"), encoding: .utf8)
        let units = try JSONDecoder().decode([ExtractedDocument.Unit].self, from: Data(try #require(row.pageMapJSON).utf8))
        let doc = ExtractedDocument(markdown: md, units: units)
        #expect(ScanDetector.scanPages(doc).isEmpty, "pages 2–3 were read on resume")
        #expect(doc.text(of: doc.units[0]) == full.text(of: full.units[0]))
    }

    @Test func pendingScanWithoutItsFileIsMarkedFailed() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let item = await rig.intake.ingest(AttachmentIntake.admit([try rig.scan()]).items[0])
        try rig.db.write { db in try db.execute(sql: "UPDATE attachment SET ocr_state = 'pending'") }
        try FileManager.default.removeItem(at: try #require(item.storedURL))
        _ = await rig.intake.resumePendingOCR()
        #expect(try rig.rows().first?.ocrState == .failed)
    }

    @Test func sameScanAttachedTwiceRunsOneOCRJob() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let a = try rig.scan("a.pdf"), b = try rig.dir.appendingPathComponent("b.pdf")
        try FileManager.default.copyItem(at: a, to: b)
        let items = AttachmentIntake.admit([a, b]).items
        let logA = UpdateLog(), logB = UpdateLog()
        async let ra = rig.intake.ingest(items[0]) { logA.add($0.state) }
        async let rb = rig.intake.ingest(items[1]) { logB.add($0.state) }
        let (x, y) = await (ra, rb)
        #expect(x.state == .ready && y.state == .ready)
        let scanning = { (l: UpdateLog) in l.states.contains { if case .scanning = $0 { true } else { false } } }
        #expect(scanning(logA) != scanning(logB), "exactly one of the two attachments ran the OCR job")
        let rows = try rig.rows()
        #expect(rows.count == 2 && rows.allSatisfy { $0.ocrState == .done })
        #expect(rows[0].pageMapJSON == rows[1].pageMapJSON, "both rows follow the one Markdown file")
        let sha = try #require(x.storedURL).deletingPathExtension().lastPathComponent
        let md = try String(contentsOf: rig.media.appendingPathComponent("extracted/\(sha).md"), encoding: .utf8)
        let units = try JSONDecoder().decode([ExtractedDocument.Unit].self, from: Data(try #require(rows[1].pageMapJSON).utf8))
        #expect(ScanDetector.scanPages(ExtractedDocument(markdown: md, units: units)).isEmpty)
    }

    /// An OLE container with an `EncryptedPackage` stream (what Office writes for a password-protected .docx).
    static func encryptedOOXML(in dir: URL, ext: String) throws -> URL {
        var d = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        d.append(Data(count: 504))
        d.append(Data("EncryptedPackage".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }))
        d.append(Data(count: 2048))
        let url = dir.appendingPathComponent("secret.\(ext)")
        try d.write(to: url)
        return url
    }

    @Test(arguments: ["docx", "xlsx", "pptx"]) func passwordProtectedOfficeIsLocked(_ ext: String) async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let url = try Self.encryptedOOXML(in: rig.dir, ext: ext)
        let item = AttachmentIntake.admit([url]).items[0]
        #expect(item.state == .locked(ext: ext), "no password field for a file only a PDF password could open")
        #expect(item.state.isTerminalError)
        #expect(await rig.intake.ingest(item, password: "right or wrong").state == .locked(ext: ext))
        #expect(try rig.rows().isEmpty)
        // A password-protected PDF still asks.
        #expect(AttachmentIntake.admit([IntakeFixtures.url("docs/pdf/encrypted.pdf")]).items[0].state == .encrypted)
    }

    @Test func removedWhileReadingWritesNoRow() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let item = AttachmentIntake.admit([IntakeFixtures.url("docs/office/report.docx")]).items[0]
        let intake = rig.intake
        // × on the tile after the copy, while the text is extracted (IntakeTray.remove cancels the read task).
        let final = await Task {
            await intake.ingest(item) { update in
                if update.state == .reading(0.3) { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }.value
        #expect(final.attachmentID == nil)
        #expect(try rig.rows().isEmpty, "a removed tile left an orphan draft row")
    }

    @Test func admitLimitsDoesNotSniff() {
        let a = AttachmentIntake.admitLimits([IntakeFixtures.url("docs/pdf/text-10p.pdf")])
        #expect(a.items[0].sniff == nil && a.items[0].state == .reading(nil))
        #expect(AttachmentIntake.sniffed(a.items[0]).sniff?.kind == .pdf)
    }
}
