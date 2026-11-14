// fix/u5-renderer guard (NFR-U5, AT-008 on the S1 stand-in): the work of one reveal tick must not grow with the
// reply. M9.T05 measured an apply median of 124.7 ms and 723 main-thread passes > 33 ms at -RendererCPUScale 0.25,
// with every tick re-slicing and re-diffing the whole block stack. These tests pin the structure that bounds it:
// - MarkdownSegmenter: root blocks and the stability rule (what may be frozen);
// - the binder's append-only blocks equal a full segmentation, a tick re-segments only the unstable tail, and a
//   block keeps its identity from its first reveal to the end;
// - hosted: a tick re-evaluates the live block rows only (view-body counters), lays out the growing block's stack
//   only (layout counters: rows in the stacks measured or placed), and re-segments the unstable tail only (at most
//   one apply re-splitting a few blocks). These counters are exact and load-independent; they are the guard. The
//   tick's main-thread CPU (medians, late vs early) is kept as a loose secondary bound: a CPU ratio alone swung
//   with the shared Mac's load (13.09 vs 5.22 ms failed, 10.03 vs 4.61 ms passed), and the flat stack it was meant
//   to catch measured 2.13 → 3.07 ms once (passed), while its layout counter reads 83 rows per tick (fails, ≤ 16).
//   Measured (Debug, this Mac, 12 → 94 blocks): the old flat selectable stack 3.7 → 10.4 ms per tick; fixed chunks +
//   no selection while streaming 3.4 → 6.2 ms; rows laid out per tick ~6 → ~5 (fixed chunks) vs 18 → 83 (flat).
//   make test-unit FILTER=RendererTickCostTests
import AppKit
import Darwin
import SwiftUI
import Testing
@testable import AntiChatUI

@Suite(.isolatedSettings) struct MarkdownSegmenterTests {
    static func sources(_ text: String) -> [String] {
        MarkdownSegmenter.split(text).blocks.map { MarkdownSegmenter.slice(text, $0) }
    }

    @Test func paragraphsAndHeadings() {
        let t = "# Title\n\nFirst paragraph.\n\nSecond one"
        #expect(Self.sources(t) == ["# Title", "First paragraph.", "Second one"])
        #expect(MarkdownSegmenter.split(t).stable == 2)  // the last block may still grow
    }

    @Test func blocksWithoutBlankLineStayUnstable() {
        let t = "## Heading\nText right under it"
        #expect(Self.sources(t) == ["## Heading", "Text right under it"])
        #expect(MarkdownSegmenter.split(t).stable == 0)  // MarkdownView's rule: only a blank line freezes
    }

    @Test func fencedCodeKeepsItsBlankLines() {
        let t = "```swift\nlet a = 1\n\nlet b = 2\n```\n\nAfter"
        #expect(Self.sources(t) == ["```swift\nlet a = 1\n\nlet b = 2\n```", "After"])
        #expect(MarkdownSegmenter.split(t).stable == 1)
        // An unclosed fence runs to the end: one unstable block.
        let open = "Intro\n\n```python\nx = 1\n\ny = 2"
        #expect(Self.sources(open) == ["Intro", "```python\nx = 1\n\ny = 2"])
        #expect(MarkdownSegmenter.split(open).stable == 1)
    }

    @Test func displayMathAcrossBlankLineIsOneBlock() {
        let t = "$$\na = b\n\nc = d\n$$\n\nAfter"
        #expect(Self.sources(t) == ["$$\na = b\n\nc = d\n$$", "After"])
        #expect(MarkdownSegmenter.split(t).stable == 1)
    }

    @Test func looseListIsOneBlock() {
        #expect(Self.sources("- a\n\n- b\n\n- c") == ["- a\n\n- b\n\n- c"])
        // cmark ends a list on the line after it (MarkdownView's own ranges slice it the same way).
        #expect(Self.sources("1. one\n2. two\n\nNext") == ["1. one\n2. two\n", "Next"])
    }

    @Test func tableIsOneBlock() {
        let t = "| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter"
        #expect(Self.sources(t) == ["| a | b |\n|---|---|\n| 1 | 2 |", "After"])
    }

    @Test func nonASCIIBytesAndEdges() {
        #expect(Self.sources("Café ☕ ok\n\nnext ü") == ["Café ☕ ok", "next ü"])
        #expect(Self.sources("").isEmpty)
        #expect(Self.sources("\n\n  \n").isEmpty)
        #expect(Self.sources("\n\nLeading blank lines") == ["Leading blank lines"])
    }
}

/// fix/u5-renderer-2: the word fade draws whole lines except the ones holding a fading glyph. A Text drawn through a
/// TextRenderer is rasterised on the CPU on every redraw; drawing each glyph slice of a long paragraph separately was
/// 23 % of the main thread in the window-hosted profile (now about 3 %).
@MainActor
@Suite(.isolatedSettings) struct WordFadeDrawTests {
    func draw(_ text: String, now: Double, ledger: FadeLedger) {
        let view = Text(verbatim: text)
            .font(.system(size: 13))
            .frame(width: 420, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textRenderer(WordFadeRenderer(now: now, ledger: ledger))
        let r = ImageRenderer(content: view)
        r.scale = 2
        _ = r.cgImage
    }

    @Test func onlyTheLinesWithFadingWordsAreDrawnGlyphByGlyph() {
        let ledger = FadeLedger(fade: 0.18)
        let old = String(repeating: "The quiet harbour town wakes slowly. ", count: 40)  // ~1,500 characters, many lines
        draw(old, now: 0, ledger: ledger)
        draw(old, now: 1, ledger: ledger)  // everything opaque
        let before = ledger.probeCounters
        draw(old + "Gulls argue", now: 1, ledger: ledger)  // two new words, fading
        let c = ledger.probeCounters
        let lines = c.lineDraws - before.lineDraws, slices = c.sliceDraws - before.sliceDraws
        print("WordFadeDraw: \(lines) whole lines, \(slices) glyph slices")
        #expect(c.fadingDraws > before.fadingDraws, "the new words fade")
        #expect(lines >= 10, "old lines are drawn whole: \(lines)")
        #expect(slices <= 200, "only the last line(s) glyph by glyph: \(slices) of ~1,500 glyphs")
    }
}

/// A long reply with every block kind the renderer splits: ~`sections` × 1.3 KB.
enum LongReply {
    static func text(sections: Int) -> String {
        var s = ""
        for i in 0..<sections {
            s += "## Section \(i)\n\n"
            s += String(repeating: "The quiet harbour town wakes slowly while gulls argue over the catch. ", count: 8) + "\n\n"
            s += "- first point \(i)\n- second point with **bold** text\n- third point\n\n"
            if i % 3 == 0 { s += "```python\nfor n in range(\(i)):\n    print(n)\n\nprint('done')\n```\n\n" }
            if i % 4 == 1 { s += "| item | price |\n|---|---|\n| apples | \(i) |\n| honey | 4 |\n\n" }
            if i % 5 == 2 { s += "With the average $\\bar{p} = \\frac{1}{n}\\sum_i p_i$ the estimate holds.\n\n" }
            if i % 7 == 3 { s += "$$\nx = \\frac{a}{b}\n$$\n\n" }
        }
        return s
    }

