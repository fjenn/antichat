// Per-word fade-in of a streaming reply (IS-3: "newest words fade in, light grey → full colour"; M1.T09 step 2;
// token `motion.stream.wordFade` 180 ms, range 150–250). A SwiftUI `TextRenderer` is installed over the reply's
// MarkdownView, so it draws every `Text` inside (paragraphs, headings, list items, table cells, code). The renderer
// cannot see the string, only glyph geometry, so a `FadeLedger` remembers, per Text, when each character count was
// first drawn: a glyph whose index was first drawn `age` seconds ago draws at opacity `floor + (1 − floor)·age/fade`.
// Texts are told apart by the advance widths of their first glyphs (stable while a paragraph grows at its end).
// Drawing only: the renderer never changes layout, so fading cannot move text (NFR-U5 "0 jumps > 4 px").
// Reduce Motion (system or the R-101 override) → no renderer, words simply appear (token reduceMotion: none).
import AntiChatDesign
import os
import QuartzCore
import SwiftUI

/// When each part of each visible Text first appeared. One per streaming reply; main-thread only (TextRenderer
/// draws on the main thread), guarded by a lock anyway because `draw` is nonisolated.
final class FadeLedger: @unchecked Sendable {
    struct Entry {
        /// Ascending (character count, first-drawn time).
        var steps: [(count: Int, time: Double)] = []
        var lastSeen: Double = 0
    }

    let fade: Double
    private let lock = OSAllocatedUnfairLock()
    private var entries: [[Int32]: Entry] = [:]
    /// Probe counters (AT-008 "per-word fade active"). The fade's `now` is the clock's tick time, so these record
    /// real draw time and counts instead: on the S1 stand-in a main-thread pass is stretched ×4 after the draw, and
    /// "drawn mid-fade within 50 ms of `now`" (the old check) never held there (fade frames 0, fix/u5-renderer).
    /// `body…`: Texts longer than `bodyChars` characters — reply text, not the code / table header labels, which
    /// were the only fading draws the old counter saw.
    struct Counters: Sendable, Equatable {
        var draws = 0, fadingDraws = 0, bodyDraws = 0, bodyFadingDraws = 0
        /// Lines drawn whole and glyph slices drawn one by one (RendererTickCostTests: per-line drawing).
        var lineDraws = 0, sliceDraws = 0
        /// Media time (CACurrentMediaTime) of the last fading draw.
        var lastFadingAt: Double = -1
    }
    static let bodyChars = 40
    private var counters = Counters()
    var probeCounters: Counters { lock.withLock { counters } }
    var lastFadingAt: Double { probeCounters.lastFadingAt }

    init(fade: Double) { self.fade = fade }

    /// Character index → first-drawn time for the Text keyed `key`, after recording `count` at `now`.
    func times(key: [Int32], count: Int, now: Double) -> [(count: Int, time: Double)] {
        lock.withLock {
            var e = entries[key] ?? inherit(key, now: now)
            if count > (e.steps.last?.count ?? 0) { e.steps.append((count, now)) }
            // Times ascend, so the fully faded steps are a prefix: collapse it into one "old" step (time −1).
            let faded = e.steps.prefix { $0.time < 0 || now - $0.time >= fade }.count
            if faded > 0 { e.steps.replaceSubrange(0..<faded, with: [(e.steps[faded - 1].count, -1)]) }
            e.lastSeen = now
            entries[key] = e
            if entries.count > 512 { entries = entries.filter { now - $0.value.lastSeen < 2 } }
            return e.steps
        }
    }

    /// A Text first keyed with fewer than `keyGlyphs` glyphs is re-keyed as it grows: carry its history over.
    private func inherit(_ key: [Int32], now: Double) -> Entry {
        for n in stride(from: key.count - 1, through: 1, by: -1) {
            let prefix = Array(key.prefix(n))
            if let e = entries[prefix], now - e.lastSeen < 1 {
                entries[prefix] = nil
                return e
            }
        }
        return Entry()
    }

