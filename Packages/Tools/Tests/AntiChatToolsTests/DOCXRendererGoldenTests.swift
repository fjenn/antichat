// M6.T09 task check `DOCXRendererGoldenTests` (AT-273 checks 1 and 3): the 30 `fileout-golden/docx-30` specs render
// through RenderHost (vendored docx 9.15.0, no network, no process) and their normalised `word/document.xml` equals
// the frozen golden; structure: headings, numbered/bulleted lists, bordered tables with a repeated header row, images,
// right-to-left paragraphs, header title + footer "Page n of N" fields, core properties creator "AntiChat". The
// Markdown goldens (`md-30`) are byte-equal.
import Foundation
import Testing
@testable import AntiChatTools

@MainActor
@Suite(.serialized, .enabled(if: FileOutFixtures.available, "fixtures/docs/golden-out/specs missing"))
struct DOCXRendererGoldenTests {
    static func render(_ id: String) async throws -> URL {
        let data = try await DOCXRenderer.render(try FileOutFixtures.spec(id), images: FileOutFixtures.images,
                                                 locale: Locale(identifier: "en_GB"))
        FileOutFixtures.dump("\(id).docx", data)
        let url = try FileOutFixtures.scratch().appendingPathComponent("\(id).docx")
        try data.write(to: url)
        return url
    }

    /// document.xml without the ids docx generates per process (drawing ids, relationship ids) and with one element
    /// per line, so a golden diff is readable.
    static func normalised(_ xml: String) -> String {
        var s = xml
        for (pattern, repl) in [(#" (id|r:embed|r:id)="[^"]*""#, ""), (#"<wp:docPr [^>]*>"#, "<wp:docPr>"),
                                (#"(<pic:cNvPr)[^>]*>"#, "$1>"), (#"><"#, ">\n<")] {
            s = s.replacingOccurrences(of: pattern, with: repl, options: .regularExpression)
        }
        return s + "\n"
    }

    @Test func goldenDocumentXML() async throws {
        var failures: [String] = []
        for id in FileOutFixtures.ids("docx") {
            let url = try await Self.render(id)
            let xml = Self.normalised(try FileOutFixtures.part(url, "word/document.xml"))
            #expect(xml.count > 200, "\(id): empty document.xml")
            if let diff = try FileOutFixtures.golden("\(id).document.xml", Data(xml.utf8)) { failures.append(diff) }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func structureAndProperties() async throws {
        let url = try await Self.render("docx-30")
        let entries = try FileOutFixtures.entries(url)
        #expect(entries.contains("word/document.xml") && entries.contains("[Content_Types].xml"))
        #expect(entries.contains { $0.hasPrefix("word/media/") }, "image part: \(entries)")
        let doc = try FileOutFixtures.part(url, "word/document.xml")
        #expect(doc.contains(#"w:pStyle w:val="Heading1""#), "heading style")
        #expect(doc.contains("<w:numPr>"), "list numbering")
        #expect(doc.contains("<w:tbl>") && doc.contains("<w:tblHeader"), "table with a repeated header row")
        #expect(doc.contains("<w:drawing>"), "image")
        #expect(doc.contains("<w:bidi/>") && doc.contains("<w:rtl/>"), "right-to-left paragraph")
        let footers = entries.filter { $0.hasPrefix("word/footer") }
        let footer = try footers.map { try FileOutFixtures.part(url, $0) }.joined()
        #expect(footer.contains("PAGE") && footer.contains("NUMPAGES") && footer.contains("Page "), "footer Page n of N")
        let header = try entries.filter { $0.hasPrefix("word/header") }.map { try FileOutFixtures.part(url, $0) }.joined()
        #expect(header.contains("Kitchen Sink"), "header title")
        let core = try FileOutFixtures.part(url, "docProps/core.xml")
        #expect(core.contains("<dc:creator>AntiChat</dc:creator>"), "creator: \(core)")
        #expect(core.contains("<dc:title>Kitchen Sink</dc:title>"))
        // Letter vs A4 page size (twips).
        let letter = try FileOutFixtures.part(try await Self.render("docx-19"), "word/document.xml")
        #expect(letter.contains(#"w:w="12240""#) && letter.contains(#"w:h="15840""#), "Letter")
        let a4 = try FileOutFixtures.part(try await Self.render("docx-20"), "word/document.xml")
        #expect(a4.contains(#"w:w="11906""#) && a4.contains(#"w:h="16838""#), "A4")
    }

    @Test func markdownGoldensAreByteEqual() throws {
        var failures: [String] = []
        for id in FileOutFixtures.ids("md") {
            let data = MarkdownWriter.render(try FileOutFixtures.spec(id))
            FileOutFixtures.dump("\(id).md", data)
            #expect(String(decoding: data, as: UTF8.self).hasSuffix("\n") && !data.starts(with: [0xEF, 0xBB, 0xBF]))
            if let diff = try FileOutFixtures.golden("\(id).md", data) { failures.append(diff) }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func hostIsWarmAcrossCalls() async throws {
        let host = RenderHost.shared
        _ = try await Self.render("docx-01")
        let loads = host.loads
        _ = try await Self.render("docx-02")
        #expect(host.loads == loads, "the second document reuses the loaded page")
    }
}
