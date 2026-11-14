// Q-015 r6 (QueueTests.testFollowUpQueued): TranscriptList keeps following when the content or the bottom margin
// (queued follow-up bubbles) grows under a still offset; a reader's own scroll still detaches.
//   make test-unit FILTER=TranscriptFollowTests
import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import AntiChatUI

@Suite(.isolatedSettings) struct TranscriptFollowTests {
    private func g(away: Bool, content: CGFloat, inset: CGFloat, offset: CGFloat) -> FollowGeometry {
        FollowGeometry(away: away, contentHeight: content, bottomInset: inset, offsetY: offset)
    }

    @Test func queuedBubbleMarginGrowthIsNotAScroll() {
        let before = g(away: false, content: 1_400, inset: 0, offset: 860)
        let after = g(away: true, content: 1_400, inset: 71, offset: 860)
        #expect(FollowGeometry.grewUnderStillOffset(before, after))
    }

    /// Content growth alone is left to the bottom size-change anchor: rows measured above the viewport while the reader
    /// scrolls up grow the content under a still offset too, and must not pull the reader back down.
    @Test func contentGrowthAloneIsNotCounted() {
        let before = g(away: false, content: 1_400, inset: 142, offset: 1_002)
        let after = g(away: true, content: 1_460, inset: 142, offset: 1_002)
        #expect(!FollowGeometry.grewUnderStillOffset(before, after))
    }

    @Test func readerScrollUpStillDetaches() {
        let before = g(away: false, content: 1_400, inset: 0, offset: 860)
        let after = g(away: true, content: 1_400, inset: 0, offset: 600)
        #expect(!FollowGeometry.grewUnderStillOffset(before, after))
        // …even while the reply grows in the same pass.
        #expect(!FollowGeometry.grewUnderStillOffset(before, g(away: true, content: 1_430, inset: 0, offset: 600)))
    }

    /// Only the reader moves the offset up; growth and Jump to bottom move it down or not at all.
    @Test func onlyAnUpwardOffsetIsTheReaders() {
        let at = g(away: true, content: 1_400, inset: 0, offset: 860)
        #expect(FollowGeometry.readerScrolledUp(at, g(away: true, content: 1_400, inset: 0, offset: 500)))
        #expect(!FollowGeometry.readerScrolledUp(at, g(away: true, content: 1_460, inset: 0, offset: 920)))
        #expect(!FollowGeometry.readerScrolledUp(at, g(away: true, content: 1_460, inset: 0, offset: 860)))
    }

    /// RC e8fe19986: the transcript scrolls under the toolbar (52 pt top inset; the container excludes it). At the
    /// very bottom the view is not away; before, the missing top inset read 52 pt (> 24) and left it detached.
    @Test func theBottomUnderAToolbarIsNotAway() {
        // Measured in the app's shape: container 448, top inset 52, content 696, offset 196 = the bottom.
        let at = { (o: CGFloat) in FollowGeometry.away(contentHeight: 696, offsetY: o, containerHeight: 448, topInset: 52,
                                                       bottomInset: 0, threshold: 24) }
        #expect(!at(196))
        #expect(!at(180))
        #expect(at(150))
        // A chat shorter than the view (offset -52, its top under the toolbar) is never away.
        #expect(!FollowGeometry.away(contentHeight: 480, offsetY: -52, containerHeight: 448, topInset: 52, bottomInset: 0,
                                     threshold: 24))
    }

    @Test func contentGrowthUnderAStillOffsetIsSeen() {
        let before = g(away: false, content: 793, inset: 0, offset: 59)
        #expect(FollowGeometry.contentGrewUnderStillOffset(before, g(away: true, content: 968, inset: 0, offset: 59)))
        #expect(!FollowGeometry.contentGrewUnderStillOffset(before, g(away: true, content: 968, inset: 0, offset: 20)))
        #expect(!FollowGeometry.contentGrewUnderStillOffset(before, g(away: false, content: 793, inset: 0, offset: 59)))
    }

    /// Measured in ModelInfoTests after a send: the content shrank 24 pt under a view at the bottom and the offset was
    /// clamped up 24 pt in the next pass. Not the reader (the view is still at the bottom); leaving the bottom is.
    @Test func aClampAtTheBottomIsNotTheReader() {
        let shrunk = g(away: false, content: 906, inset: 0, offset: 196)
        #expect(!FollowGeometry.readerScrolledUp(shrunk, g(away: false, content: 906, inset: 0, offset: 172)))
        #expect(FollowGeometry.readerScrolledUp(shrunk, g(away: true, content: 906, inset: 0, offset: 100)))
    }

    @Test func shrinkingIsNotGrowth() {
        let before = g(away: false, content: 1_400, inset: 142, offset: 860)
        #expect(!FollowGeometry.grewUnderStillOffset(before, g(away: false, content: 1_400, inset: 71, offset: 860)))
    }
}