    /// Streams `text` into `binder` in `chunk`-byte deltas, one clock tick per delta (virtual time, 40 Hz).
    @MainActor
    static func stream(_ text: String, into binder: StreamingMarkdownBinder, chunk: Int = 24,
                       each: (Int) -> Void = { _ in }) -> Double {
        let bytes = Array(text.utf8)
        var t = 1.0
        var end = 0
        var step = 0
        while end < bytes.count || binder.reveal.backlog > 0, step < 200_000 {
            end = min(bytes.count, end + chunk)
            while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }  // never cut a character
            binder.update(text: String(decoding: bytes[0..<end], as: UTF8.self), streaming: true, interrupted: false)
            binder.tick(now: t)
            t += 1.0 / 40
            step += 1
            each(step)
            if end == bytes.count, binder.reveal.backlog <= 1 { break }  // the last word waits for the stream's end
        }
        return t
    }
}

@MainActor
@Suite(.isolatedSettings) struct StreamingBlocksTests {
    @Test func appendOnlyBlocksEqualAFullSegmentation() {
        let text = LongReply.text(sections: 48) + "The end.\n"
        let binder = StreamingMarkdownBinder(text: "", streaming: true)
        var first: ObjectIdentifier?
        var maxTail = 0
        _ = LongReply.stream(text, into: binder) { _ in
            if first == nil, let b = binder.blocks.first { first = ObjectIdentifier(b) }
            maxTail = max(maxTail, binder.lastSegmentedBytes)
        }
        let full = MarkdownSegmenterTests.sources(text)
        #expect(binder.blocks.map { $0.source } == full)
        #expect(binder.blocks.map { $0.id } == Array(0..<full.count))
        // The first block is the same object from its first reveal to the end (its view is never rebuilt).
        #expect(binder.blocks.first.map(ObjectIdentifier.init) == first)
        // Each apply re-segmented the unstable tail only: never more than the two largest blocks of the reply,
        // whatever its length (the reply is ~40 KB).
        let largest = full.map { $0.utf8.count }.sorted(by: >).prefix(2).reduce(0, +)
        print("StreamingBlocks: \(full.count) blocks, \(text.utf8.count) B, max tail \(maxTail) B")
        #expect(maxTail <= largest + 64)
        #expect(text.utf8.count > 30_000)
    }

    @Test func stableBlocksRetireAfterTheirFade() {
        let binder = StreamingMarkdownBinder(text: "", streaming: true)
        let t = LongReply.stream(LongReply.text(sections: 4), into: binder)
        // Everything but the unstable tail has settled: at most the last two blocks are live.
        var now = t
        for _ in 0..<20 {
            now += 1.0 / 40
            binder.tick(now: now)
        }
        let live = binder.blocks.filter { $0.live }.count
        #expect(live <= 2, "live blocks: \(live) of \(binder.blocks.count)")
        // Finished: after the fade nothing is live and the clock stops (once selection is back: it starts
        // `selectionDelay` after the last word, one block per tick).
        binder.update(text: binder.reveal.target, streaming: false, interrupted: false)
        for _ in 0..<(40 + Int(StreamingMarkdownBinder.selectionDelay * 40) + binder.blocks.count) {
            now += 1.0 / 40
            binder.tick(now: now)
        }
        #expect(binder.blocks.allSatisfy { !$0.live })
        #expect(!binder.animating)
    }

    /// fix/u5-renderer-4: a streaming table re-renders once per completed row, not on every reveal tick (each
    /// re-render rebuilds every cell and re-measures the grid). Counts the table block's source changes.
    @Test func aStreamingTableChangesOncePerRow() {
        var table = "| item | crates | price | revenue |\n|---|---:|---:|---:|\n"
        for i in 0..<12 { table += "| stall number \(i) | \(i * 3) | \(i).50 | \(i * 7).25 |\n" }
        let text = "Intro line.\n\n" + table + "\nAfter the table.\n"
        let binder = StreamingMarkdownBinder(text: "", streaming: true)
        var versions: [String] = []
        _ = LongReply.stream(text, into: binder, chunk: 6) { _ in
            guard binder.blocks.count >= 2, binder.blocks[1].source.contains("\n|---|") else { return }  // a table by now
            let s = binder.blocks[1].source
            if versions.last != s { versions.append(s) }
        }
        print("StreamingBlocks table: \(versions.count) table versions for 12 rows")
        #expect(versions.count <= 12 + 3, "the table re-rendered \(versions.count) times for 12 rows")
        #expect(binder.blocks.map { $0.source } == MarkdownSegmenterTests.sources(text), "the finished table is whole")
    }

    /// fix/q60-table-stream: a row whose newline has arrived is complete, even though the reveal holds that newline
    /// back (it is the leading whitespace of the next word): a drained, still-streaming table shows its last row.
    @Test func aDrainedStreamingTableShowsItsLastRow() {
        let table = "| fruit | crates |\n| --- | ---: |\n| Apples | 7 |\n| Pears | 18 |"
        let binder = StreamingMarkdownBinder(text: "", streaming: true)
        binder.update(text: "Intro line.\n\n" + table + "\n", streaming: true, interrupted: false)
        var t = 1.0
        while binder.reveal.backlog > 1, t < 60 {
            binder.tick(now: t)
            t += 1.0 / 60
        }
        #expect(binder.reveal.backlog == 1)  // the trailing newline, held back
        #expect(binder.blocks.last?.source == table)
        // Without that newline the last row may still grow: it stays hidden.
        let open = StreamingMarkdownBinder(text: "", streaming: true)
        open.update(text: "Intro line.\n\n" + table + " more", streaming: true, interrupted: false)
        t = 1.0
        while open.reveal.backlog > 5, t < 60 {  // " more" is never revealed (no whitespace after it)
            open.tick(now: t)
            t += 1.0 / 60
        }
        #expect(open.blocks.last?.source == "| fruit | crates |\n| --- | ---: |\n| Apples | 7 |")
    }

