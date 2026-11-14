// M6 review #2 (P1): DOCX (headings + the AppKit importer behind it) and EPUB intake go through the shared bounded zip
// reader: a small file whose part inflates past 64 MB is refused with a size error instead of inflating in memory.
import AntiChatStorage
import Foundation
import OsaurusVendored
import Testing
@testable import AntiChatKnowledge

@Suite(.serialized) struct ZipBombIntakeTests {
    static func zip(_ parts: [(String, Data)]) throws -> Data {
        var w = ZipArchiveWriter()
        for (n, d) in parts { try w.add(path: n, data: d) }
        return try w.finalize()
    }
    static func bombXML(_ open: String, _ close: String) -> Data {
        var d = Data(open.utf8); d.append(Data(repeating: 0x20, count: 80 << 20)); d.append(Data(close.utf8)); return d
    }

    @Test func docxBombIsRefused() async throws {
        let dir = try IntakeFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("bomb.docx")
        try Self.zip([
            ("[Content_Types].xml", Data(#"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#.utf8)),
            ("word/document.xml", Self.bombXML(#"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>x</w:t></w:r></w:p>"#, "</w:body></w:document>")),
        ]).write(to: url)
        #expect(try Data(contentsOf: url).count < 1 << 20)
        #expect(throws: BoundedZipError.self) { try DOCXHeadings.levels(url) }
        do {
            _ = try await ExtractionService().extract(url: url, kind: .docx)
            Issue.record("the bomb was extracted")
        } catch let ExtractionError.failed(why) {
            #expect(why.contains("partTooLarge"), "\(why)")
        }
    }

    @Test func epubBombIsRefused() throws {
        let dir = try IntakeFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("bomb.epub")
        try Self.zip([
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(#"<container><rootfiles><rootfile full-path="c.opf"/></rootfiles></container>"#.utf8)),
            ("c.opf", Data(#"<package><manifest><item id="a" href="a.xhtml"/></manifest><spine><itemref idref="a"/></spine></package>"#.utf8)),
            ("a.xhtml", Self.bombXML("<html><body><p>x", "</p></body></html>")),
        ]).write(to: url)
        #expect(throws: BoundedZipError.self) { try EPUBAdapter().extract(url: url) }
    }
}
