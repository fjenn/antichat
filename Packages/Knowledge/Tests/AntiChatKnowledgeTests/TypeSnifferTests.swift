// AT-020 check 2 leg (M6.T01 step 2): the magic table, HEIC named .jpg (`isLying`, read as HEIC), encrypted PDF,
// legacy `.doc` → unsupported, OOXML/EPUB by their zip members, text by extension.
//   make test-unit FILTER=TypeSnifferTests
import Foundation
import Testing
@testable import AntiChatKnowledge

@Suite struct TypeSnifferTests {
    @Test(arguments: [
        ("docs/pdf/text-10p.pdf", AttachmentKind.pdf), ("docs/office/report.docx", .docx), ("docs/office/budget.xlsx", .xlsx),
        ("docs/office/deck.pptx", .pptx), ("docs/office/notes.csv", .csv), ("docs/text/sample.tsv", .tsv),
        ("docs/text/sample.txt", .text), ("docs/text/sample.md", .markdown), ("docs/text/sample.rtf", .rtf),
        ("docs/text/sample.html", .html), ("docs/text/sample.json", .json), ("docs/text/sample.swift", .code),
        ("docs/epub/sample.epub", .epub), ("images/photos-cc0/001.jpg", .jpeg), ("images/upload-errors/sample.png", .png),
        ("images/upload-errors/sample.gif", .gif), ("images/upload-errors/sample.webp", .webp),
    ])
    func knownKinds(_ rel: String, _ kind: AttachmentKind) throws {
        let r = try TypeSniffer.sniff(IntakeFixtures.url(rel))
        #expect(r.kind == kind, "\(rel)")
        #expect(!r.isLying && !r.isEncrypted, "\(rel)")
    }

    @Test func heicNamedJPGIsReadAsHEIC() throws {
        let r = try TypeSniffer.sniff(IntakeFixtures.url("images/upload-errors/heic-named.jpg"))
        #expect(r.kind == .heic)
        #expect(r.isLying)
        #expect(r.ext == "jpg")
    }

    @Test func encryptedPDF() throws {
        let r = try TypeSniffer.sniff(IntakeFixtures.url("docs/pdf/encrypted.pdf"))
        #expect(r.kind == .pdf && r.isEncrypted)
    }

    @Test func legacyDocIsUnsupported() throws {
        let r = try TypeSniffer.sniff(IntakeFixtures.url("docs/office/legacy.doc"))
        #expect(r.kind == .legacyOffice)
        #expect(!r.kind.isSupported)
        let adm = AttachmentIntake.admit([IntakeFixtures.url("docs/office/legacy.doc")])
        #expect(adm.items.first?.state == .unsupported(ext: "doc"))
    }

    @Test func magicBeatsTheExtensionAndTextNeedsAKnownName() throws {
        let dir = try IntakeFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A PNG named .pdf → PNG, lying.
        let png = dir.appendingPathComponent("photo.pdf")
        try FileManager.default.copyItem(at: IntakeFixtures.url("images/upload-errors/sample.png"), to: png)
        let r = try TypeSniffer.sniff(png)
        #expect(r.kind == .png && r.isLying)
        // Text with an unknown extension → unknown; OLE with a Workbook stream → xls.
        let odd = dir.appendingPathComponent("notes.qqq")
        try Data("hello".utf8).write(to: odd)
        #expect(try TypeSniffer.sniff(odd).kind == .unknown)
        var ole = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 504)
        ole += Data("Workbook".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        let xls = dir.appendingPathComponent("legacy.xls")
        try ole.write(to: xls)
        #expect(try TypeSniffer.sniff(xls).kind == .xls)
        // XLS is supported (R-272) and read since M6.T07 (libxls): admitted, not an unsupported tile.
        #expect(AttachmentIntake.admit([xls]).items.first?.state != .unsupported(ext: "xls"))
        // Binary junk with a text name is not text.
        let junk = dir.appendingPathComponent("junk.txt")
        try Data([0x00, 0x01, 0x02, 0xFE]).write(to: junk)
        #expect(try TypeSniffer.sniff(junk).kind == .unknown)
    }
}
