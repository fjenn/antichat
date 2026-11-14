// The streaming Markdown renderer of an assistant reply (M1.T09 step 1; P-shell-04 MarkdownView 3.0.0).
// TurnController text deltas land in `ConversationModel.LiveReply`; the binder pulls them on the IS-3 reveal clock
// (`StreamingReveal`, a `TimelineView` independent of token arrival) and shows them as one MarkdownView per root
// block. Each apply emits the `rendererApply` signpost event with the words revealed (S-2 gate, NFR-U5).
//
// fix/u5-renderer (NFR-U5 on the S1 stand-in, M9.T05 AT-008: apply median 124.7 ms, 723 passes > 33 ms): the work
// of a reveal tick is bounded by the reply's last block, not by the reply.
// - Blocks are append-only (`RenderedBlock`, observable one by one). A block that can no longer change is frozen
//   (`MarkdownSegmenter`'s stability rule); each apply re-segments only the unstable tail, on the main thread (it is
//   one block, normally < 2 KB). Before, every apply went through StreamingMarkdownReader: an off-main parse of the
//   tail, then on main a re-slice of every block of the reply into new strings and a re-diff of the whole stack —
//   once for the clock tick (the fade's `now` was threaded through the whole stack) and once per parse commit.
// - The clock's time (`clock`) is read only by live blocks (still growing, or fading in). A clock tick therefore
//   re-evaluates the last one or two blocks; finished blocks keep their identity and are never touched again.
// - The streaming reply is not selectable until its reveal settles (`selectableBlocks`). Every selectable Text has
//   an AppKit selection overlay that SwiftUI re-updates on every layout pass, so per-tick cost grew with the reply
//   (RendererTickCostTests, measured: 3 → 10 ms per tick from 12 to 94 blocks; 3 → 6 ms without selection), and a
//   selectable Text ignores `textRenderer`, so the IS-3 word fade never drew on reply text (AT-008 counted only
//   the code / table header labels fading: 22–46 frames per run at S4, 0 at S1). After the reveal, chunks of
//   blocks turn selectable one per clock tick (fix/u5-renderer-3: one block, not a chunk of 8: a chunk's switch
//   rebuilt 8 MarkdownViews with their selection overlays in one pass, 40–49 ms per tick in RendererTickCostTests'
//   settle, a 100–400 ms main-thread pass at the end of every AT-008 reveal on the perf build). `-RendererLiveSelectable YES` keeps the old behaviour (A/B runs).
// - Blocks sit in fixed chunks (`ReplyBlocks`), so the growing block's height change re-lays out its chunk only.
// - Finished replies are segmented off the main thread (synchronously when short), as the reader did.
import AntiChatDesign
import AntiChatFoundation
import AppKit
import MarkdownView
import os
import QuartzCore
import SwiftUI

/// One root block of a reply. Observable on its own, so a change re-evaluates this block's view only.
@MainActor
@Observable
final class RenderedBlock: Identifiable {
    let id: Int
    /// The block's Markdown source.
    fileprivate(set) var source: String
    /// Still growing or fading in: draws with the word-fade renderer and follows the clock.
    fileprivate(set) var live: Bool
    /// Clock time the block last grew (its newest words start fading then).
    @ObservationIgnored fileprivate(set) var grewAt: Double
    /// fix/t05-u5-part5: whether this block's code / Mermaid / promoted card still shows the streaming form. The
    /// block's own flag (in its row's environment, `markdownStream`), so a reply's end re-evaluates the views that
    /// read it, block by block, and nothing else.
    let stream: MarkdownStreamFlag

    init(id: Int, source: String, live: Bool, grewAt: Double, streaming: Bool) {
        self.id = id
        self.source = source
        self.live = live
        self.grewAt = grewAt
        stream = MarkdownStreamFlag(streaming)
    }

    /// A fenced (or indented) code block: the only kind whose views read the stream flag (code highlighting,
    /// Mermaid, promoted artifact cards).
    var isCode: Bool { source.hasPrefix("```") || source.hasPrefix("~~~") || source.hasPrefix("    ") }
}

/// fix/t05-u5-part5 (NFR-U5): "the reply is still streaming" for one block's views. Before, `markdownIsStreaming` was
/// one environment value over the whole reply; its flip at the reply's end changed the environment of every block,
/// and every block of the reply was laid out in that pass (mixed-3k in a transcript: 34 of 34 blocks at the finish tick;
/// `RendererTickCostTests.theReplysEndLaysOutNoMoreThanTwoChunks`).
@MainActor
@Observable
final class MarkdownStreamFlag {
    fileprivate(set) var streaming: Bool
    init(_ streaming: Bool) { self.streaming = streaming }
}

