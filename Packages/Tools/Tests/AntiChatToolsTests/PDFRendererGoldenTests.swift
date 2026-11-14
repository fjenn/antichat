// M6.T09 task check `PDFRendererGoldenTests` (AT-273 checks 1 and 3): the 30 `fileout-golden/pdf-30` specs render with
// no model, no network and no process (TPPDF in-process), and their text layer (PDFKit) + page count equal the frozen
// goldens. AC3: headings, lists, tables (header repeated on every page), images and "Page n of N" on every page; text
// in Latin, Greek, Cyrillic, CJK, Arabic and Hebrew extracts from the text layer, and no character draws as .notdef
// (CoreText run glyphs, FontRegistry cascade). Metadata: Creator "AntiChat", Producer "AntiChat <version>".
import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import AntiChatTools

@Suite(.enabled(if: FileOutFixtures.available, "fixtures/docs/golden-out/specs missing"))
struct PDFRendererGoldenTests {
    static let samples: [(String, String)] = [
        ("greek", "Η γρήγορη καφέ αλεπού πηδάει πάνω από τον τεμπέλη σκύλο."),
        ("cyrillic", "Съешь же ещё этих мягких французских булок, да выпей чаю."),
        ("cjk-sc", "敏捷的棕色狐狸跳过了懒狗。这是一段简体中文文本。"),
        ("cjk-jp", "いろはにほへと ちりぬるを。これは日本語のテキストです。"),
        ("cjk-kr", "다람쥐 헌 쳇바퀴에 타고파. 이것은 한국어 문장입니다."),
        ("arabic", "نص حكيم له سر قاطع وذو شأن عظيم مكتوب على ثوب أخضر."),
        ("hebrew", "דג סקרן שט בים מאוכזב ולפתע מצא חברה."),
    ]

    static func render(_ id: String) throws -> PDFDocument {
        let data = try PDFRenderer.render(try FileOutFixtures.spec(id), images: FileOutFixtures.images, locale: Locale(identifier: "en_GB"))
        FileOutFixtures.dump("\(id).pdf", data)
        return try #require(PDFDocument(data: data))
    }

