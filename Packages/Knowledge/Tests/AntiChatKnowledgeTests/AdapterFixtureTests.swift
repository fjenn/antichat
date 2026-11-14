// AT-020 check 2 (R-020 AC2; M6.T01 step 5): every AC2 format extracts non-empty Markdown with the expected unit count
// from fixtures/docs/** and the images; writes the per-format table to build/at/AT-020/<date>/formats.json.
//   make test-unit FILTER=AdapterFixtureTests
import Foundation
import Testing
@testable import AntiChatKnowledge

@Suite(.serialized) struct AdapterFixtureTests {
    struct Case: Sendable, CustomStringConvertible {
        let path: String, kind: AttachmentKind, unit: ExtractedDocument.UnitKind?, units: Int, needle: String?
        var description: String { path }
    }

    static let cases: [Case] = [
        .init(path: "docs/pdf/text-10p.pdf", kind: .pdf, unit: .page, units: 10, needle: nil),
        .init(path: "docs/office/report.docx", kind: .docx, unit: .section, units: 1, needle: "# Quarterly report\n\n## Summary"),
        .init(path: "docs/office/budget.xlsx", kind: .xlsx, unit: .sheet, units: 2, needle: "## Sheet: Budget"),
        .init(path: "docs/office/legacy.xls", kind: .xls, unit: .sheet, units: 2, needle: "## Sheet: Orders"),  // M6.T07
        .init(path: "docs/office/deck.pptx", kind: .pptx, unit: .slide, units: 4, needle: "## Slide 1"),
        .init(path: "docs/office/notes.csv", kind: .csv, unit: .sheet, units: 1, needle: "| --- |"),
        .init(path: "docs/text/sample.tsv", kind: .tsv, unit: .sheet, units: 1, needle: "| region | quarter | amount |"),
        .init(path: "docs/text/sample.txt", kind: .text, unit: .section, units: 1, needle: nil),
        .init(path: "docs/text/sample.md", kind: .markdown, unit: .section, units: 1, needle: "# Harbour notes"),
        .init(path: "docs/text/sample.rtf", kind: .rtf, unit: .section, units: 1, needle: "Harbour report"),
        .init(path: "docs/text/sample.html", kind: .html, unit: .section, units: 1, needle: "Harbour report"),
        .init(path: "docs/text/sample.json", kind: .json, unit: .section, units: 1, needle: "```json"),
        .init(path: "docs/text/sample.swift", kind: .code, unit: .section, units: 1, needle: "```swift"),
        .init(path: "docs/epub/sample.epub", kind: .epub, unit: .section, units: 3, needle: "## Chapter 1"),
        .init(path: "images/photos-cc0/001.jpg", kind: .jpeg, unit: nil, units: 0, needle: nil),
        .init(path: "images/upload-errors/sample.png", kind: .png, unit: nil, units: 0, needle: nil),
        .init(path: "images/upload-errors/heic-named.jpg", kind: .heic, unit: nil, units: 0, needle: nil),
        .init(path: "images/upload-errors/sample.webp", kind: .webp, unit: nil, units: 0, needle: nil),
        .init(path: "images/upload-errors/sample.gif", kind: .gif, unit: nil, units: 0, needle: nil),
    ]

    actor Table {
        var rows: [[String: String]] = []
        func add(_ r: [String: String]) -> [[String: String]] { rows.append(r); return rows }
    }
    static let table = Table()

    @Test(arguments: cases)
    func extracts(_ c: Case) async throws {
        let url = IntakeFixtures.url(c.path)
        let sniff = try TypeSniffer.sniff(url)
        #expect(sniff.kind == c.kind)
        // Adapters decide by extension: extract a copy named the way the media store names it.
        let dir = try IntakeFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let named = dir.appendingPathComponent("x." + (c.kind.canonicalExtension ?? url.pathExtension))
        try FileManager.default.copyItem(at: url, to: named)
        let doc = try await ExtractionService().extract(url: named, kind: sniff.kind)
        if c.kind.isImage {
            #expect(doc.markdown.isEmpty)  // OCR text arrives with M6.T04
        } else {
            #expect(!doc.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(doc.units.count == c.units)
            #expect(doc.units.allSatisfy { $0.kind == c.unit })
            if let n = c.needle { #expect(doc.markdown.contains(n), "\(doc.markdown.prefix(600))") }
            #expect(doc.units.allSatisfy { !doc.text(of: $0).isEmpty })
        }
        let rows = await Self.table.add(["file": c.path, "kind": c.kind.rawValue, "units": "\(doc.units.count)",
                                         "chars": "\(doc.charCount)", "ok": "true"])
        try Self.writeFormats(rows)
    }

    @Test func pdfPagesKeepTheirNumbers() async throws {
        let doc = try await ExtractionService().extract(url: IntakeFixtures.url("docs/pdf/text-10p.pdf"), kind: .pdf)
        #expect(doc.pageCount == 10)
        #expect(doc.units.map(\.index) == Array(1...10))
        #expect(doc.promptBlock(name: "a \"b\".pdf").hasPrefix("<document name=\"a &quot;b&quot;.pdf\" pages=\"10\" untrusted=\"true\">"))
    }

    @Test func sheetsCountRows() async throws {
        let doc = try await ExtractionService().extract(url: IntakeFixtures.url("docs/office/budget.xlsx"), kind: .xlsx)
        #expect(doc.sheetCount == 2)
        #expect(doc.units.first?.label == "Budget")
        #expect(doc.units.first?.rows == 13, "header + 12 months + Total")
        #expect(doc.markdown.contains("| Total |  | =SUM(C2:C13) | =SUM(D2:D13) |"), "uncached formulas show as formulas")
    }

    @Test func corruptPDFFails() async {
        await #expect(throws: ExtractionError.self) {
            _ = try await ExtractionService().extract(url: IntakeFixtures.url("docs/pdf/corrupt.pdf"), kind: .pdf)
        }
    }

    /// build/at/AT-020/<date>/formats.json, rewritten after each format (the parameterized cases run in any order).
    static func writeFormats(_ rows: [[String: String]]) throws {
        let day = Date().formatted(.iso8601.year().month().day())
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let dir = root.appendingPathComponent("build/at/AT-020/\(day)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rows.sorted { $0["file", default: ""] < $1["file", default: ""] })
            .write(to: dir.appendingPathComponent("formats.json"))
    }
}
