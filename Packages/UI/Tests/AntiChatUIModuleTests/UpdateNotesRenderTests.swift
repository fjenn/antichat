// RC review P2-7: the update-notes sheet renders the appcast item's HTML without AppKit's WebKit-backed HTML importer.
// The text comes through; scripts, styles, image URLs and links do not, and the source never reaches for the importer.
//   make test-unit FILTER=UpdateNotesRenderTests
import Foundation
import Testing
@testable import AntiChatUI

@Suite(.isolatedSettings) struct UpdateNotesRenderTests {
    static let feedHTML = """
        <html><head><style>body { background: url(https://example.com/bg.png) }</style>
        <link rel="stylesheet" href="https://example.com/s.css"></head><body>
        <h2>What&rsquo;s new</h2>
        <p>Faster <b>imports</b> &amp; fixes. <a href="https://example.com/notes">Full notes</a></p>
        <ul><li>First item</li><li>Second item</li></ul>
        <img src="https://example.com/tracker.png" alt="">
        <script>document.write('injected'); fetch('https://example.com/x')</script>
        </body></html>
        """

    @Test func rendersTextOnlyWithNoScriptStyleImageOrLink() throws {
        let out = try #require(UpdateNotesSheet.render(Self.feedHTML))
        let text = String(out.characters)
        for kept in ["What\u{2019}s new", "imports", "& fixes", "Full notes", "First item", "Second item"] {
            #expect(text.contains(kept), "missing \(kept) in \(text)")
        }
        for gone in ["injected", "fetch", "background", "example.com", "tracker", "<"] {
            #expect(!text.contains(gone), "\(gone) leaked into \(text)")
        }
        #expect(out.runs.allSatisfy { $0.link == nil && $0.imageURL == nil })
    }

    @Test func emptyOrMissingNotesRenderNothing() {
        #expect(UpdateNotesSheet.render(nil) == nil)
        #expect(UpdateNotesSheet.render("") == nil)
        #expect(UpdateNotesSheet.render("<script>alert(1)</script>") == nil)
    }

    @Test func sourceNeverUsesTheAppKitHTMLImporter() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/AntiChatUI/Sidebar/UpdatePill.swift").standardized
        let src = try String(contentsOf: file, encoding: .utf8)
        for banned in ["DocumentType.html", ".documentType", "NSAttributedString(data", "NSAttributedString(html", "WKWebView", "import WebKit"] {
            #expect(!src.contains(banned), "UpdatePill references \(banned)")
        }
    }
}
