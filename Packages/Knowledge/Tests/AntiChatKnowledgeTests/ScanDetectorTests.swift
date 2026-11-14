// AT-271 check 1 (R-271 AC1; M6.T04 step 1): a PDF page needs OCR iff its text layer has < 20 non-blank characters
// (19 → OCR, 20 / 21 → not); a mixed text + scan PDF only OCRs its scan pages, which then carry text; an image
// always gets OCR text (`attachment.ocr_text`, ocr_state done).
//   make test-unit FILTER=ScanDetectorTests
import AntiChatStorage
import AppKit
import CoreText
import Foundation
import GRDB
import PDFKit
import Testing
@testable import AntiChatKnowledge

enum ScanPDF {
    /// A one-page PDF whose text layer is exactly `text`.
    static func textPage(_ text: String) -> PDFPage {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)!.page(at: 0)!
    }

    /// The first page of a scan fixture (image only).
    static func scanPage(_ rel: String) -> PDFPage { PDFDocument(url: IntakeFixtures.url(rel))!.page(at: 0)! }

    /// text-10p.pdf with the scan page inserted as page 3.
    static func mixed(to url: URL) -> URL {
        let doc = PDFDocument(url: IntakeFixtures.url("docs/pdf/text-10p.pdf"))!
        doc.insert(scanPage("docs/ocr-30p/page-01.pdf"), at: 2)
        doc.write(to: url)
        return url
    }
}

@Suite struct ScanDetectorTests {
    @Test func thresholdIsTwentyCharacters() {
        #expect(ScanDetector.needsOCR(String(repeating: "a", count: 19)))
        #expect(!ScanDetector.needsOCR(String(repeating: "a", count: 20)))
        #expect(!ScanDetector.needsOCR(String(repeating: "a", count: 21)))
        #expect(ScanDetector.needsOCR("  \n" + String(repeating: "b", count: 19) + "\n\t "))
        #expect(ScanDetector.needsOCR(nil) && ScanDetector.needsOCR(""))
    }

    @Test func pdfTextLayersAtTheBoundary() {
        let doc = PDFDocument()
        for (i, n) in [19, 20, 21].enumerated() { doc.insert(ScanPDF.textPage(String(repeating: "x", count: n)), at: i) }
        doc.insert(ScanPDF.scanPage("docs/ocr-30p/page-02.pdf"), at: 3)
        #expect(ScanDetector.scanPages(doc) == [1, 4])
    }

    @Test func mixedPDFOnlyOCRsItsScanPages() async throws {
        let dir = try IntakeFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = ScanPDF.mixed(to: dir.appendingPathComponent("mixed.pdf"))
        let before = try #require(try? await ExtractionService().extract(url: url, kind: .pdf))
        #expect(ScanDetector.scanPages(before) == [3], "\(before.units.map { before.text(of: $0).count }) \(PDFDocument(url: url)?.pageCount ?? -1)")
        let db = try AppDatabase.inMemory()
        let intake = AttachmentIntake(database: db, mediaRoot: dir.appendingPathComponent("media"), incognito: true)
        let states = StateLog()
        let item = await intake.ingest(AttachmentIntake.admit([url]).items[0]) { states.add($0.state) }
        #expect(item.state == .ready)
        let doc = try #require(item.document)
        #expect(ScanDetector.scanPages(doc).isEmpty, "page 3 now has OCR text")
        let p3 = doc.text(of: doc.units[2])
        #expect(p3.contains("Notes 1"), "\(p3.prefix(200))")
        for i in [0, 1, 3] { #expect(doc.text(of: doc.units[i]) == before.text(of: before.units[i]), "text pages untouched") }
        #expect(states.all.contains(.scanning(page: 0, pages: 1)) && states.all.contains(.scanning(page: 1, pages: 1)))
        let row = try #require(try db.read { try AttachmentRecord.fetchOne($0, key: item.attachmentID!) })
        #expect(row.ocrState == .done && row.tokenCount == nil)
        // The same scan again: the earlier OCR is reused (no second run).
        let again = await intake.ingest(AttachmentIntake.admit([url]).items[0])
        #expect(again.document?.markdown == doc.markdown)
    }

    @Test func imagesAlwaysGetOCRText() async throws {
        let dir = try IntakeFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase.inMemory()
        let intake = AttachmentIntake(database: db, mediaRoot: dir, incognito: true)
        let png = IntakeFixtures.url("images/ocr/doc-01.png")
        let item = await intake.ingest(AttachmentIntake.admit([png]).items[0])
        let row = try #require(try db.read { try AttachmentRecord.fetchOne($0, key: item.attachmentID!) })
        #expect(row.ocrState == .done)
        #expect((row.ocrText ?? "").count > 40, "\(row.ocrText ?? "nil")")
    }
}

final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [IntakeState] = []
    func add(_ s: IntakeState) { lock.withLock { states.append(s) } }
    var all: [IntakeState] { lock.withLock { states } }
}