    /// fix/u5-renderer-4: a streaming fenced code block re-renders once per completed line, not on every tick.
    @Test func aStreamingCodeBlockChangesOncePerLine() {
        var code = "```python\n"
        for i in 0..<16 { code += "total_\(i) = sum(price * crates for price, crates in stalls[\(i)])\n" }
        code += "```"
        let text = "Intro line.\n\n" + code + "\n\nAfter the code.\n"
        let binder = StreamingMarkdownBinder(text: "", streaming: true)
        var versions: [String] = []
        _ = LongReply.stream(text, into: binder, chunk: 6) { _ in
            guard binder.blocks.count >= 2, binder.blocks[1].source.hasPrefix("```") else { return }
            let s = binder.blocks[1].source
            if versions.last != s { versions.append(s) }
        }
        print("StreamingBlocks code: \(versions.count) code block versions for 16 lines")
        #expect(versions.count <= 16 + 3, "the code block re-rendered \(versions.count) times for 16 lines")
        #expect(binder.blocks.map { $0.source } == MarkdownSegmenterTests.sources(text), "the finished code block is whole")
    }

    /// fix/t05-u5-part5: at the reply's end the blocks' stream flags turn off: prose at once (no view reads them), code
    /// blocks one per clock tick (each one's full highlighting / Mermaid / promoted card is its own pass). Before, one
    /// environment flip over the whole reply re-measured every block in the finishing pass.
    @Test func codeBlocksSettleOnePerTickAfterTheReplysEnd() {
        var text = "Intro line.\n\n"
        for i in 0..<3 { text += "```python\nprint(\(i))\nprint('again')\n```\n\nA paragraph after block \(i).\n\n" }
        let binder = StreamingMarkdownBinder(text: "", streaming: true)
        var now = LongReply.stream(text, into: binder)
        #expect(binder.blocks.allSatisfy { $0.stream.streaming }, "streamed blocks start in their streaming form")
        binder.update(text: text, streaming: false, interrupted: false)
        var settled: [Int] = []  // code blocks still streaming, per tick, until the source has finished
        var finishedAt: Int?
        for i in 0..<200 {
            now += 1.0 / 40
            binder.tick(now: now)
            guard binder.sourceFinished else { continue }
            if finishedAt == nil {
                finishedAt = i
                #expect(binder.blocks.filter { !$0.isCode }.allSatisfy { !$0.stream.streaming }, "prose flags settle at once")
            }
            settled.append(binder.blocks.filter { $0.isCode && $0.stream.streaming }.count)
            if settled.last == 0 { break }
        }
        print("StreamingBlocks settle: code blocks streaming per tick \(settled)")
        #expect(finishedAt != nil, "the source never finished")
        #expect(settled.first.map { $0 >= 2 } == true, "all code blocks settled in the finishing tick: \(settled)")
        #expect(zip(settled, settled.dropFirst()).allSatisfy { $0 - $1 <= 1 }, "more than one code block per tick: \(settled)")
        #expect(settled.last == 0)
        // The clock keeps running until they have.
        for _ in 0..<(40 + Int(StreamingMarkdownBinder.selectionDelay * 40) + binder.blocks.count) {
            now += 1.0 / 40
            binder.tick(now: now)
        }
        #expect(!binder.animating)
        // A finished reply opened later shows its final form from the start.
        let opened = StreamingMarkdownBinder(text: text, streaming: false)
        #expect(opened.blocks.allSatisfy { !$0.stream.streaming })
    }

    /// fix/t05-u5-part6: the reveal clock stops after the same ticks whether the final segmentation of a long reply has
    /// landed or is still running off the main thread: it never waits for it.
    @Test func theClockDoesNotWaitForTheFinalSegmentation() {
        let text = LongReply.text(sections: 8)  // > `syncSegmentBytes`: segmented off the main thread
        #expect(text.utf8.count > StreamingMarkdownBinder.syncSegmentBytes)
        func ticksToStop(inline: Bool) -> Int {
            let binder = StreamingMarkdownBinder(text: "", streaming: true)
            binder.segmentsSynchronously = inline
            var now = LongReply.stream(text, into: binder)
            binder.update(text: text, streaming: false, interrupted: false)
            var ticks = 0
            while binder.animating, ticks < 2000 {  // no await: an off-main result cannot land meanwhile
                ticks += 1
                now += 1.0 / 40
                binder.tick(now: now)
            }
            #expect(!binder.animating)
            return ticks
        }
        let inline = ticksToStop(inline: true), pending = ticksToStop(inline: false)
        print("StreamingBlocks clock: \(inline) ticks with the final segmentation inline, \(pending) with it pending")
        #expect(pending == inline)
    }

    @Test func replacedTextRebuildsTheBlocks() {
        let binder = StreamingMarkdownBinder(text: "", streaming: true)
        var now = LongReply.stream("First paragraph here.\n\nSecond paragraph here.\n\n", into: binder)
        #expect(binder.blocks.map { $0.source } == ["First paragraph here.", "Second paragraph here."])
        // Not an append (an edit of the streamed text): the reveal moves back and the blocks follow it.
        binder.update(text: "Other text entirely.\n\n", streaming: false, interrupted: true)
        now += 1.0 / 40
        binder.tick(now: now)
        #expect(binder.blocks.map { $0.source } == ["Other text entirely."])
    }

    /// Ticks until the clock stops (or `limit`); returns the ticks it took, nil if it never stopped.
    private func ticksUntilStopped(_ binder: StreamingMarkdownBinder, from start: Double, limit: Int = 2000) -> Int? {
        var now = start
        for i in 1...limit {
            now += 1.0 / 40
            binder.tick(now: now)
            if !binder.animating { return i }
        }
        return nil
    }