extension EnvironmentValues {
    /// The enclosing block's stream flag (nil outside a streaming reply: not streaming).
    @Entry var markdownStream: MarkdownStreamFlag? = nil
    /// fix/t05-u5-part6: the enclosing reply block (its source keys a table's rows; nil outside a reply).
    @Entry var markdownBlock: RenderedBlock? = nil
}

@MainActor
@Observable
final class StreamingMarkdownBinder {
    /// Whether the reveal clock runs (false = paused TimelineView: no per-frame work for finished replies).
    private(set) var animating = false
    /// The reply's root blocks. The array changes only when a block is added or removed; a growing block changes
    /// its own `source`.
    private(set) var blocks: [RenderedBlock] = []
    /// The reveal clock's time of the latest tick. Only live blocks read it (their fade redraws on each tick).
    private(set) var clock: Double = 0
    /// The reveal has shown everything of a finished reply (then the blocks' stream flags settle: `settleStreamFlags`).
    private(set) var sourceFinished = false
    /// Leading blocks whose text is selectable. 0 while the reply streams: every selectable Text has an AppKit
    /// selection overlay that SwiftUI re-updates on every layout pass of the window, so a streaming reply of N
    /// blocks cost O(N) per reveal tick (RendererTickCostTests: 3 → 10 ms per tick from 12 to 94 blocks; 3 → 6 ms
    /// without selection), and a selectable Text ignores `textRenderer` (no word fade). Once the reveal has settled
    /// the blocks turn selectable one per clock tick, so no single pass rebuilds more than one block.
    private(set) var selectableBlocks = Int.max
    @ObservationIgnored private(set) var reveal: StreamingReveal
    @ObservationIgnored let ledger = FadeLedger(fade: MotionToken.streamWordFade.duration)
    @ObservationIgnored let context = MarkdownRenderContext()
    @ObservationIgnored private var lastTick: Double?
    /// Clock time of the last reveal; the fade keeps drawing until every word is opaque.
    @ObservationIgnored private var lastReveal: Double = 0
    /// Blocks `0..<stableCount` are final. The unstable tail starts at UTF-8 offset `stableBytes` of the reply.
    @ObservationIgnored private(set) var stableCount = 0
    @ObservationIgnored private var stableBytes = 0
    /// Revealed UTF-8 bytes the blocks show.
    @ObservationIgnored private(set) var appliedBytes = 0
    /// The first live block (live blocks are always a suffix: text only grows at the end).
    @ObservationIgnored private var firstLive = 0
    /// The reveal moved back over text the blocks already show (see `setTarget`).
    @ObservationIgnored private var rewound = false
    /// Bumped on every full segmentation, so an off-main result for an older text is dropped.
    @ObservationIgnored private var generation = 0
    /// Probe counters (in-process AT-008 evidence): applies, words, and apply timestamps.
    @ObservationIgnored private(set) var applies = 0
    @ObservationIgnored private(set) var revealedWords = 0
    @ObservationIgnored var onApply: ((Double, Int) -> Void)?
    /// Bytes of the tail re-segmented by the last apply (tests: the per-tick work is bounded by the tail).
    @ObservationIgnored private(set) var lastSegmentedBytes = 0
    /// Blocks the last apply re-segmented (the unstable tail's root blocks; tests: bounded, whatever the reply).
    @ObservationIgnored private(set) var lastSegmentedBlocks = 0
    /// Applies (re-segmentations) since the last read of `takeSegmentations()` (tests: per tick).
    @ObservationIgnored private var segmentations = 0
    @ObservationIgnored private(set) var ticks = 0
    /// Blocks turned selectable one by one after the reveal (tests).
    @ObservationIgnored private(set) var selectionSwitches = 0

    static let signposter = OSSignposter(subsystem: AppLog.subsystem, category: "ui")
    /// A finished reply up to this size is segmented on the main thread at once (no empty first frame); longer ones
    /// off the main thread.
    static let syncSegmentBytes = 4096
    /// `-RendererLiveSelectable YES`: the streaming reply stays selectable (and then draws without the fade, and
    /// pays every selectable Text's overlay update on every pass). A/B runs only.
    static let liveBlocksSelectable: Bool = {
        // A launch argument (not a setting): read the arguments, never the shared defaults domain.
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-RendererLiveSelectable"), i + 1 < args.count else { return false }
        return ["YES", "1", "true"].contains(args[i + 1])
    }()
    /// Seconds after the last revealed word before selection starts coming back (block by block).
    static let selectionDelay = 0.6
    /// Blocks per chunk (`ReplyBlocks`): the unit of layout isolation.
    static let chunk = 8

