// M7.T16 (A-M7-T03a d, AT-VQ-M7): a citation pill must not push the rest of its paragraph onto a new line. MarkdownView
// lays a paragraph holding an embedded view out as a flow of whole runs, so the pills of a line go to its end
// (CitationPill.pillsAtLineEnd); hosted at a fixed width the paragraph keeps the height of one line.
//   make test-unit FILTER=PillLineBreakTests
import AntiChatDesign
import AntiChatStorage
import AppKit
import MarkdownView
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct PillLineBreakTests {
    static let sources = [1, 2].map {
        MessageProvenance.WebSourceRecord(n: $0, url: "https://source\($0).example/p", title: "T\($0)", site: "source\($0).example",
                                          date: nil, faviconData: nil, snippet: "s", fetched: true)
    }

    @Test func pillsGoToTheEndOfTheirLine() {
        let r = CitationPill.linkify("The latest macOS is macOS 27 [1]. It shipped this autumn [2].\n\n```\nx = arr[1]\n```", sources: Self.sources)
        #expect(r.text.hasPrefix("The latest macOS is macOS 27. It shipped this autumn. [source1.example](antichat-cite://1) [source2.example](antichat-cite://2)"), "\(r.text)")
        #expect(r.text.hasSuffix("```\nx = arr[1]\n```"), "code untouched")
        #expect(r.cited == [1, 2])
    }

    /// AT-250 c2 (M7 bars): while the reply's citation checks run, its pills carry `?checking` (the pill shows
    /// `cite.checking`); the settled text has plain links, so the renderer redraws when the verdict lands.
    @Test func checkingPillsCarryTheCheckingStateUntilTheySettle() throws {
        let r = CitationPill.linkify("macOS 27 shipped [1].", sources: Self.sources, checking: true)
        #expect(r.text == "macOS 27 shipped. [source1.example](antichat-cite://1?checking)", "\(r.text)")
        let url = try #require(URL(string: "antichat-cite://1,2?checking"))
        #expect(CitationPill.numbers(url) == [1, 2] && CitationPill.checking(url))
        let settled = CitationPill.linkify("macOS 27 shipped [1].", sources: Self.sources)
        #expect(settled.text == "macOS 27 shipped. [source1.example](antichat-cite://1)")
        #expect(!CitationPill.checking(try #require(URL(string: "antichat-cite://1"))))
    }

    /// VQ-M11 S-10 (R5): the drawn reply groups a line's trailing pills into one chip that still names every pill.
    @Test func trailingPillsDrawAsOneChip() throws {
        let linked = CitationPill.linkify("macOS 27 [1]. It shipped [1,2].\n\nOne [2].\n\n```\na [1] b\n```", sources: Self.sources).text
        let shown = CitationPill.groupedForDisplay(linked)
        let lines = shown.components(separatedBy: "\n")
        #expect(lines[0] == "macOS 27. It shipped. [source1.example](antichat-cite://1,2?g=1_1-2)", "\(lines[0])")
        #expect(lines[2] == "One. [source2.example](antichat-cite://2)", "a single pill is left as it is")
        #expect(shown.hasSuffix("```\na [1] b\n```"), "code untouched")
        let url = try #require(URL(string: "antichat-cite://1,2?g=1_1-2&checking"))
        #expect(CitationPill.groups(url) == [[1], [1, 2]])
        #expect(CitationPill.numbers(url) == [1, 2] && CitationPill.checking(url))
        #expect(CitationPill.groups(try #require(URL(string: "antichat-cite://2"))) == [[2]])
    }

    func height(_ markdown: String) -> CGFloat {
        let v = NSHostingView(rootView: MarkdownView(markdown).markdownStyle().environment(\.webSources, Self.sources)
            .frame(width: 860, alignment: .leading))
        v.layoutSubtreeIfNeeded()
        return v.fittingSize.height
    }

    @Test func aParagraphWithAPillKeepsOneLine() {
        _ = NSApplication.shared
        let one = height("The latest macOS is macOS 27. It shipped this autumn.")
        let pilled = height(CitationPill.linkify("The latest macOS is macOS 27 [1]. It shipped this autumn.", sources: Self.sources).text)
        #expect(one > 0 && pilled < one * 1.6, "one line \(one) pt, with the pill \(pilled) pt")
    }
}
}  // extension WindowSuites