    /// fix/review U1: the final text is a prefix of the streamed one (a trailing paragraph or marker dropped when the
    /// reply settles). The reveal rewinds to a point it has already shown with nothing left to reveal; before, no tick
    /// applied it: the removed text stayed on screen and the 40 Hz clock never stopped.
    @Test func aShorterFinalTextDropsTheRemovedTextAndStopsTheClock() {
        let streamed = "First paragraph here.\n\nSecond paragraph here.\n\nA third paragraph [1].\n\n"
        let final = "First paragraph here.\n\nSecond paragraph here."
        let binder = StreamingMarkdownBinder(text: "", streaming: true)
        binder.segmentsSynchronously = true
        let now = LongReply.stream(streamed, into: binder)
        #expect(binder.blocks.map { $0.source } == ["First paragraph here.", "Second paragraph here.", "A third paragraph [1]."])
        let first = binder.blocks.first.map(ObjectIdentifier.init)
        binder.update(text: final, streaming: false, interrupted: false)
        #expect(binder.reveal.isComplete)  // rewound with nothing left to reveal
        let ticks = ticksUntilStopped(binder, from: now)
        #expect(ticks != nil, "the reveal clock never stopped")
        #expect(binder.sourceFinished)
        #expect(binder.blocks.map { $0.source } == ["First paragraph here.", "Second paragraph here."])
        #expect(binder.appliedBytes == final.utf8.count)
        // The unchanged blocks kept their views (no rebuild, no re-fade of words already shown).
        #expect(binder.blocks.first.map(ObjectIdentifier.init) == first)
    }

    /// fix/review U1: the shorter final text cuts into the last streamed word (the reveal rewinds to a word boundary
    /// and re-reveals the cut word): the screen ends on the final text and the clock stops.
    @Test func aShorterFinalTextCutMidWordEndsOnTheFinalText() {
        let streamed = "First paragraph here.\n\nSecond paragraph here [1] and more.\n\n"
        let final = "First paragraph here.\n\nSecond paragraph here."
        let binder = StreamingMarkdownBinder(text: "", streaming: true)
        binder.segmentsSynchronously = true
        let now = LongReply.stream(streamed, into: binder)
        binder.update(text: final, streaming: false, interrupted: false)
        #expect(ticksUntilStopped(binder, from: now) != nil, "the reveal clock never stopped")
        #expect(binder.blocks.map { $0.source } == ["First paragraph here.", "Second paragraph here."])
    }

    /// fix/review U1: a long reply (final segmentation off the main thread) that ends shorter: the clock stops without
    /// waiting for the segmentation, which then shows the final text.
    @Test func aLongShorterFinalTextStopsTheClockAndSettlesOffMain() async {
        let final = LongReply.text(sections: 8)
        let streamed = final + "A trailing paragraph that the final text drops.\n\n"
        #expect(final.utf8.count > StreamingMarkdownBinder.syncSegmentBytes)
        let binder = StreamingMarkdownBinder(text: "", streaming: true)
        let now = LongReply.stream(streamed, into: binder)
        binder.update(text: final, streaming: false, interrupted: false)
        #expect(ticksUntilStopped(binder, from: now) != nil, "the reveal clock never stopped")
        for _ in 0..<200 where binder.blocks.map({ $0.source }) != MarkdownSegmenterTests.sources(final) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(binder.blocks.map { $0.source } == MarkdownSegmenterTests.sources(final))
    }
}