    init(text: String, streaming: Bool) {
        #if DEBUG
        RendererBodyCounters.binders += 1
        #endif
        if streaming {
            reveal = StreamingReveal()
            reveal.update(target: text, finished: false)
            animating = true
            if !Self.liveBlocksSelectable { selectableBlocks = 0 }
        } else {
            reveal = StreamingReveal(revealed: text, finished: true)
            sourceFinished = true
            appliedBytes = text.utf8.count
            context.source = text
            segmentFully(text)
        }
    }

    /// The message changed (new delta, final text, status change).
    func update(text: String, streaming: Bool, interrupted: Bool) {
        if sourceFinished {
            // A finished reply whose text changes: a new version streamed into the same row starts over; a changed
            // final text (AT-248 c1: citation verdicts settle the pills and may drop a marker) is re-segmented, and
            // only the blocks that differ redraw.
            guard text != reveal.target || streaming else { return }
            generation += 1
            if streaming {
                reveal = StreamingReveal()
                reveal.update(target: text, finished: false)
                resetBlocks()
                sourceFinished = false
                animating = true
                if !Self.liveBlocksSelectable { selectableBlocks = 0 }
                lastTick = nil
            } else {
                reveal = StreamingReveal(revealed: text, finished: true)
                appliedBytes = text.utf8.count
                context.source = text
                segmentFully(text)
            }
            return
        }
        setTarget(text, finished: !streaming)
        if interrupted { reveal.revealAll() }  // Stop: the screen shows exactly the persisted text (A-M1-T06a a)
        if !animating { animating = true }
        if interrupted { apply(words: 0, now: CACurrentMediaTime()) }
    }

    /// While streaming, the reply's latest text, pulled once per clock tick (instead of pushing every token
    /// delta through the view tree, which costs a SwiftUI update + layout pass per delta).
    @ObservationIgnored var live: (@MainActor () -> String)?

    /// Tests: the caller drives `tick` with its own clock (no RevealClock view ticks the binder in real time beside it),
    /// and the final segmentation runs inline, so a test's passes do not depend on when the off-main parse lands.
    @ObservationIgnored var externalClock = false
    @ObservationIgnored var segmentsSynchronously = false

    /// One reveal clock tick (TimelineView, 30–60 Hz).
    func tick(now: Double) {
        ticks += 1
        if let live, !sourceFinished, !reveal.finished {
            let t = live()
            // The live text only grows while streaming (ConversationModel.LiveReply): a length check suffices, and
            // avoids an O(reply) compare per tick (A-M1-T09b).
            if t.utf8.count != reveal.target.utf8.count { setTarget(t, finished: false) }
        }
        let dt = lastTick.map { now - $0 } ?? (1.0 / 60)
        lastTick = now
        let words = reveal.tick(dt)
        if words > 0 {
            apply(words: words, now: now)
        } else if reveal.isComplete, !sourceFinished {
            // fix/review U1: a final text shorter than the streamed one (e.g. a dropped citation marker) rewinds the
            // reveal to a point it has already shown, with nothing left to reveal: no tick ever applies. Clamp the
            // applied position to the reveal and finish: the full segmentation of the final text replaces the blocks
            // that changed and drops the removed ones (no re-fade of the words still there), and the clock can stop.
            if appliedBytes != reveal.shown {
                rewound = false
                appliedBytes = reveal.shown
            }
            finishSource()
        }
        retireFadedBlocks(now: now)
        if sourceFinished, streamingFlags > 0 { settleStreamFlags(one: true) }
        // Stop the clock once everything is revealed, finished and faded in.
        if sourceFinished, now - lastReveal > ledger.fade + 0.05 {
            for b in blocks[firstLive...] where b.live { b.live = false }
            firstLive = blocks.count
            if selectableBlocks < blocks.count {
                // One block per tick; the clock runs until the last one. fix/u5-renderer-4: not before the reply has
                // been still for `selectionDelay`: each switch builds a block's selection overlays, and right after
                // the last word those passes landed among the turn's own end work (AT-008: the cluster of 100–300 ms
                // passes at the end of every reply).
                if now - lastReveal > Self.selectionDelay {
                    selectableBlocks += 1
                    selectionSwitches += 1
                }
            } else if streamingFlags > 0 {
                // The clock runs until every code block has settled (one per tick).
            } else {
                if selectableBlocks != .max { selectableBlocks = .max }
                if animating { animating = false }
                lastTick = nil
            }
        } else if firstLive < blocks.count, clock - lastReveal <= ledger.fade, clock != now {
            // Only live blocks read it, and only while the last frame drawn may still hold a fading word (a slow
            // clock must still reach full opacity).
            clock = now
        }
    }

