// M6.T13 DoD (R-016, R-277): snapshot tests for the ArtifactCard (code / React / Mermaid v2), the SidePanel header of an
// artifact (Copy, Download, version picker, `panel.fix` after a preview error) and the FileCard deleted state, light and
// dark, 100% and 200% text. Re-record after an intended visual change:
// SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=ArtifactSnapshotTests.
// Also the model side of the panel for artifacts (open on a promoted block, Fix / Edit selection requests, download
// formats per kind, PDF page jumps).
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

private func ref(_ title: String, kind: ArtifactKind, react: Bool = false, versions: [(Int, String)], version: Int,
                 language: String = "") -> PromotedArtifactRef {
    PromotedArtifactRef(artifactID: "art-1", title: title, kind: kind, react: react, language: language, version: version,
                        versions: versions.map { (n: $0.0, path: $0.1) }, createdAt: Date(timeIntervalSince1970: 0),
                        versionCreatedAt: Date(timeIntervalSince1970: 0))
}

private func scratch(_ name: String, _ text: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct ArtifactSnapshotTests {
    static let scales: [(String, CGFloat)] = [("100", 1), ("200", 2)]

    func check(_ view: some View, width: CGFloat, name: String) {
        for (label, scale) in Self.scales {
            for look in ResponseActionsSnapshotTests.Look.allCases {
                let v = view.environment(\.chatTextScale, scale).dynamicTypeSize(scale > 1 ? .accessibility3 : .large)
                assertSnapshot(of: ResponseActionsSnapshotTests.render(v, width: width, look: look),
                               as: .image(precision: 1, perceptualPrecision: 0.98),
                               named: "\(name)-\(label)-\(look.rawValue)", testName: "artifact")
            }
        }
    }

    @Test func artifactCards() throws {
        let code = try #require(OutputPromotion.classify(language: "python", code: (1...41).map { "x = \($0)" }.joined(separator: "\n")))
        check(ArtifactCardView(block: code, ref: ref("Python code.py", kind: .code, versions: [(1, "/tmp/a.py")], version: 1),
                               onOpen: {}), width: 440, name: "card-code")
        let jsx = try #require(OutputPromotion.classify(language: "jsx", code: "export default function Counter() {\n  return <b/>;\n}"))
        check(ArtifactCardView(block: jsx, ref: ref("Counter.jsx", kind: .html, react: true, versions: [(1, "/tmp/c.jsx")], version: 1),
                               onOpen: {}), width: 440, name: "card-react")
        let mmd = try #require(OutputPromotion.classify(language: "mermaid", code: "flowchart TD\n A --> B"))
        check(ArtifactCardView(block: mmd, ref: ref("Flowchart.mmd", kind: .mermaid, versions: [(1, "/tmp/f1.mmd"), (2, "/tmp/f2.mmd")], version: 2),
                               onOpen: {}), width: 440, name: "card-mermaid-v2")
    }

    @Test func sidePanelArtifactHeaderWithFix() throws {
        let v1 = try scratch("v1.py", (1...30).map { "print(\($0))" }.joined(separator: "\n"))
        let v2 = try scratch("v2.py", (1...30).map { "print(\($0 * 2))" }.joined(separator: "\n"))
        let model = SidePanelModel(windowID: "snap-\(UUID().uuidString)", defaults: UserDefaults.inMemory())
        model.onArtifactEdit = { _ in }
        model.open(ref("Python code.py", kind: .code, versions: [(1, v1.path), (2, v2.path)], version: 2, language: "python"))
        model.previewError = "ReferenceError: formatSteps is not defined"
        check(SidePanel(model: model).frame(height: 220), width: 480, name: "panel-fix")
    }

    @Test func fileCardDeleted() {
        let gone = URL(fileURLWithPath: "/tmp/antichat-deleted-\(UUID().uuidString).pdf")
        let card = FileCard(model: FileCardViewModel(item: FileCardItem(url: gone, displayName: "report.pdf", size: 13_808, version: 1)),
                            showsThumbnail: false)
        check(card, width: FileCard.width, name: "filecard-deleted")
    }
}
}  // extension WindowSuites

@MainActor
@Suite(.isolatedSettings) struct ArtifactPanelModelTests {
    func model() -> SidePanelModel {
        SidePanelModel(windowID: "t-\(UUID().uuidString)", defaults: UserDefaults.inMemory())
    }

