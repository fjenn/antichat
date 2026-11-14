// M6.T11 task check `PPTXRendererGoldenTests` (AT-275 check 1a): the 20 `pptx-golden-20` specs render through
// RenderHost (PptxGenJS 4.0.1; no model, network or process) — slide count, layouts, notes text and theme per fixture spec
// (`ppt/slides/slide*.xml`, `ppt/notesSlides/*`, slide masters), normalised slide XML equal to the frozen goldens; all four
// themes; a 31-slide spec is rejected (repair turn); properties author/company "AntiChat".
import Foundation
import Testing
@testable import AntiChatTools

@MainActor
@Suite(.serialized, .enabled(if: FileOutFixtures.available, "fixtures/docs/golden-out/specs missing"))
struct PPTXRendererGoldenTests {
    static let ids = (1...20).map { String(format: "pptx-%02d", $0) }

    static func render(_ id: String) async throws -> (URL, PresentationSpec) {
        let spec = try CreatePresentationTool.decode(try FileOutFixtures.specJSON(id))
        var images: [String: FileOutImage] = [:]
        for ref in Set(spec.slides.compactMap(\.image_ref)) { images[ref] = FileOutFixtures.images[ref] }
        let data = try await CreatePresentationTool.render(spec, images: images)
        FileOutFixtures.dump("\(id).pptx", data)
        let url = try FileOutFixtures.scratch().appendingPathComponent("\(id).pptx")
        try data.write(to: url)
        return (url, spec)
    }

    static func slideParts(_ url: URL) throws -> [String] {
        try FileOutFixtures.entries(url).filter { $0.range(of: #"^ppt/slides/slide\d+\.xml$"#, options: .regularExpression) != nil }
            .sorted { Int($0.filter(\.isNumber)) ?? 0 < Int($1.filter(\.isNumber)) ?? 0 }
    }

    /// Slide XML without generated ids / relationship ids / random object names, one element per line.
    static func normalised(_ xml: String) -> String {
        var s = xml
        for (p, r) in [(#" (id|r:embed|r:id|r:link)="[^"]*""#, ""), (#" name="[^"]*""#, ""), (#" descr="[^"]*""#, ""),
                       (#"><"#, ">\n<")] {
            s = s.replacingOccurrences(of: p, with: r, options: .regularExpression)
        }
        return s
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    @Test func goldenSlides() async throws {
        var failures: [String] = []
        for id in Self.ids {
            let (url, spec) = try await Self.render(id)
            let slides = try Self.slideParts(url)
            #expect(slides.count == spec.slides.count, "\(id): \(slides.count) slides, spec \(spec.slides.count)")
            let text = try slides.map { "== \($0)\n" + Self.normalised(try FileOutFixtures.part(url, $0)) }.joined(separator: "\n") + "\n"
            if let d = try FileOutFixtures.golden("\(id).pptx.txt", Data(text.utf8)) { failures.append(d) }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func layoutsNotesImagesThemes() async throws {
        var themes = Set<String>(), layouts = Set<String>()
        for id in Self.ids {
            let (url, spec) = try await Self.render(id)
            themes.insert(spec.theme ?? "clean")
            let entries = try FileOutFixtures.entries(url)
            for (i, s) in spec.slides.enumerated() {
                layouts.insert(s.layout)
                let xml = try FileOutFixtures.part(url, "ppt/slides/slide\(i + 1).xml")
                #expect(xml.contains(Self.esc(s.title)), "\(id) slide \(i + 1) title")
                for b in s.bullets ?? [] { #expect(xml.contains(Self.esc(b)), "\(id) slide \(i + 1) bullet \(b)") }
                if s.image_ref != nil { #expect(xml.contains("<p:pic>"), "\(id) slide \(i + 1) image") }
            }
            let notes = try entries.filter { $0.hasPrefix("ppt/notesSlides/notesSlide") && $0.hasSuffix(".xml") }
                .map { try FileOutFixtures.part(url, $0) }.joined()
            for s in spec.slides { if let n = s.notes { #expect(notes.contains(Self.esc(n)), "\(id) notes \(n)") } }
            let app = try FileOutFixtures.part(url, "docProps/app.xml"), core = try FileOutFixtures.part(url, "docProps/core.xml")
            #expect(app.contains("<Company>AntiChat</Company>") && core.contains("<dc:creator>AntiChat</dc:creator>"), "\(id) properties")
        }
        #expect(themes == Set(PresentationSpec.themes), "all four themes: \(themes)")
        #expect(layouts == ["title", "bullets", "image", "title_bullets_image"])
        // Theme colours reach the masters (dusk = dark background 1E2235).
        let (dusk, _) = try await Self.render("pptx-02")
        let masters = try FileOutFixtures.entries(dusk).filter { $0.hasPrefix("ppt/slideLayouts/") || $0.hasPrefix("ppt/slideMasters/") }
            .map { try FileOutFixtures.part(dusk, $0) }.joined()
        #expect(masters.contains("1E2235"), "dusk background")
    }

    @Test func thirtyOneSlidesAreRejected() throws {
        var spec = try CreatePresentationTool.decode(try FileOutFixtures.specJSON("pptx-20"))
        #expect(spec.slides.count == 30)
        #expect(CreatePresentationTool.problems(argumentsJSON: try FileOutFixtures.specJSON("pptx-20"), imageExists: { _ in true }).isEmpty)
        spec.slides.append(.init(layout: "bullets", title: "One too many", bullets: ["x"]))
        let json = String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
        #expect(CreatePresentationTool.problems(argumentsJSON: json, imageExists: { _ in true }) == ["$.slides: more than 30 items (31)"])
        let nine = #"{"filename":"d","slides":[{"layout":"bullets","title":"t","bullets":["1","2","3","4","5","6","7","8","9"]}]}"#
        #expect(CreatePresentationTool.problems(argumentsJSON: nine, imageExists: { _ in true }) == ["$.slides[0].bullets: more than 8 items (9)"])
        let lenient = #"{"filename":"d","slides":[{"layout":"image"},{"layout":"title_bullets_image","title":"t","bullets":["a"]}]}"#
        #expect(CreatePresentationTool.problems(argumentsJSON: lenient, imageExists: { _ in true }).isEmpty, "no title / no image tolerated")
        #expect(try CreatePresentationTool.decode(lenient).slides[0].title == "")
        let unknown = #"{"filename":"d","slides":[{"layout":"image","title":"t","image_ref":"gone"}]}"#
        #expect(CreatePresentationTool.problems(argumentsJSON: unknown, imageExists: { _ in false }) == [#"$.slides[0].image_ref: no attachment or file with id "gone""#])
        let badTheme = #"{"filename":"d","theme":"neon","slides":[{"layout":"title","title":"t"}]}"#
        #expect(CreatePresentationTool.problems(argumentsJSON: badTheme, imageExists: { _ in true }).first?.hasPrefix("$.theme: not one of") == true)
    }
}