    /// The reveal's new target. A change that is not an append (a new version, an edit, a final text that differs
    /// from the streamed one) moves the reveal back; the blocks are rebuilt on the next apply.
    private func setTarget(_ text: String, finished: Bool) {
        reveal.update(target: text, finished: finished)
        if reveal.shown < appliedBytes { rewound = true }
    }

    private func apply(words: Int, now: Double) {
        let shown = reveal.shown
        guard shown != appliedBytes || rewound else { return }
        if rewound || shown < stableBytes {  // the text was replaced, not extended: rebuild the blocks
            rewound = false
            resetBlocks()
        }
        appliedBytes = shown
        segmentTail(now: now)
        lastReveal = now
        applies += 1
        revealedWords += words
        Self.signposter.emitEvent("rendererApply", "\(words, privacy: .public) words")
        onApply?(now, words)
        #if DEBUG || ANTICHAT_PERF_HARNESS
        MarkdownProbe.current?.noteCommit()
        #endif
        RendererCPUThrottle.shared.noteActive()
        // M1.T26a: main-thread frames > 33 ms while streaming (NFR-U5); inert unless the perf log is on.
        HitchCounter.shared.noteActive { target, selector in
            let app = NSApp as NSApplication?  // nil in a headless process (no application object)
            return (app?.keyWindow ?? app?.windows.first { $0.isVisible })?.contentView?.displayLink(target: target, selector: selector)
        }
    }

    /// Re-segmentations since the last call (tests: how many applies one tick ran).
    func takeSegmentations() -> Int {
        defer { segmentations = 0 }
        return segmentations
    }

    // MARK: - Blocks

    /// Re-segments the unstable tail (`stableBytes..<appliedBytes`): O(tail), whatever the reply's length.
    private func segmentTail(now: Double) {
        let tail = reveal.text(bytes: stableBytes..<appliedBytes)
        lastSegmentedBytes = tail.utf8.count
        let r = MarkdownSegmenter.split(tail)
        lastSegmentedBlocks = r.blocks.count
        segmentations += 1
        var added: [RenderedBlock] = []
        for (j, range) in r.blocks.enumerated() {
            let i = stableCount + j
            var source = MarkdownSegmenter.slice(tail, range)
            // The unstable last block: a table shows whole rows only, a fenced code block whole lines only
            // (MarkdownSegmenter.completeTableRows / completeCodeLines).
            if j == r.blocks.count - 1, j >= r.stable {
                // A block range excludes its trailing newline: look at the received text right after it. Not the
                // revealed text: the reveal holds a newline back as the leading whitespace of the next word, so a
                // row whose newline has arrived would stay hidden until more text came (fix/q60-table-stream: a
                // drained streaming table lacked its last row, RendererGoldenTests.tables 041–070).
                let ended = reveal.byte(at: stableBytes + range.upperBound) == 0x0A
                if let rows = MarkdownSegmenter.completeTableRows(source, lineEnded: ended) {
                    source = rows
                } else if let lines = MarkdownSegmenter.completeCodeLines(source, lineEnded: ended) {
                    source = lines
                }
            }
            if i < blocks.count {
                let b = blocks[i]
                if b.source != source {
                    b.source = source
                    b.grewAt = now
                }
                if !b.live { b.live = true }
            } else {
                added.append(RenderedBlock(id: i, source: source, live: true, grewAt: now, streaming: !sourceFinished))
            }
        }
        let count = stableCount + r.blocks.count
        if blocks.count > count { blocks.removeLast(blocks.count - count) }
        if !added.isEmpty { blocks.append(contentsOf: added) }
        firstLive = min(firstLive, stableCount)
        if r.stable > 0 {
            stableCount += r.stable
            stableBytes += r.blocks[r.stable].lowerBound
            context.source = reveal.text(bytes: 0..<stableBytes)  // Copy as CSV of a finished table (once per block)
        }
    }

    /// A stable block stops being live once its newest words have faded in: from then on it is selectable and no
    /// longer follows the clock.
    private func retireFadedBlocks(now: Double) {
        let settle = ledger.fade + 0.05
        while firstLive < stableCount, firstLive < blocks.count, now - blocks[firstLive].grewAt > settle {
            blocks[firstLive].live = false
            firstLive += 1
        }
    }

    /// Everything is revealed and the stream is over: the blocks are final. One full segmentation catches what an
    /// append-only split cannot see (MarkdownView's reader also re-parsed in full at the end); blocks that come out
    /// the same keep their views.
    private func finishSource() {
        sourceFinished = true
        let text = reveal.target
        context.source = text
        segmentFully(text)
        settleStreamFlags(one: false)
    }

