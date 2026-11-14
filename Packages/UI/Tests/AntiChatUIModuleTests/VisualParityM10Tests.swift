// VQ-M10 (blind visual QA, parity-M10.md) chat-screen fixes that are logic, not pixels: S-10 favicons that would draw
// as a sliver fall back to the globe; the Chats page filter; the Files-in-this-chat table height.
//   make test-unit FILTER=VisualParityM10Tests
import AntiChatHarness
import AppKit
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct VisualParityM10Tests {
    static func png(width: Int, height: Int, opaque: (Int, Int) -> Bool) -> String {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<height {
            for x in 0..<width {
                rep.setColor(opaque(x, y) ? NSColor(deviceRed: 0, green: 0.4, blue: 1, alpha: 1) : NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0), atX: x, y: y)
            }
        }
        return rep.representation(using: .png, properties: [:])!.base64EncodedString()
    }

    @Test func faviconsThatWouldDrawAsASliverFallBackToTheGlobe() {
        #expect(CitationPill.image(Self.png(width: 16, height: 16) { _, _ in true }) != nil)
        #expect(CitationPill.image(Self.png(width: 32, height: 4) { _, _ in true }) == nil)  // a strip
        #expect(CitationPill.image(Self.png(width: 16, height: 16) { x, y in x < 2 && y < 2 }) == nil)  // nearly empty
        #expect(CitationPill.image(nil) == nil && CitationPill.image("not base64") == nil)
    }

    @Test func chatsPageFiltersByEveryWord() {
        let now = Date()
        func chat(_ id: String, _ title: String) -> ChatSummary {
            ChatSummary(id: id, title: title, titlePending: false, updatedAt: now)
        }
        let all = [chat("a", "Plan a relaxed weekend"), chat("b", "Seafood dishes"), chat("c", "")]
        #expect(ChatsPage.filter(all, query: "", untitled: "New chat").map(\.id) == ["a", "b", "c"])
        #expect(ChatsPage.filter(all, query: "WEEKEND plan", untitled: "New chat").map(\.id) == ["a"])
        #expect(ChatsPage.filter(all, query: "new", untitled: "New chat").map(\.id) == ["c"])
        #expect(ChatsPage.filter(all, query: "zebra", untitled: "New chat").isEmpty)
    }

    /// S-08: a reply that opens with a heading drops the heading's top margin (the user → answer gap was ~80 pt).
    @Test func leadingHeadingMargin() {
        #expect(MarkdownBlock.leadingHeadingMargin("## A weekend in Lisbon") == 24)
        #expect(MarkdownBlock.leadingHeadingMargin("#### Small") == 10)
        #expect(MarkdownBlock.leadingHeadingMargin("Here is a plan") == 0)
        #expect(MarkdownBlock.leadingHeadingMargin("#hashtag") == 0)
    }

    @Test func filesInChatTableIsAsTallAsItsRows() {
        #expect(ChatFileRow.tableHeight(rows: 2) < ChatFileRow.tableHeight(rows: 3))
        #expect(ChatFileRow.tableHeight(rows: 2) < 240)
        #expect(ChatFileRow.tableHeight(rows: 50) == ChatFileRow.tableHeight(rows: 10))
    }
}
