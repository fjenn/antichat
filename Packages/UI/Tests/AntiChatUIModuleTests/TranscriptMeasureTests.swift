// fix/u5-renderer-3 guard (NFR-U5, AT-008 at -RendererCPUScale 0.25): the window's minimum-size and alignment
// queries must not measure the transcript. The perf-build probe's profile put 34 % of the main thread under
// NSHostingView.minSize while a reply streamed: a stack above the transcript asked its alignment guide, the
// ScrollView's frame answered by placing (measuring) the ScrollView, and that laid out every reply's text again at
// the query's proposal, on every pass. Counts work (row measurements), not time.
//   make test-unit FILTER=TranscriptMeasureTests
import AppKit
import SwiftUI
import Testing
@testable import AntiChatUI

/// Counts the size queries that reach a transcript row.
struct RowMeasureCounter: Layout {
    nonisolated(unsafe) static var queries = 0
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        Self.queries += 1
        return subviews.first?.sizeThatFits(proposal) ?? .zero
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews { s.place(at: bounds.origin, proposal: proposal) }
    }
}

@MainActor @Observable final class MeasureModel {
    var tail = ""
}

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct TranscriptMeasureTests {
    struct Row: Identifiable, Equatable { let id: Int }

    /// The app's shape: the transcript inside stacks with non-default alignment (ConversationView / the split view),
    /// in a window whose hosting view asks for its minimum size on every layout pass.
    @Test func windowSizeAndAlignmentQueriesDoNotMeasureTheRows() async throws {
        _ = NSApplication.shared
        let model = MeasureModel()
        let items = (0..<6).map { Row(id: $0) }
        let paragraph = String(repeating: "The quiet harbour town wakes slowly while gulls argue over the catch. ", count: 6)
        let root = HStack(alignment: .firstTextBaseline, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Title")
                TranscriptList(items: items, startDate: nil) { row in
                    RowMeasureCounter {
                        Text(row.id == items.count - 1 ? paragraph + model.tail : paragraph)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 900, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        BackgroundRun.present(window)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded()
        }

        // Size queries (what NSHostingView.minSize / the window's content-size limits ask on each pass), after the
        // pass that measured the grown row: they find no layout to redo and must not measure rows at all.
        model.tail += " More words."
        try? await Task.sleep(for: .milliseconds(1))
        host.layoutSubtreeIfNeeded()
        RowMeasureCounter.queries = 0
        _ = host.fittingSize
        _ = host.intrinsicContentSize
        let sizeQueryMeasures = RowMeasureCounter.queries
        // One streaming step through the window's own layout pass: the grown row is measured, its finished
        // siblings answer from their caches.
        RowMeasureCounter.queries = 0
        model.tail += " And more."
        try? await Task.sleep(for: .milliseconds(1))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let passMeasures = RowMeasureCounter.queries
        print("TranscriptMeasure: size queries measured rows \(sizeQueryMeasures) times; a layout pass \(passMeasures)")
        // Measured: with the transcript's old `.frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, …)` the pass
        // measured the grown row 3 times (its own layout, then again for the stacks' alignment queries, at other
        // proposals); with `OpaqueFill` once.
        #expect(sizeQueryMeasures == 0, "window size queries measured transcript rows \(sizeQueryMeasures) times")
        #expect(passMeasures <= 2, "one growth step measured the grown row \(passMeasures) times (3 = the alignment re-measure)")
    }

    /// fix/u5-renderer-4: sending in a long chat appends two rows. With the eager tail always the newest 8 rows, the
    /// two oldest eager rows moved into the lazy stack — a new parent, so their views (MarkdownView parse, text
    /// layout, selection overlays) were built again, and the lazy stack re-estimated its rows: the AT-008 long-chat
    /// probe's 100–190 ms passes in the first 2 s of every reply. Appending a turn must build only the new rows.
    @Test func appendingATurnBuildsOnlyTheNewRows() async throws {
        let model = AppendModel(count: 61)
        let reply = LongReply.text(sections: 2)
        let h = RendererRig.Host(AppendTranscript(model: model, reply: reply).frame(height: 700), look: .light)
        h.layout()
        await h.settle(min: 0.5, stableFor: 0.3, max: 6)
        var rebuilt: [Int] = []
        for _ in 0..<6 {  // three turns of two rows: every split position the rule can hit
            let made = RendererBodyCounters.binders
            model.count += 1
            for _ in 0..<4 {
                try? await Task.sleep(for: .milliseconds(20))
                h.host.layoutSubtreeIfNeeded()
                h.host.displayIfNeeded()
            }
            rebuilt.append(RendererBodyCounters.binders - made)
        }
        print("TranscriptMeasure append: replies built per appended row \(rebuilt)")
        // Each append builds its own row; older rows move (and some are rebuilt) at most once per `splitStep` appends.
        // Before: every append rebuilt an older reply ([2, 2, 2, 2, 2, 2]).
        let step = TranscriptList<AppendTranscript.Row, EmptyView>.splitStep
        let moves = rebuilt.filter { $0 > 1 }.count
        #expect(rebuilt.allSatisfy { $0 >= 1 }, "an appended row was not built: \(rebuilt)")
        #expect(moves <= (rebuilt.count + step - 1) / step, "older replies rebuilt on \(moves) of \(rebuilt.count) appends: \(rebuilt)")
    }

    /// fix/t05-u5-part5: Jump to bottom fades in and out on its own. On the scroll view, `.animation(value: detached)`
    /// animated every change that landed in the update where `detached` flipped, so a reply growing under the view
    /// (away for a pass until the anchor catches up) had every row's text display list interpolated (perf-build
    /// profile at the reply's end: InterpolatedDisplayList / ResolvedStyledText.modifyTransition). No row update may
    /// carry an animation, whether the reader is following, scrolls away, or the reply grows meanwhile.
    @Test func rowsNeverUpdateInAnAnimatedTransaction() async throws {
        let model = GrowModel()
        let h = RendererRig.Host(GrowTranscript(model: model).frame(height: 500), look: .light)
        h.layout()
        await h.settle(min: 0.3, stableFor: 0.2, max: 4)
        func frames(_ n: Int) async {
            for _ in 0..<n {
                try? await Task.sleep(for: .milliseconds(15))
                h.host.layoutSubtreeIfNeeded()
                h.host.displayIfNeeded()
            }
        }
        GrowModel.animatedRowUpdates = 0
        GrowModel.rowUpdates = 0
        for _ in 0..<30 {  // the last row grows under an attached view
            model.lines += 1
            await frames(1)
        }
        // The reader scrolls away while it keeps growing (Jump to bottom shows), then jumps back.
        if let scroll = Self.find(NSScrollView.self, in: h.host).first {
            for _ in 0..<10 {
                scroll.contentView.scroll(to: CGPoint(x: 0, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
                model.lines += 1
                await frames(1)
            }
            scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        for _ in 0..<10 {
            model.lines += 1
            await frames(1)
        }
        print("TranscriptMeasure animation: \(GrowModel.animatedRowUpdates) animated of \(GrowModel.rowUpdates) row updates")
        #expect(GrowModel.rowUpdates > 0, "no row update was seen")
        #expect(GrowModel.animatedRowUpdates == 0, "\(GrowModel.animatedRowUpdates) row updates were animated")
    }

    /// M9.T05 (NFR-U11): a long chat's first frame lays out its newest `openingRows` rows only; the history joins the
    /// lazy section once that frame has committed, and every row is then reachable.
    @Test func aLongChatOpensWithItsNewestRowsThenTheHistory() async throws {
        typealias List = TranscriptList<Row, EmptyView>
        #expect(List.firstShown(items: 1000, historyShown: false) == 1000 - List.openingRows)
        #expect(List.firstShown(items: 10, historyShown: false) == 0)
        #expect(List.firstShown(items: 1000, historyShown: true) == 0)
        let items = (0..<1000).map { Row(id: $0) }
        let seen = SeenRows()
        let root = TranscriptList(items: items, startDate: nil) { row in
            Text("Row \(row.id)").frame(maxWidth: .infinity, alignment: .leading).onAppear { seen.ids.insert(row.id) }
        }
        let h = RendererRig.Host(root.frame(height: 600), look: .light)
        h.host.layoutSubtreeIfNeeded()
        h.host.displayIfNeeded()
        let opening = seen.ids
        #expect(!opening.isEmpty && opening.allSatisfy { $0 >= 1000 - List.openingRows },
                "the first frame drew \(opening.count) rows, oldest \(opening.min() ?? -1)")
        #expect(opening.contains(999), "the newest row is in the first frame")
        // After the commit the history is in the list: scrolling to the top reaches row 0.
        func frames(_ n: Int) async {
            for _ in 0..<n {
                try? await Task.sleep(for: .milliseconds(30))
                h.host.layoutSubtreeIfNeeded()
                h.host.displayIfNeeded()
            }
        }
        await frames(6)
        if let scroll = Self.find(NSScrollView.self, in: h.host).first {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        await frames(4)
        #expect(seen.ids.contains(0), "the history never joined the list")
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var out: [T] = []
        if let v = view as? T { out.append(v) }
        for s in view.subviews { out += find(type, in: s) }
        return out
    }
}
}  // extension WindowSuites

@MainActor final class SeenRows {
    var ids = Set<Int>()
}

@MainActor @Observable final class GrowModel {
    var lines = 1
    nonisolated(unsafe) static var animatedRowUpdates = 0
    nonisolated(unsafe) static var rowUpdates = 0
}

struct GrowTranscript: View {
    struct Row: Identifiable, Equatable { let id: Int }
    let model: GrowModel
    var body: some View {
        TranscriptList(items: (0..<12).map { Row(id: $0) }, startDate: nil) { r in
            GrowRow(model: model, id: r.id)
        }
    }
}

private struct GrowRow: View {
    let model: GrowModel
    let id: Int
    var body: some View {
        let n = id == 11 ? model.lines : 3
        Text(String(repeating: "Row \(id) has words that wrap across the reading column. ", count: n))
            .frame(maxWidth: .infinity, alignment: .leading)
            .transaction { t in
                GrowModel.rowUpdates += 1
                if t.animation != nil { GrowModel.animatedRowUpdates += 1 }
            }
    }
}

@MainActor @Observable final class AppendModel {
    var count: Int
    init(count: Int) { self.count = count }
}

struct AppendTranscript: View {
    struct Row: Identifiable, Equatable { let id: Int }
    let model: AppendModel
    let reply: String
    var body: some View {
        TranscriptList(items: (0..<model.count).map { Row(id: $0) }, startDate: nil) { _ in
            MessageMarkdownView(text: reply, streaming: false)
        }
    }
}