/// Hosted: the per-tick cost of the real views.
extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct RendererTickCostTests {
    static func mainThreadCPU() -> Double { TranscriptIdleCostTests.mainThreadCPU() }

    @Test func aTickReEvaluatesTheLiveBlocksOnly() async throws {
        let text = LongReply.text(sections: 24)
        let binder = StreamingMarkdownBinder(text: "", streaming: true)
        // As in the transcript: a bottom-anchored scroll view of fixed size (the reply grows inside it; a host that
        // resized its window on every tick would measure AppKit's window resizing instead).
        let h = RendererRig.Host(
            ScrollView { MessageMarkdownView(binder: binder) }
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .frame(height: 700),
            look: .light)
        h.layout()
        let bytes = Array(text.utf8)
        var end = 0
        var t = CACurrentMediaTime()
        // Per-tick samples. Deterministic counters: blocks on screen, row bodies evaluated, rows in the block stacks laid out
        // (RendererLayoutProbe: a stack measured or placed walks all of its rows), re-segmentations and the blocks they re-split. And the main-thread CPU (tick + SwiftUI
        // update + layout), which swings with the machine's load and is only a loose secondary check.
        struct Sample { let blocks, rows, laidOut, segmentations, segmentedBlocks: Int; let cpu: Double }
        var samples: [Sample] = []
        var split: [(tick: Double, update: Double, layout: Double)] = []
        var farRows: [String] = [], farLayout: [String] = []
        let chunk = StreamingMarkdownBinder.chunk
        _ = binder.takeSegmentations()
        while end < bytes.count {
            end = min(bytes.count, end + 24)
            while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
            RendererBodyCounters.reset()
            let c0 = Self.mainThreadCPU()
            binder.update(text: String(decoding: bytes[0..<end], as: UTF8.self), streaming: true, interrupted: false)
            t = max(t + 1.0 / 40, CACurrentMediaTime())
            binder.tick(now: t)
            let c1 = Self.mainThreadCPU()
            try? await Task.sleep(for: .milliseconds(1))  // the run loop applies the update (SwiftUI's transaction)
            let c2 = Self.mainThreadCPU()
            // Fixed window: lay out and draw, as a display cycle would (Host.layout's fittingSize walks the
            // constraints of every platform view in the window, which the app's transcript never does per frame).
            h.host.layoutSubtreeIfNeeded()
            h.host.displayIfNeeded()
            let cpu = Self.mainThreadCPU() - c0
            split.append((c1 - c0, c2 - c1, cpu - (c2 - c0)))
            let segs = binder.takeSegmentations()
            samples.append(Sample(blocks: binder.blocks.count, rows: RendererBodyCounters.rows,
                                  laidOut: RendererBodyCounters.laidOutChunks.values.reduce(0, +),
                                  segmentations: segs, segmentedBlocks: segs > 0 ? binder.lastSegmentedBlocks : 0, cpu: cpu))
            // Only rows at the end of the reply (the live ones) are re-evaluated by a tick.
            if let oldest = RendererBodyCounters.rowIDs.min(), oldest < binder.blocks.count - 8 {
                farRows.append("tick \(samples.count): row \(oldest) of \(binder.blocks.count)")
            }
            // Only the growing block's stack (its chunk, and the one before it) is laid out.
            if let oldest = RendererBodyCounters.laidOutChunks.keys.min(), oldest < (binder.blocks.count - 1) / chunk * chunk - chunk {
                farLayout.append("tick \(samples.count): row \(oldest) of \(binder.blocks.count) laid out (\(RendererBodyCounters.laidOutChunks.values.reduce(0, +)) rows; last block \(binder.blocks.last.map { String($0.source.prefix(16)) } ?? ""), before it \(binder.blocks.dropLast().last.map { String($0.source.prefix(16)) } ?? ""))")
            }
        }
        let n = samples.count
        #expect(n > 200)
        #expect(samples.contains { $0.rows > 0 }, "no row was re-evaluated: the measurement saw no update")
        #expect(samples.contains { $0.laidOut > 0 }, "no row was laid out: the measurement saw no layout")
        let early = samples[(n / 8)..<(n / 4)], late = samples[(n * 3 / 4)...]
        func mean(_ xs: some Collection<Double>) -> Double { xs.reduce(0, +) / Double(max(1, xs.count)) }
        func median(_ xs: some Collection<Double>) -> Double {
            let s = xs.sorted()
            return s.isEmpty ? 0 : s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
        let rowsEarly = mean(early.map { Double($0.rows) }), rowsLate = mean(late.map { Double($0.rows) })
        let laidEarly = mean(early.map { Double($0.laidOut) }), laidLate = mean(late.map { Double($0.laidOut) })
        let maxLaidOut = samples.map(\.laidOut).max() ?? 0
        let maxSegs = samples.map(\.segmentations).max() ?? 0, maxSplit = samples.map(\.segmentedBlocks).max() ?? 0
        let cpuEarly = median(early.map { $0.cpu }) * 1000, cpuLate = median(late.map { $0.cpu }) * 1000
        print(String(format: "RendererTickCost: %d ticks, blocks %d → %d; rows/tick %.2f → %.2f; rows laid out/tick %.2f → %.2f "
                     + "(max %d); segmentations/tick max %d, blocks re-split max %d; median cpu/tick %.2f → %.2f ms",
                     n, early.first?.blocks ?? 0, late.last?.blocks ?? 0, rowsEarly, rowsLate, laidEarly, laidLate,
                     maxLaidOut, maxSegs, maxSplit, cpuEarly, cpuLate))
        for (name, r) in [("early", (n / 8)..<(n / 4)), ("late", (n * 3 / 4)..<n)] {
            let xs = split[r]
            print(String(format: "RendererTickCost %@: tick %.2f, runloop update %.2f, test layout %.2f ms", name,
                         mean(xs.map { $0.tick }) * 1000, mean(xs.map { $0.update }) * 1000, mean(xs.map { $0.layout }) * 1000))
        }
        // The guard (exact, load-independent counters): a tick's work does not grow with the reply.
        // O(1) views per tick: only the live rows at the end of the reply (a tick and the clock's own tick may each
        // evaluate them, and several short blocks can be fading at once).
        #expect(farRows.isEmpty, "\(farRows.prefix(5))")
        #expect(rowsLate <= 6, "rows per tick late: \(rowsLate)")
        // O(1) layout per tick: a tick measures and places the rows of the growing chunk (and the one before it), not
        // the reply's earlier blocks; the flat selectable stack laid out every block on every tick. Now and then the
        // whole reply is laid out once (3 of ~700 ticks here), never on most ticks. 16 = two chunks of 8 (≈ 5 measured).
        #expect(laidLate <= 16, "rows laid out per tick late: \(laidLate)")
        // fix/t05-u5-part5: these sit at `$$` blocks and only re-place the earlier chunks (no re-measure:
        // `ticksAroundMathMeasureNoMoreThanTwoChunks`).
        print("RendererTickCost far layout: \(farLayout)")
        #expect(farLayout.count <= n / 50, "\(farLayout.count) of \(n) ticks laid out earlier chunks: \(farLayout.prefix(5))")
        // O(tail) segmentation per tick: one apply per tick (and one by the clock's own tick), re-splitting the
        // unstable tail's few blocks only (the stability rule: a blank line freezes a block), never the reply's.
        #expect(maxSegs <= 2, "segmentations in one tick: \(maxSegs)")
        #expect(maxSplit <= 6, "blocks re-split in one tick: \(maxSplit)")
        // Secondary, loose timing bound (medians of thread CPU over ~70 ticks each; the counters above are the guard):
        // the last quarter's ticks (≈ 4× the blocks) cost about what the early ones do.
        #expect(cpuLate <= max(3 * cpuEarly, cpuEarly + 6), "median cpu per tick grows with the reply: \(cpuEarly) → \(cpuLate) ms")
    }

    struct Row: Identifiable, Equatable { let id: Int }

    /// Per-tick CPU (ms) of a reply streaming in a TranscriptList that fills a window's content view with no fixed
    /// frame, as in the app: NSHostingView's default sizing options measure the content's minimum size on every
    /// layout pass (the probe's profile: NSHostingView.minSize → the transcript ScrollView measuring its content).
    func windowTickCost() async -> Double {
        _ = NSApplication.shared
        let binder = StreamingMarkdownBinder(text: "", streaming: true)
        let items = [Row(id: 0)]
        let host = NSHostingView(rootView: TranscriptList(items: items, startDate: nil) { _ in MessageMarkdownView(binder: binder) }
            .frame(minWidth: 600, minHeight: 400))
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 900, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        BackgroundRun.present(window)
        defer { window.contentView = nil; window.close() }
        // RENDERER_TICK_SECTIONS=<n>: a longer reply, with 3 s to attach a profiler first (Time Profiler / sample).
        let env = ProcessInfo.processInfo.environment["RENDERER_TICK_SECTIONS"].flatMap(Int.init)
        if env != nil { try? await Task.sleep(for: .seconds(3)) }
        let bytes = Array(LongReply.text(sections: env ?? 10).utf8)
        var end = 0
        var t = CACurrentMediaTime()
        var cpu: [Double] = []
        while end < bytes.count {
            end = min(bytes.count, end + 24)
            while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
            let c0 = Self.mainThreadCPU()
            binder.update(text: String(decoding: bytes[0..<end], as: UTF8.self), streaming: true, interrupted: false)
            t = max(t + 1.0 / 40, CACurrentMediaTime())
            binder.tick(now: t)
            try? await Task.sleep(for: .milliseconds(1))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            cpu.append(Self.mainThreadCPU() - c0)
        }
        let n = cpu.count
        let early = cpu[(n / 8)..<(n / 4)], late = cpu[(n * 3 / 4)...]
        let e = early.reduce(0, +) / Double(early.count) * 1000, l = late.reduce(0, +) / Double(late.count) * 1000
        // The settle after the stream ends (final segmentation, fade end, selection turned back on block by block).
        binder.update(text: String(decoding: bytes, as: UTF8.self), streaming: false, interrupted: false)
        var settle: [Double] = []
        var selectionRows: [Int] = []
        let finishedAt = t
        var earlySwitches = 0
        while binder.animating, settle.count < 2000 {
            RendererBodyCounters.reset()
            let switches = binder.selectionSwitches
            let c0 = Self.mainThreadCPU()
            t = max(t + 1.0 / 40, CACurrentMediaTime())
            binder.tick(now: t)
            try? await Task.sleep(for: .milliseconds(1))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            settle.append(Self.mainThreadCPU() - c0)
            if binder.selectionSwitches > switches {
                selectionRows.append(RendererBodyCounters.rows)
                if t - finishedAt < StreamingMarkdownBinder.selectionDelay { earlySwitches += 1 }
            }
        }
        print(String(format: "RendererTickCost window settle: %d ticks, max %.2f ms, total %.2f ms; rows per selection tick max %d",
                     settle.count, (settle.max() ?? 0) * 1000, settle.reduce(0, +) * 1000, selectionRows.max() ?? 0))
        // fix/u5-renderer-3: selection comes back one block per tick (a chunk of 8 at once rebuilt 8 rows: a 40–49 ms tick here
        // and a 100–400 ms pass at the end of each AT-008 reveal on the perf build).
        #expect(!binder.animating, "the reveal clock never stopped")
        // fix/u5-renderer-4: selection waits until the reply has been still for `selectionDelay`.
        #expect(earlySwitches == 0, "\(earlySwitches) blocks turned selectable right after the last word")
        #expect(selectionRows.count == binder.blocks.count, "\(selectionRows.count) selection ticks for \(binder.blocks.count) blocks")
        #expect((selectionRows.max() ?? 0) <= 2, "a selection tick re-evaluated \(selectionRows.max() ?? 0) block rows")
        print(String(format: "RendererTickCost window: early %.2f ms, late %.2f ms per tick (%d blocks)", e, l, binder.blocks.count))
        return l / max(e, 0.1)
    }

    @Test func aTickInAWindowDoesNotMeasureTheWholeReply() async throws {
        let growth = await windowTickCost()
        #expect(growth <= 1.8, "per-tick cost grows \(growth)x with the reply")
    }

    /// Mean main-thread CPU (ms) of a reveal tick while a reply streams below `finished` finished replies in the
    /// transcript (TranscriptList: the newest 60 rows are eager).
    func tickCost(finished: Int) async -> Double {
        let binder = StreamingMarkdownBinder(text: "", streaming: true)
        let old = LongReply.text(sections: 2)
        let items = (0...finished).map { Row(id: $0) }
        let h = RendererRig.Host(
            TranscriptList(items: items, startDate: nil) { row in
                if row.id < finished {
                    MessageMarkdownView(text: old, streaming: false)
                } else {
                    MessageMarkdownView(binder: binder)
                }
            }
            .frame(height: 700),
            look: .light)
        h.layout()
        await h.settle(min: 0.5, stableFor: 0.3, max: 6)
        let bytes = Array(LongReply.text(sections: 6).utf8)
        var end = 0
        var t = CACurrentMediaTime()
        var cpu: [Double] = []
        while end < bytes.count {
            end = min(bytes.count, end + 24)
            while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
            let c0 = Self.mainThreadCPU()
            binder.update(text: String(decoding: bytes[0..<end], as: UTF8.self), streaming: true, interrupted: false)
            t = max(t + 1.0 / 40, CACurrentMediaTime())
            binder.tick(now: t)
            try? await Task.sleep(for: .milliseconds(1))
            h.host.layoutSubtreeIfNeeded()
            h.host.displayIfNeeded()
            cpu.append(Self.mainThreadCPU() - c0)
        }
        let tail = cpu[(cpu.count / 2)...]
        return tail.reduce(0, +) / Double(max(1, tail.count)) * 1000
    }

    /// The finished rows of a long chat must not make each tick of the streaming reply dearer. Measured: with the
    /// newest 60 rows eager (a VStack), each tick re-placed and re-dirtied every view of every finished reply
    /// (fresh 3 ms, 60 finished replies 56–85 ms per tick); with the newest 8 eager and older rows lazy, 4.8 ms.
    /// Selection was not the cost here (finished rows without selection: same), nor a paused TimelineView per row,
    /// nor scroll anchoring.
    @Test func aTickInALongChatCostsAboutWhatItDoesInAFreshOne() async throws {
        let fresh = await tickCost(finished: 0)
        let made = RendererBodyCounters.binders
        let long = await tickCost(finished: 60)
        let realized = RendererBodyCounters.binders - made
        print(String(format: "RendererTickCost long chat: fresh %.2f ms, 60 finished replies %.2f ms per tick, %d replies realized",
                     fresh, long, realized))
        // Structural (load-independent): only the transcript's eager tail and the rows on screen are realized.
        let eager = 61 - TranscriptList<Row, EmptyView>.lazyCount(61)
        #expect(realized <= eager + 8, "\(realized) of 61 replies realized (\(eager) eager)")
        // Timing (generous: the full suite runs in parallel): 60 eager rows cost 56–85 ms per tick.
        #expect(long <= max(4 * fresh, fresh + 12), "fresh \(fresh) ms, long chat \(long) ms")
    }

    /// fix/t05-u5-part5: from the reply's end to the clock stopping, no pass lays out the reply's earlier blocks.
    /// `markdownIsStreaming` was one environment value over the reply; its flip at the end re-measured every block
    /// in one pass (mixed-3k in a transcript: 34 of 34 blocks laid out). Now each block has its own flag, and a pass
    /// lays out the growing / settling block's chunk (and the last one), at most two chunks of rows.
    @Test func theReplysEndLaysOutNoMoreThanTwoChunks() async throws {
        var text = ""
        for i in 0..<5 { text += LongReply.text(sections: 1) + "```python\nprint(\(i))\n```\n\n" }
        let binder = StreamingMarkdownBinder(text: "", streaming: true)
        // Deterministic: only this test's virtual clock ticks the binder (the view's real-time RevealClock beside it
        // mixed two time bases: a real-time apply left the virtual ticks behind `lastReveal`, so one run took 376 passes
        // and another measured two clocks' work in one window), and the final segmentation is applied inline.
        binder.externalClock = true
        binder.segmentsSynchronously = true
        let items = [Row(id: 0), Row(id: 1)]
        let h = RendererRig.Host(
            TranscriptList(items: items, startDate: nil) { r in
                if r.id == 0 { Text("A question").textSelection(.enabled) } else { MessageMarkdownView(binder: binder) }
            }.frame(height: 700),
            look: .light)
        h.layout()
        var t = LongReply.stream(text, into: binder)
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(10))
            h.host.layoutSubtreeIfNeeded()
            h.host.displayIfNeeded()
        }
        let chunk = StreamingMarkdownBinder.chunk
        #expect(binder.blocks.count > 3 * chunk, "the reply must span several chunks: \(binder.blocks.count) blocks")
        binder.update(text: text, streaming: false, interrupted: false)
        var worst = (rows: 0, chunks: [Int]())
        var worstMeasured = (rows: 0, chunks: [Int]())
        var passes = 0
        while binder.animating, passes < 600 {
            passes += 1
            RendererBodyCounters.reset()
            t += 1.0 / 40
            binder.tick(now: t)
            try? await Task.sleep(for: .milliseconds(2))
            h.host.layoutSubtreeIfNeeded()
            h.host.displayIfNeeded()
            let rows = RendererBodyCounters.laidOutChunks.values.reduce(0, +)
            if rows > worst.rows { worst = (rows, RendererBodyCounters.laidOutChunks.keys.sorted()) }
            let measured = RendererBodyCounters.measuredChunks.values.reduce(0, +)
            if measured > worstMeasured.rows { worstMeasured = (measured, RendererBodyCounters.measuredChunks.keys.sorted()) }
        }
        print("RendererTickCost reply end: \(passes) passes, most rows laid out in one \(worst.rows) (chunks \(worst.chunks)), "
              + "measured \(worstMeasured.rows) (chunks \(worstMeasured.chunks)) of \(binder.blocks.count)")
        #expect(!binder.animating)
        // The clock stops after the fade, `selectionDelay` and one tick per block: it never runs long.
        let bound = 4 + Int((StreamingMarkdownBinder.selectionDelay + 0.5) * 40) + binder.blocks.count
        #expect(passes <= bound, "the reveal clock ran \(passes) passes (bound \(bound))")
        #expect(worst.rows <= 2 * chunk, "a pass laid out \(worst.rows) rows (chunks \(worst.chunks)) of \(binder.blocks.count)")
    }

    /// fix/t05-u5-part5: math in a streaming reply measures its own chunk, not the reply. A pass where the probe also saw
    /// the earlier chunks (4 of ~700 ticks in `aTickReEvaluatesTheLiveBlocksOnly`, at `$$` blocks) only placed them
    /// again, with unchanged bounds: a `$$` block still fading in keeps its chunk changing while the next block starts
    /// the next chunk, so the reply's stack re-places its chunks; it measures (lays out text in) those two only. Bisected
    /// (fade off, no baseline guides, no ViewThatFits / horizontal ScrollView, no fixedSize / frame, math drawn as an image,
    /// a host tall enough not to scroll): all left the placements, none measured a third chunk. Typesetting is small too:
    /// ~6 fitting-size calls per formula over the whole reply.
    @Test func ticksAroundMathMeasureNoMoreThanTwoChunks() async throws {
        var text = ""
        for i in 0..<10 {
            text += "Paragraph \(i) with inline math $a_{\(i)} = \\frac{x}{y}$ in the middle of a sentence that wraps.\n\n"
            text += "$$\nx_{\(i)} = \\frac{a}{b} + \\sum_{k=1}^{n} k\n$$\n\n"
            text += "A plain paragraph after the formula, long enough to wrap across the reading column once or twice.\n\n"
        }
        let binder = StreamingMarkdownBinder(text: "", streaming: true)
        let items = [Row(id: 0), Row(id: 1)]
        let h = RendererRig.Host(
            TranscriptList(items: items, startDate: nil) { r in
                if r.id == 0 { Text("A question").textSelection(.enabled) } else { MessageMarkdownView(binder: binder) }
            }.frame(height: 700),
            look: .light)
        h.layout()
        let chunk = StreamingMarkdownBinder.chunk
        let bytes = Array(text.utf8)
        var end = 0
        var t = CACurrentMediaTime()
        var measuredWide: [String] = []
        var placedWide = 0, mathTicks = 0
        while end < bytes.count {
            end = min(bytes.count, end + 24)
            while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
            RendererBodyCounters.reset()
            binder.update(text: String(decoding: bytes[0..<end], as: UTF8.self), streaming: true, interrupted: false)
            t = max(t + 1.0 / 40, CACurrentMediaTime())
            binder.tick(now: t)
            try? await Task.sleep(for: .milliseconds(1))
            h.host.layoutSubtreeIfNeeded()
            h.host.displayIfNeeded()
            if binder.blocks.suffix(2).contains(where: { $0.source.contains("$") }) { mathTicks += 1 }
            if RendererBodyCounters.laidOutChunks.values.reduce(0, +) > 2 * chunk { placedWide += 1 }
            let measured = RendererBodyCounters.measuredChunks
            if measured.count > 2 {
                measuredWide.append("chunks \(measured.keys.sorted()) of \(binder.blocks.count) blocks")
            }
        }
        print("RendererTickCost math: \(mathTicks) ticks next to math; \(placedWide) re-placed more than two chunks; "
              + "\(measuredWide.count) measured more than two: \(measuredWide.prefix(4))")
        #expect(binder.blocks.count > 3 * chunk, "the reply must span several chunks: \(binder.blocks.count) blocks")
        #expect(mathTicks > 50, "the stream never sat next to math")
        #expect(measuredWide.isEmpty, "\(measuredWide.count) ticks measured more than two chunks: \(measuredWide.prefix(4))")
    }

    /// Streams `text` into a transcript row 12 bytes per tick and reports each tick's counters.
    private func streamHosted(_ text: String, each: (StreamingMarkdownBinder) -> Void) async {
        let binder = StreamingMarkdownBinder(text: "", streaming: true)
        let h = RendererRig.Host(
            TranscriptList(items: [Row(id: 0)], startDate: nil) { _ in MessageMarkdownView(binder: binder) }.frame(height: 700),
            look: .light)
        h.layout()
        let bytes = Array(text.utf8)
        var end = 0
        var t = CACurrentMediaTime()
        while end < bytes.count {
            end = min(bytes.count, end + 12)
            while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
            RendererBodyCounters.reset()
            binder.update(text: String(decoding: bytes[0..<end], as: UTF8.self), streaming: true, interrupted: false)
            t = max(t + 1.0 / 40, CACurrentMediaTime())
            binder.tick(now: t)
            try? await Task.sleep(for: .milliseconds(1))
            h.host.layoutSubtreeIfNeeded()
            h.host.displayIfNeeded()
            each(binder)
        }
    }

    /// fix/t05-u5-part6: a streaming table builds its new row only. The configuration's rows hold type-erased cells
    /// made by each parse, which never compare equal: every new row rebuilt the header and every row before it (the
    /// 12th row re-evaluated 13 rows). Rows are now kept while their Markdown line is unchanged.
    @Test func aStreamingTableRebuildsOnlyItsNewRow() async throws {
        var table = "| item | crates | price | revenue |\n|---|---:|---:|---:|\n"
        for i in 0..<12 { table += "| stall number \(i) | \(i * 3) | \(i).50 | \(i * 7).25 |\n" }
        let text = "Intro line.\n\n" + table + "\nAfter the table.\n"
        var perRow: [Int: Int] = [:]  // body rows shown → table rows re-evaluated in that tick
        await streamHosted(text) { binder in
            guard binder.blocks.count > 1, binder.blocks[1].source.contains("|---") else { return }
            let shown = binder.blocks[1].source.split(separator: "\n").count - 2
            perRow[shown, default: 0] += RendererBodyCounters.tableRows
        }
        print("RendererTickCost table: rows re-evaluated per shown row count \(perRow.sorted { $0.key < $1.key })")
        #expect(perRow.keys.contains(12), "the table never showed its 12 rows: \(perRow.keys.sorted())")
        // The header and the first row are built together; from then on each new row builds itself only.
        let wide = perRow.filter { $0.key >= 2 && $0.value > 1 }
        #expect(wide.isEmpty, "rows re-evaluated for one new row: \(wide.sorted { $0.key < $1.key })")
    }

    /// fix/t05-u5-part6: the live block is parsed once per change of its source (MarkdownView parses in its body; the
    /// block's view is equal, and not re-evaluated, while its source is). MarkdownView has no finer incremental parse:
    /// its own re-parses from the last root block, which is the live block.
    @Test func theLiveBlockIsParsedOncePerChange() async throws {
        let text = String(repeating: "The quiet harbour town wakes slowly while gulls argue over the catch. ", count: 14) + "\n"
        var ticks = 0, changes = 0, parses = 0, worst = 0
        var last = ""
        await streamHosted(text) { binder in
            ticks += 1
            let source = binder.blocks.last?.source ?? ""
            if source != last { changes += 1; last = source }
            parses += RendererBodyCounters.markdowns
            worst = max(worst, RendererBodyCounters.markdowns)
        }
        print("RendererTickCost parse: \(parses) parses for \(changes) source changes over \(ticks) ticks (max \(worst) per tick)")
        #expect(changes > 20)
        #expect(worst <= 1, "a tick parsed the live block \(worst) times")
        #expect(parses <= changes, "\(parses) parses for \(changes) changes")
    }

    /// fix/u5-renderer-4: the turn's end (the row's status leaves streaming, its live pull goes away) re-evaluates
    /// MessageMarkdownView. It must not re-apply the Markdown style: its element renderers cannot be compared, so a
    /// re-application re-parsed and redrew every block of the reply in one pass (U5 window test: 90 Text draws for a
    /// 4-section reply, 45 after; AT-008 on the perf build: 100–200 ms passes at each reply's end).
    @Test func theTurnEndDoesNotRestyleTheReply() async throws {
        let text = LongReply.text(sections: 4)
        let m = TurnEndModel()
        let h = RendererRig.Host(ScrollView { TurnEndRow(m: m, text: text) }.frame(height: 700), look: .light)
        h.layout()
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(30))
            h.host.layoutSubtreeIfNeeded()
            h.host.displayIfNeeded()
        }
        RendererBodyCounters.reset()
        WordFadeRenderer.drawCount = 0
        m.streaming = false
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(30))
            h.host.layoutSubtreeIfNeeded()
            h.host.displayIfNeeded()
        }
        let blocks = MarkdownSegmenterTests.sources(text).count
        print("RendererTickCost turn end: style applications \(RendererBodyCounters.styles), rows \(RendererBodyCounters.rowIDs), "
              + "text draws \(WordFadeRenderer.drawCount) (\(blocks) blocks)")
        #expect(RendererBodyCounters.styles == 0, "the turn end re-applied the Markdown style to the whole reply")
        #expect(RendererBodyCounters.rowIDs.allSatisfy { $0 >= blocks - 2 }, "rows re-evaluated: \(RendererBodyCounters.rowIDs)")
    }
}
}  // extension WindowSuites

@MainActor @Observable final class TurnEndModel { var streaming = true }

/// A streaming row as AssistantMessageView builds it: live pull while streaming, the final text once done.
private struct TurnEndRow: View {
    let m: TurnEndModel
    let text: String
    var body: some View {
        MessageMarkdownView(text: m.streaming ? "" : text, streaming: m.streaming, live: m.streaming ? { text } : nil)
            .equatable()
    }
}