    /// Blocks whose stream flag still says streaming (tests; the clock runs until 0).
    @ObservationIgnored private(set) var streamingFlags = 0

    /// fix/t05-u5-part5: after the reply's end, the blocks' stream flags turn off. Prose blocks at once (no view reads
    /// theirs); code blocks one per clock tick (`one`), so their full highlighting, Mermaid rendering and promoted
    /// cards land in separate passes, not all in the finishing pass.
    private func settleStreamFlags(one: Bool) {
        var flippedCode = false
        var left = 0
        for b in blocks where b.stream.streaming {
            if !b.isCode {
                b.stream.streaming = false
            } else if one, !flippedCode {
                b.stream.streaming = false
                flippedCode = true
            } else {
                left += 1
            }
        }
        streamingFlags = left
    }

    private func resetBlocks() {
        rewound = false
        if !blocks.isEmpty { blocks = [] }
        stableCount = 0
        stableBytes = 0
        appliedBytes = 0
        firstLive = 0
    }

    /// Segments a whole finished text (off the main thread unless it is short) and makes every block final.
    private func segmentFully(_ text: String) {
        generation += 1
        if text.utf8.count <= Self.syncSegmentBytes || segmentsSynchronously {
            setFinal(MarkdownSegmenter.split(text), of: text)
            return
        }
        let g = generation
        Task { [weak self] in
            let r = await Task.detached(priority: .userInitiated) { MarkdownSegmenter.split(text) }.value
            guard let self, self.generation == g else { return }
            self.setFinal(r, of: text)
        }
    }

    /// Replaces the blocks with a full segmentation of `text`, keeping the views of the blocks that did not change.
    /// Live blocks stay live (their fade ends on its own); new ones start final.
    private func setFinal(_ r: MarkdownSegmenter.Result, of text: String) {
        var added: [RenderedBlock] = []
        for (i, range) in r.blocks.enumerated() {
            let source = MarkdownSegmenter.slice(text, range)
            if i < blocks.count {
                if blocks[i].source != source { blocks[i].source = source }
            } else {
                added.append(RenderedBlock(id: i, source: source, live: false, grewAt: lastReveal, streaming: false))
            }
        }
        if blocks.count > r.blocks.count { blocks.removeLast(blocks.count - r.blocks.count) }
        if !added.isEmpty { blocks.append(contentsOf: added) }
        stableCount = blocks.count
        stableBytes = text.utf8.count
        firstLive = min(firstLive, blocks.count)
        if !animating {
            for b in blocks[firstLive...] where b.live { b.live = false }
            firstLive = blocks.count
        }
    }
}

/// The rendered body of an assistant reply: Markdown, code, tables, LaTeX math, Mermaid, with the IS-3 reveal.
public struct MessageMarkdownView: View, Equatable {
    let text: String
    let streaming: Bool
    let interrupted: Bool
    let live: (@MainActor () -> String)?
    /// The view's binder, made once (on the first body) and kept for the view's life. `State(initialValue:)` built a new
    /// binder (source + reveal + first parse) on every parent re-evaluation and threw it away (P0 follow-up, Q-015 r5);
    /// the box is a cheap allocation and the binder is made only when the box is empty.
    @State private var box = BinderBox()

    @MainActor final class BinderBox {
        var binder: StreamingMarkdownBinder?
    }

    private var binder: StreamingMarkdownBinder {
        if let b = box.binder { return b }
        let b = StreamingMarkdownBinder(text: text, streaming: streaming)
        box.binder = b
        return b
    }

    /// `streaming`: the reply is still arriving (pending/streaming); `interrupted`: Stop / failure ended it.
    /// `live`: optional pull of the reply's current text while streaming; with it the view is equal across token
    /// deltas (use `.equatable()`), and the binder reads new text on its own clock.
    public init(text: String, streaming: Bool, interrupted: Bool = false, live: (@MainActor () -> String)? = nil) {
        self.text = text
        self.streaming = streaming
        self.interrupted = interrupted
        self.live = live
    }

    nonisolated public static func == (a: Self, b: Self) -> Bool {
        a.streaming == b.streaming && a.interrupted == b.interrupted && (a.streaming && a.live != nil || a.text == b.text)
    }

    /// Tests drive the binder (and its reveal clock) directly.
    init(binder: StreamingMarkdownBinder) {
        text = binder.reveal.target
        streaming = !binder.reveal.finished
        interrupted = false
        live = nil
        let box = BinderBox()
        box.binder = binder
        _box = State(initialValue: box)
    }