    func noteDraw(chars: Int, fading: Bool, lines: Int = 0, slices: Int = 0) {
        let t = fading ? CACurrentMediaTime() : 0
        lock.withLock {
            let body = chars > Self.bodyChars
            counters.draws += 1
            counters.lineDraws += lines
            counters.sliceDraws += slices
            if body { counters.bodyDraws += 1 }
            guard fading else { return }
            counters.fadingDraws += 1
            if body { counters.bodyFadingDraws += 1 }
            counters.lastFadingAt = t
        }
    }
}

struct WordFadeRenderer: TextRenderer {
    /// Seconds (CACurrentMediaTime) of this frame; changes every reveal tick, which redraws (not re-lays) the text.
    var now: Double
    let ledger: FadeLedger
    /// Opacity of a brand-new word ("light grey").
    var floor: Double = 0.2
    /// Off (Reduce Motion, or the reply finished fading): plain drawing. The renderer stays installed either way so
    /// toggling it never changes the view tree (which would reset MarkdownView's state).
    var enabled = true
    static let keyGlyphs = 8

    #if DEBUG
    /// Every draw of a reply Text, faded or not (tests: which Texts a pass redrew).
    nonisolated(unsafe) static var drawCount = 0
    #endif

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        #if DEBUG
        Self.drawCount += 1
        #endif
        guard enabled else {
            for line in layout { ctx.draw(line) }
            return
        }
        // fix/u5-renderer-2: per line, not per glyph. A Text drawn through a TextRenderer is rasterised on the CPU on
        // every redraw, and the old loop also built and drew every glyph slice of the Text separately (window-hosted
        // profile: 23 % of the main thread in this method). Only the lines that hold a fading glyph — normally the
        // last one or two — are drawn slice by slice; the others are drawn whole.
        var key: [Int32] = []
        key.reserveCapacity(Self.keyGlyphs)
        keyLoop: for line in layout {
            for run in line {
                for slice in run {
                    key.append(Int32((slice.typographicBounds.width * 8).rounded()))
                    if key.count == Self.keyGlyphs { break keyLoop }
                }
            }
        }
        // Character offsets relative to the Text's first glyph (CharacterIndex has no public integer value). Text
        // grows at its end, so the first glyph of the first line and the last glyph of the last line bound it.
        guard !key.isEmpty, let base = layout.first?.first?.first?.characterIndices.min(),
            let lastIndex = layout.last?.last?.last?.characterIndices.max()
        else {
            for line in layout { ctx.draw(line) }
            return
        }
        let count = base.distance(to: lastIndex) + 1
        let steps = ledger.times(key: key, count: count, now: now)
        // Glyphs below `opaque` (character offset) are fully drawn: the steps are ascending in count and time.
        var opaque = 0
        for step in steps {
            if step.time < 0 || now - step.time >= ledger.fade { opaque = step.count } else { break }
        }
        var fading = 0, wholeLines = 0, slices = 0
        for line in layout {
            let lineEnd = line.last?.last?.characterIndices.max().map { base.distance(to: $0) } ?? Int.max
            if lineEnd < opaque {
                ctx.draw(line)
                wholeLines += 1
                continue
            }
            for run in line {
                for slice in run {
                    slices += 1
                    let i = slice.characterIndices.min().map { base.distance(to: $0) } ?? 0
                    let born = steps.first(where: { $0.count > i })?.time ?? -1
                    let p = born < 0 ? 1 : min(1, max(0, (now - born) / ledger.fade))
                    if p >= 1 {
                        ctx.draw(slice)
                    } else {
                        fading += 1
                        var c = ctx
                        // Ease-out: most of the colour arrives early, the tail settles.
                        c.opacity = floor + (1 - floor) * (1 - (1 - p) * (1 - p))
                        c.draw(slice)
                    }
                }
            }
        }
        ledger.noteDraw(chars: count, fading: fading > 0, lines: wholeLines, slices: slices)
    }
}

/// Installs the word-fade renderer while `active`; `now` must advance on every reveal tick.
struct WordFadeModifier: ViewModifier {
    let active: Bool
    let now: Double
    let ledger: FadeLedger
    @EffectiveReduceMotion private var reduceMotion

    func body(content: Content) -> some View {
        content.textRenderer(WordFadeRenderer(now: now, ledger: ledger, enabled: active && !reduceMotion))
    }
}