/// RC e8fe19986 (VideoEntryTests.testAnimateOnImageCard): the pending reply's late-sized content (a video plan card, an
/// image card) appears after the turn's rows were added and grows the last row in one step. A view at the bottom must
/// stay at the bottom; before, the growth under a still offset read as "away", the view detached and the plan card's
/// Start sat below the fold.
extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct TranscriptFollowHostTests {
    @MainActor @Observable final class Model {
        var count: Int
        var lastHeight: CGFloat = 40
        init(count: Int) { self.count = count }
    }

    struct Row: Identifiable, Equatable { let id: Int }

    struct List: View {
        let model: Model
        var body: some View {
            TranscriptList(items: (0..<model.count).map { Row(id: $0) }, startDate: nil) { r in
                Color.gray.opacity(0.2)
                    .frame(height: r.id == model.count - 1 ? model.lastHeight : 120)
                    .frame(maxWidth: .infinity)
            }
            // The window's toolbar: the app's transcript scrolls under it (a 52 pt top inset).
            .safeAreaPadding(.top, 52)
        }
    }

    private func distanceFromBottom(_ h: RendererRig.Host) -> CGFloat? {
        guard let scroll = TranscriptMeasureTests.find(NSScrollView.self, in: h.host).first,
              let doc = scroll.documentView else { return nil }
        let clip = scroll.contentView.bounds
        return doc.frame.height - (clip.origin.y + clip.height)
    }

    private func frames(_ h: RendererRig.Host, _ n: Int) async {
        for _ in 0..<n {
            try? await Task.sleep(for: .milliseconds(20))
            h.host.layoutSubtreeIfNeeded()
            h.host.displayIfNeeded()
        }
    }

    /// `rows` rows of 120 pt (+ gaps) in a 500 pt view, a new turn appended, then its last row jumps 40 → 360 pt.
    private func grow(rows: Int) async throws -> CGFloat {
        _ = NSApplication.shared
        let model = Model(count: rows)
        let h = RendererRig.Host(List(model: model).frame(height: 500), look: .light)
        h.layout()
        await frames(h, 8)
        model.count += 2  // a new turn: the user's message and the pending reply
        await frames(h, 8)
        model.lastHeight = 360  // the reply's card arrives
        await frames(h, 12)
        return try #require(distanceFromBottom(h))
    }

    /// ModelInfoTests (r7att): after the reader left the bottom (a Stop mid-reply, Jump to bottom showing), a send
    /// re-pins, and the next reply's growth is followed again.
    @Test func aSendRePinsAfterTheReaderLeftTheBottom() async throws {
        _ = NSApplication.shared
        let model = Model(count: 8)
        let h = RendererRig.Host(List(model: model).frame(height: 500), look: .light)
        h.layout()
        await frames(h, 8)
        let scroll = try #require(TranscriptMeasureTests.find(NSScrollView.self, in: h.host).first)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 0))  // the reader scrolls up
        scroll.reflectScrolledClipView(scroll.contentView)
        await frames(h, 8)
        #expect(try #require(distanceFromBottom(h)) > 200, "the reader is away")
        try? await Task.sleep(for: .milliseconds(900))  // the reader's scroll is over
        model.count += 2  // a send
        await frames(h, 8)
        for step in 1...8 {  // the reply streams in
            model.lastHeight = 40 + CGFloat(step) * 50
            await frames(h, 2)
        }
        await frames(h, 6)
        let d = try #require(distanceFromBottom(h))
        #expect(d <= TranscriptList<Row, EmptyView>.attachThreshold, "the reply ended \(d) pt below the view")
    }

    /// ModelInfoTests: each send first shrank the content under the view (the offset clamped up), then the reply grew.
    @Test func aShrinkThenGrowthAtTheBottomKeepsFollowing() async throws {
        _ = NSApplication.shared
        let model = Model(count: 8)
        let h = RendererRig.Host(List(model: model).frame(height: 500), look: .light)
        h.layout()
        await frames(h, 8)
        for turn in 0..<3 {
            model.lastHeight = 200
            await frames(h, 4)
            model.lastHeight = 176  // shrinks 24 pt at the bottom: the offset is clamped up
            await frames(h, 4)
            model.count += 2
            model.lastHeight = 40
            await frames(h, 4)
            for step in 1...6 {
                model.lastHeight = 40 + CGFloat(step) * 40
                await frames(h, 2)
            }
            await frames(h, 4)
            let d = try #require(distanceFromBottom(h))
            #expect(d <= TranscriptList<Row, EmptyView>.attachThreshold, "turn \(turn): \(d) pt below the view")
        }
    }

    @Test func lastRowGrowingWhileAtTheBottomStaysAtTheBottom() async throws {
        let d = try await grow(rows: 6)
        #expect(d <= TranscriptList<Row, EmptyView>.attachThreshold, "the view was left \(d) pt above the bottom")
    }

    /// The failing shape: the chat fitted the view until the new turn, so the first growth that makes it scroll comes
    /// from the card.
    @Test func lastRowGrowingPastAShortChatStaysAtTheBottom() async throws {
        let d = try await grow(rows: 1)
        #expect(d <= TranscriptList<Row, EmptyView>.attachThreshold, "the view was left \(d) pt above the bottom")
    }
}
}