    public var body: some View {
        let binder = self.binder
        // The reveal clock is a sibling that exists only while the reply animates: a finished reply has no
        // TimelineView, so it takes no part in the window's per-frame time update (a paused TimelineView in each
        // of 60 finished rows still did: RendererTickCostTests long chat). A tick re-evaluates just the blocks that
        // read `clock` (the live ones).
        // fix/u5-renderer-4: the Markdown style lives inside an Equatable child. Applied here, every re-evaluation of
        // this view (the reply's status change at turn end, the reveal finishing) re-created the style's element
        // renderers — values SwiftUI cannot compare — so every block of the reply re-parsed and redrew its text in one
        // pass (U5 window test: 90 Text draws for a 4-section reply; AT-008: the 100–200 ms passes at the end).
        StyledReply(binder: binder).equatable()
            .background {
                if binder.animating, !binder.externalClock { RevealClock(binder: binder) }
            }
        .environment(\.markdownRenderContext, binder.context)
        .coordinateSpace(.named(markdownSpace))
        .onChange(of: StreamKey(text: text, streaming: streaming, interrupted: interrupted)) { _, k in
            binder.update(text: k.text, streaming: k.streaming, interrupted: k.interrupted)
        }
        .onAppear {
            binder.live = live
            if let probe = MarkdownProbe.current { probe.attach(binder) }
        }
    }

    /// Reveal clock (`motion.stream.cadence` 30–60 Hz). 40 Hz (25 ms, IS-3's measured reference): at 30 Hz the
    /// apply interval sat exactly on NFR-U5's 33.3 ms bound, so any late frame failed the cadence leg. A tick now
    /// costs the last block only. 30 Hz in Low Power Mode (NFR-B2, `PowerPolicy.saverRenderHz`).
    static var cadence: Double {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 1.0 / Double(PowerPolicy.saverRenderHz) : 1.0 / 40
    }

    struct StreamKey: Equatable {
        var text: String
        var streaming: Bool
        var interrupted: Bool
    }
}

/// The reply's blocks with the Markdown style; equal (never re-evaluated) for the same binder, so the style's
/// environment is written once per reply, not on every re-evaluation of `MessageMarkdownView`.
private struct StyledReply: View, Equatable {
    let binder: StreamingMarkdownBinder

    nonisolated static func == (a: Self, b: Self) -> Bool { a.binder === b.binder }

    var body: some View {
        ReplyBlocks(binder: binder).markdownStyle()
    }
}

/// Drives `StreamingMarkdownBinder.tick` at `MessageMarkdownView.cadence` while the reply animates.
private struct RevealClock: View {
    let binder: StreamingMarkdownBinder

    var body: some View {
        TimelineView(RevealSchedule(interval: MessageMarkdownView.cadence, paused: false)) { timeline in
            Color.clear
                .onChange(of: timeline.date) { binder.tick(now: CACurrentMediaTime()) }
        }
        .accessibilityHidden(true)
    }
}

/// The reveal clock's schedule: one entry every `interval` while not paused (A-M1-T09b). Unlike
/// `.animation(minimumInterval:)`, which keeps the view graph updating at the display rate (120 Hz here: a time
/// update that dirties every time-dependent attribute in the window, each frame) and only throttles the date, a
/// periodic schedule wakes SwiftUI at the clock rate alone.
struct RevealSchedule: TimelineSchedule {
    let interval: Double
    let paused: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(upcoming: startDate, step: paused ? nil : interval)
    }

    struct Entries: Sequence, IteratorProtocol {
        var upcoming: Date?
        let step: Double?

        mutating func next() -> Date? {
            guard let d = upcoming else { return nil }
            upcoming = step.map { d.addingTimeInterval($0) }
            return d
        }
    }
}

/// One MarkdownView per root block (paragraph, list, table, code block, display math…). The list observes only the
/// block array (a block added or removed); each row observes its own block, and a live row also the clock.
/// Blocks are grouped in fixed chunks of `chunk` (block i is always in chunk i / chunk, so a block never changes
/// parent): when the growing block changes height only its chunk's stack and the short stack of chunks re-lay out.
/// One flat VStack re-ran its layout and display list over every block of the reply on every tick
/// (RendererTickCostTests: 3.7 → 10.4 ms per tick from 12 to 94 blocks).
private struct ReplyBlocks: View {
    let binder: StreamingMarkdownBinder
    static var chunk: Int { StreamingMarkdownBinder.chunk }