    @Test func promotedArtifactOpensWithModeAndChain() throws {
        let m = model()
        let a = try scratch("a.json", #"{"mark":"bar"}"#), b = try scratch("b.json", #"{"mark":"line"}"#)
        m.open(ref("Chart.vl.json", kind: .chart, versions: [(1, a.path), (2, b.path)], version: 1))
        #expect(m.isOpen && m.current?.n == 1 && m.versionLabel?.string == "Version 1 of 2")
        #expect(m.body == .web && m.previewMode == .vega, "a .json version previews as Vega because the artifact is a chart")
        m.open(file: a, title: "a.json")
        #expect(m.previewMode == nil && m.body == .text && m.artifactID == nil, "a plain file resets the artifact context")
        for (name, mode) in [("a.jsx", PreviewMode.react), ("a.tsx", .react), ("a.mmd", .mermaid), ("a.vl.json", .vega),
                             ("a.html", .html), ("a.svg", .svg)] {
            #expect(PreviewMode(url: URL(fileURLWithPath: "/tmp/\(name)")) == mode, "\(name)")
            #expect(PanelBody(url: URL(fileURLWithPath: "/tmp/\(name)")) == .web, "\(name)")
        }
        #expect(PreviewMode(url: URL(fileURLWithPath: "/tmp/a.json")) == nil)
    }

    @Test func fixAndEditSelectionSendRequests() throws {
        let m = model()
        let src = try scratch("page.html", "<p>one</p>")
        var sent: [ArtifactEditRequest] = []
        m.onArtifactEdit = { sent.append($0) }
        m.open(ref("broken.html", kind: .html, versions: [(1, src.path)], version: 1, language: "html"))
        m.fix()
        #expect(sent.isEmpty, "no error, no fix")
        m.previewError = "ReferenceError: x"
        m.fix()
        #expect(sent.last == ArtifactEditRequest(artifactID: "art-1", title: "broken.html", language: "html", source: "<p>one</p>",
                                                  action: .fix(message: "ReferenceError: x"), baseVersion: 1))
        #expect(m.previewError == nil)
        let code = try scratch("a.py", "a = 1\nb = 2\n")
        m.open(ref("Python code.py", kind: .code, versions: [(1, code.path)], version: 1, language: "python"))
        m.selection = "b = 2"
        #expect(m.canEditSelection && m.editsInPlace)
        m.submitEditSelection(instruction: "  make it 3 ")
        #expect(sent.last?.action == .editSelection(selection: "b = 2", instruction: "make it 3"))
        var prefill: String?
        m.onEditSelection = { prefill = $0 }
        m.open(file: code, title: "notes.py")
        m.selection = "a = 1"
        #expect(!m.editsInPlace)
        m.submitEditSelection(instruction: "x")
        #expect(prefill == "> a = 1\n\n", "not an artifact: the composer is prefilled")
    }

    @Test func downloadFormatsPerKind() {
        let u = { (n: String) in URL(fileURLWithPath: "/tmp/\(n)") }
        #expect(ArtifactExport.formats(preview: nil, body: .text, url: u("a.md")) == [.markdown])
        #expect(ArtifactExport.formats(preview: nil, body: .text, url: u("a.py")) == [.markdown, .native("py")])
        #expect(ArtifactExport.formats(preview: .html, body: .web, url: u("a.html")) == [.html, .pdf])
        #expect(ArtifactExport.formats(preview: .react, body: .web, url: u("a.jsx")) == [.html, .pdf, .native("jsx")])
        for p in [PreviewMode.svg, .mermaid, .vega] {
            #expect(ArtifactExport.formats(preview: p, body: .web, url: u("a")) == [.svg, .png])
        }
        #expect(ArtifactExport.formats(preview: nil, body: .pdf, url: u("r.pdf")) == [.native("pdf")])
        #expect(ArtifactExport.formats(preview: nil, body: .quickLook, url: u("d.docx")) == [.native("docx")])
        #expect(ArtifactExport.filename(title: "Quarterly revenue.vl.json", format: .png) == "Quarterly revenue.png")
        #expect(ArtifactExport.filename(title: "Counter.jsx", format: .html) == "Counter.html")
        #expect(DownloadFormat.markdown.type.identifier == "net.daringfireball.markdown")
        #expect(DownloadFormat.svg.type == .svg && DownloadFormat.png.type == .png && DownloadFormat.pdf.type == .pdf)
    }

    @Test func markdownDownloadFencesCodeAndCopyPutsText() async throws {
        let code = try scratch("x.py", "print(1)")
        let md = await ArtifactExport.data(.markdown, url: code, preview: nil, language: "python", web: nil)
        #expect(md.map { String(decoding: $0, as: UTF8.self) } == "```python\nprint(1)\n```\n")
        let doc = try scratch("plan.md", "# Plan")
        #expect(await ArtifactExport.data(.markdown, url: doc, preview: nil, language: "", web: nil) == Data("# Plan".utf8))
        let pb = NSPasteboard.withUniqueName()
        ArtifactExport.copy(url: code, to: pb)
        #expect(pb.string(forType: .string) == "print(1)")
    }

    @Test func pdfPageJump() {
        let m = model()
        m.open(pdf: URL(fileURLWithPath: "/tmp/r.pdf"), title: "report.pdf", page: 7)
        #expect(m.page == 7 && m.body == .pdf && m.title == "report.pdf")
        m.open(file: URL(fileURLWithPath: "/tmp/r.pdf"))
        #expect(m.page == nil)
    }
}