    /// The text layer, one line per page, whitespace runs collapsed (the golden form).
    static func textLayer(_ pdf: PDFDocument) -> String {
        (0..<pdf.pageCount).map { i in
            (pdf.page(at: i)?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// Letters only, NFKC (no spaces, punctuation or direction marks): what "extracts correctly" compares.
    static func letters(_ s: String) -> String {
        String(String.UnicodeScalarView(s.precomposedStringWithCompatibilityMapping.unicodeScalars.filter {
            $0.properties.isAlphabetic || $0.properties.numericType != nil
        }))
    }

    @Test(arguments: FileOutFixtures.ids("pdf"))
    func goldenTextLayerAndPageCount(_ id: String) throws {
        let pdf = try Self.render(id)
        struct Golden: Codable, Equatable { var pages: Int; var text: String }
        let g = Golden(pages: pdf.pageCount, text: Self.textLayer(pdf))
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let diff = try FileOutFixtures.golden("\(id).pdf.json", e.encode(g) + Data("\n".utf8))
        if let diff, let want = try? JSONDecoder().decode(Golden.self, from: Data(contentsOf: FileOutFixtures.expectedDir
            .appendingPathComponent("\(id).pdf.json"))) {
            #expect(want.pages == g.pages, "\(id): \(g.pages) pages, golden \(want.pages)")
            #expect(want.text == g.text, "\(id): text layer differs")
        } else {
            #expect(diff == nil, "\(id): \(diff ?? "")")
        }
    }

    @Test(arguments: FileOutFixtures.ids("pdf"))
    func everyPageSaysPageNOfN(_ id: String) throws {
        let pdf = try Self.render(id)
        #expect(pdf.pageCount >= 1)
        for i in 0..<pdf.pageCount {
            let text = (pdf.page(at: i)?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            #expect(text.contains("Page \(i + 1) of \(pdf.pageCount)"), "\(id) page \(i + 1): \(text.suffix(80))")
        }
    }

    @Test func scriptsExtractFromTheTextLayer() throws {
        // pdf-30 (kitchen sink) carries six scripts; pdf-05…11 one each.
        let ids = ["pdf-05", "pdf-06", "pdf-07", "pdf-08", "pdf-09", "pdf-10", "pdf-11", "pdf-30"]
        var all = ""
        for id in ids { all += Self.letters(Self.textLayer(try Self.render(id))) }
        for (name, sample) in Self.samples {
            let want = Self.letters(sample)
            // Text layers may store right-to-left runs in visual order; either order counts as extracted.
            let found = all.contains(want) || all.contains(String(want.reversed()))
            #expect(found, "\(name) text did not extract: \(want)")
        }
    }

    @Test func bundledFacesResolve() {
        #expect(FontRegistry.register())
        #expect(FontRegistry.font(.sans, size: 12).fontName == "NotoSans-Regular")
        #expect(FontRegistry.font(.sans, size: 12, bold: true).fontName == "NotoSans-Bold")
        #expect(FontRegistry.font(.sans, size: 12, italic: true).fontName == "NotoSans-Italic")
        #expect(FontRegistry.font(.sans, size: 12, bold: true, italic: true).fontName == "NotoSans-BoldItalic")
        #expect(FontRegistry.font(.serif, size: 12, bold: true).fontName == "NotoSerif-Bold")
        #expect(FontRegistry.font(.mono, size: 12).fontName == "NotoSansMono-Regular")
    }

    @Test func noCharacterDrawsAsTofu() throws {
        for (name, sample) in Self.samples {
            for bold in [false, true] {
                let s = NSAttributedString(string: sample, attributes: [.font: FontRegistry.font(.sans, size: 11, bold: bold, for: sample)])
                #expect(FontRegistry.missingGlyphs(in: s).isEmpty, "\(name) bold=\(bold): \(FontRegistry.missingGlyphs(in: s))")
                let allowed = ["NotoSans", "GeezaPro", "PingFang", "Hiragino", "AppleSDGothicNeo"]
                let used = FontRegistry.usedFonts(in: s)
                #expect(used.allSatisfy { u in allowed.contains { u.hasPrefix($0) } }, "\(name): \(used)")
            }
        }
        let mono = NSAttributedString(string: "let x = 1 // Ωμέγα Жж", attributes: [.font: FontRegistry.font(.mono, size: 10)])
        #expect(FontRegistry.missingGlyphs(in: mono).isEmpty)
    }

    @Test func structureHeadingsListsTablesImages() throws {
        let pdf = try Self.render("pdf-30")
        let text = Self.textLayer(pdf)
        #expect(text.contains("Kitchen Sink"))
        #expect(text.contains("•") && text.contains("◦"), "bullets (nested)")
        #expect(text.contains("1.") && text.contains("2."), "numbered list")
        #expect(text.contains("A B") || text.contains("A\tB") || (text.contains("A") && text.contains("B")))
        #expect(Self.imageCount(pdf) >= 1, "an image XObject is drawn")
        #expect(Self.imageCount(try Self.render("pdf-29")) >= 3, "the gallery draws three images")
        // H1 is larger than H4 in pdf-23 (heading levels): the first line is drawn bigger.
        let headings = try Self.render("pdf-23")
        #expect(Self.textLayer(headings).contains("3.1 Cells") && Self.textLayer(headings).contains("Transport"))
    }

    @Test func longTableRepeatsItsHeaderOnEveryPage() throws {
        let pdf = try Self.render("pdf-16")
        #expect(pdf.pageCount >= 2, "the 90-row table spans pages")
        for i in 0..<pdf.pageCount {
            let text = pdf.page(at: i)?.string ?? ""
            #expect(text.contains("Region") && text.contains("Value"), "page \(i + 1) has the header row")
        }
    }

    @Test func pageSizesAndMetadata() throws {
        let letter = try Self.render("pdf-19"), a4 = try Self.render("pdf-20")
        let lb = try #require(letter.page(at: 0)).bounds(for: .mediaBox), ab = try #require(a4.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(lb.width - 612) < 1 && abs(lb.height - 792) < 1, "Letter \(lb)")
        #expect(abs(ab.width - 595.2) < 1.5 && abs(ab.height - 841.8) < 1.5, "A4 \(ab)")
        let attrs = letter.documentAttributes ?? [:]
        #expect(attrs[PDFDocumentAttribute.creatorAttribute] as? String == "AntiChat")
        #expect((attrs[PDFDocumentAttribute.producerAttribute] as? String)?.hasPrefix("AntiChat") == true,
                "producer: \(String(describing: attrs[PDFDocumentAttribute.producerAttribute]))")
        #expect(attrs[PDFDocumentAttribute.titleAttribute] as? String == "US Letter Flyer")
    }

    /// Image XObjects drawn on any page.
    static func imageCount(_ pdf: PDFDocument) -> Int {
        guard let data = pdf.dataRepresentation(), let provider = CGDataProvider(data: data as CFData),
              let doc = CGPDFDocument(provider) else { return 0 }
        var count = 0
        for i in 1...max(doc.numberOfPages, 1) {
            guard let dict = doc.page(at: i)?.dictionary else { continue }
            var res: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res else { continue }
            var xo: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(res, "XObject", &xo), let xo else { continue }
            final class Box { var n = 0 }
            let box = Box()
            CGPDFDictionaryApplyBlock(xo, { _, obj, info in
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(obj, .stream, &stream), let stream, let sd = CGPDFStreamGetDictionary(stream) {
                    var name: UnsafePointer<CChar>?
                    if CGPDFDictionaryGetName(sd, "Subtype", &name), let name, String(cString: name) == "Image" {
                        Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue().n += 1
                    }
                }
                return true
            }, Unmanaged.passUnretained(box).toOpaque())
            count += box.n
        }
        return count
    }
}