    var body: some View {
        #if DEBUG
        let _ = RendererBodyCounters.list()
        #endif
        let blocks = binder.blocks
        let chunks = (blocks.count + Self.chunk - 1) / Self.chunk
        let selectable = binder.selectableBlocks
        VStack(alignment: .leading, spacing: Spacing.space3) {
            ForEach(0..<chunks, id: \.self) { c in
                // How many of this chunk's blocks are selectable: only the chunk holding the block that switches
                // compares unequal (and is re-evaluated) on a selection tick.
                let lo = c * Self.chunk
                BlockChunk(blocks: Array(blocks[lo..<min(blocks.count, lo + Self.chunk)]), binder: binder,
                           selectable: min(Self.chunk, max(0, selectable - lo)))
                    .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A fixed run of blocks; equal (not re-evaluated) while it holds the same block objects.
private struct BlockChunk: View, Equatable {
    let blocks: [RenderedBlock]
    let binder: StreamingMarkdownBinder
    /// The leading `selectable` blocks of this chunk are selectable.
    let selectable: Int

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.binder === b.binder && a.selectable == b.selectable && a.blocks.count == b.blocks.count
            && zip(a.blocks, b.blocks).allSatisfy { $0 === $1 }
    }

    var body: some View {
        let stack = VStack(alignment: .leading, spacing: Spacing.space3) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { i, block in
                // Switching rebuilds this block's views once (a different selectability is a different view type).
                if i < selectable {
                    BlockRow(block: block, binder: binder)
                } else {
                    BlockRow(block: block, binder: binder).textSelection(.disabled)
                }
            }
        }
        // Merge (main's RendererLayoutProbe, Debug only) × fix/u5-renderer-3 (per-block selectability in the stack).
        #if DEBUG
        RendererLayoutProbe(firstRow: blocks.first?.id ?? 0, rows: blocks.count) { stack }
        #else
        stack
        #endif
    }
}

private struct BlockRow: View {
    let block: RenderedBlock
    let binder: StreamingMarkdownBinder

    var body: some View {
        #if DEBUG
        let _ = RendererBodyCounters.row(block.id)
        #endif
        let live = block.live
        MarkdownBlock(source: block.source).equatable()
            // VQ-M10 S-08: a reply that opens with a heading starts at the top of its row, as in the reference; the
            // heading's own top margin (MarkdownView: 24 pt for #–###, 10 pt below) separates sections, not turns.
            .padding(.top, block.id == 0 ? -MarkdownBlock.leadingHeadingMargin(block.source) : 0)
            .modifier(WordFadeModifier(active: live, now: live ? binder.clock : 0, ledger: binder.ledger))
            .environment(\.markdownStream, block.stream)  // fix/t05-u5-part5: per block, a stable reference
            .environment(\.markdownBlock, block)  // fix/t05-u5-part6: the table rows' keys (a stable reference)
    }
}

struct MarkdownBlock: View, Equatable {
    let source: String

    /// The top margin MarkdownView 3.0.0 gives a block that is an ATX heading (`HeadingPaddings`); 0 otherwise.
    static func leadingHeadingMargin(_ source: String) -> CGFloat {
        let line = source.drop { $0 == " " }
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return 0 }
        return hashes <= 3 ? 24 : 10
    }
    var body: some View {
        #if DEBUG
        let _ = RendererBodyCounters.markdown()
        #endif
        MarkdownView(source)
    }
}

#if DEBUG
/// View bodies evaluated by the renderer (RendererTickCostTests: a reveal tick re-evaluates the live blocks only,
/// however long the reply).
@MainActor
enum RendererBodyCounters {
    static var lists = 0, rows = 0, markdowns = 0
    /// Markdown style applications (`markdownStyle()` bodies): once per reply, not per re-evaluation of the row.
    static var styles = 0
    /// Binders made (one per realized MessageMarkdownView); not reset by `reset()`.
    static var binders = 0
    /// The ids of the rows evaluated since the last reset.
    static var rowIDs: [Int] = []
    static func list() { lists += 1 }
    static func row(_ id: Int) { rows += 1; rowIDs.append(id) }
    static func markdown() { markdowns += 1 }
    /// Block stacks (chunks) laid out since the last reset: first row id → the rows in that stack. A stack that is
    /// measured or placed lays out all of its rows, so the sum is the rows a layout pass walked.
    static var laidOutChunks: [Int: Int] = [:]
    /// fix/t05-u5-part5: the stacks measured (`sizeThatFits`, where text is laid out) since the last reset. Placing a stack
    /// with unchanged bounds (counted in `laidOutChunks`) does not lay out its text again.
    static var measuredChunks: [Int: Int] = [:]
    /// fix/t05-u5-part6: table rows (and headers) re-evaluated (`TableRowView`).
    static var tableRows = 0
    static func reset() {
        lists = 0; rows = 0; markdowns = 0; styles = 0; rowIDs = []
        laidOutChunks = [:]
        measuredChunks = [:]
        tableRows = 0
    }
}

/// A pass-through layout around each block stack (Debug only) that counts the layout passes over it: a tick must lay
/// out the growing block's stack (one chunk), not one stack of every block of the reply (RendererTickCostTests: the
/// flat stack re-laid out all its rows whenever the last one grew). One child, proposed and placed exactly as its
/// parent proposes and places this view.
struct RendererLayoutProbe: SwiftUI.Layout {
    let firstRow: Int
    let rows: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        note()
        let r = subviews.first?.sizeThatFits(proposal) ?? .zero
        let (first, n) = (firstRow, rows)
        MainActor.assumeIsolated { RendererBodyCounters.measuredChunks[first] = n }
        return r
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        note()
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }

    private func note() {
        MainActor.assumeIsolated {
            RendererBodyCounters.laidOutChunks[firstRow] = rows
        }
    }
}
#endif

extension View {
    /// The AntiChat Markdown look (tokens.md type + colours; code, table, math styles), scaled by `chatTextScale`.
    func markdownStyle() -> some View { modifier(MarkdownStyleModifier()) }
}

/// Renders a remote Markdown image as its alt text (or the host) without any network request.
struct NoFetchImageRenderer: MarkdownImageRenderer {
    func makeBody(configuration: MarkdownImageRendererConfiguration) -> some View {
        Label(configuration.alternativeText ?? configuration.url.host ?? "", systemImage: "photo")
            .foregroundStyle(Color.textTertiary)
    }
}

/// M4.T16 (Release run at T4): after create_image the resident model sometimes "embeds" the picture it just made as
/// `![Lighthouse at dusk](image:<image_id>)`. The picture is already in its card above the text, so a reference to
/// a picture / video by id renders nothing (it showed as a stray "photo" + alt-text line).
struct OmittedMediaReferenceRenderer: MarkdownImageRenderer {
    static let schemes = ["image", "video"]
    func makeBody(configuration: MarkdownImageRendererConfiguration) -> some View { EmptyView() }
}

private struct MarkdownStyleModifier: ViewModifier {
    @Environment(\.chatTextScale) private var scale
    @Environment(\.chatFont) private var chatFont  // M1.T23

    func body(content: Content) -> some View {
        #if DEBUG
        let _ = RendererBodyCounters.styles += 1
        #endif
        return content
            .markdownCodeBlockStyle(AntiChatCodeBlockStyle())
            .markdownTableStyle(AntiChatTableStyle())
            .markdownMathRenderingEnabled()
            // M2.T02 (R-297, InjectionCoverageTests): MarkdownView's default http(s) image renderer fetches with
            // URLSession.shared, outside the gate. Remote images in a reply are never fetched; the alt text shows.
            .markdownElementRenderer(.image(NoFetchImageRenderer(), urlScheme: "http"))
            .markdownElementRenderer(.image(NoFetchImageRenderer(), urlScheme: "https"))
            .markdownElementRenderer(.image(OmittedMediaReferenceRenderer(), urlScheme: OmittedMediaReferenceRenderer.schemes[0]))
            .markdownElementRenderer(.image(OmittedMediaReferenceRenderer(), urlScheme: OmittedMediaReferenceRenderer.schemes[1]))
            .markdownElementRenderer(.link(CitationPillRenderer(), urlScheme: CitationPill.scheme))  // M7.T03 pills
            .markdownElementRenderer(.link(PageCitePillRenderer(), urlScheme: PageCitePill.scheme))  // round 65 page pills
            .markdownComponentSpacing(Spacing.space3)
            .markdownLinksUnderlined()
            .font(chatFont.nsFont(for: .body, scale: scale), for: .body)
            .font(chatFont.nsFont(for: .markdownH1, scale: scale), for: .h1)
            .font(chatFont.nsFont(for: .markdownH2, scale: scale), for: .h2)
            .font(chatFont.nsFont(for: .markdownH3, scale: scale), for: .h3)
            .font(chatFont.nsFont(for: .headline, scale: scale), for: .h4)
            .font(chatFont.nsFont(for: .bodyEmph, scale: scale), for: .tableHeader)
            .font(chatFont.nsFont(for: .body, scale: scale), for: .tableBody)
            .font(chatFont.nsFont(for: .code, scale: scale), for: .codeBlock)
            .font(chatFont.nsFont(for: .body, scale: scale), for: .blockQuote)
            .lineSpacing(TypeToken.body.lineSpacing(scale: scale))
            .foregroundStyle(Color.textPrimary)
            .tint(Color.textPrimary, for: .inlineCodeBlock)
            .tint(Color.textTertiary, for: .blockQuote)
            .tint(Color.accentColor, for: .link)
            .textSelection(.enabled)
    }
}
