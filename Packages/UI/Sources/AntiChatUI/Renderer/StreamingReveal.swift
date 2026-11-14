// The steady reveal clock of IS-3 (M1.T09 step 2): tokens arrive unevenly (prefill bursts, decode jitter, thermal);
// the renderer shows them at a steady cadence instead. `StreamingReveal` is the pure, testable policy: it holds the
// text received so far (`target`) and how much of it is on screen (`shown`, UTF-8 bytes), and on each clock tick
// reveals whole words at a rate that drains the backlog in `catchUp` seconds, never slower than `minRate`.
// A word is revealed only once it is complete (followed by whitespace), except when the stream has finished.
import Foundation

public struct StreamingReveal: Sendable, Equatable {
    /// Text received so far (the message text).
    public private(set) var target = ""
    /// Revealed UTF-8 bytes of `target` (always at a word boundary or the end).
    public private(set) var shown = 0
    /// No more text will arrive (done, interrupted, error).
    public private(set) var finished = false
    /// Base characters per second while a backlog exists (≈ 30 tok/s); the backlog term adds to it.
    public var minRate: Double = 120
    /// Seconds to drain the backlog while streaming / after the stream finished.
    public var catchUp: Double = 0.20  // A-M1-T01a (b): was 0.30
    public var finishCatchUp: Double = 0.15
    private var budget: Double = 0

    public init() {}

    /// Starts with `text` already fully revealed (a finished message, or a reply loaded from the database).
    public init(revealed text: String, finished: Bool) {
        target = text
        shown = text.utf8.count
        self.finished = finished
    }

    public var shownText: String {
        var t = target
        let n = shown
        return t.withUTF8 { String(decoding: UnsafeBufferPointer(rebasing: $0[0..<n]), as: UTF8.self) }
    }
    /// The text of `target` in the UTF-8 byte range `range` (clamped). Callers cut at word or block boundaries,
    /// which never split a character. O(range), unlike `shownText` (fix/u5-renderer: per-tick work is bounded by
    /// the unstable tail, not the reply).
    public func text(bytes range: Range<Int>) -> String {
        var t = target
        return t.withUTF8 { b in
            let lo = min(max(0, range.lowerBound), b.count)
            let hi = min(max(lo, range.upperBound), b.count)
            return String(decoding: UnsafeBufferPointer(rebasing: b[lo..<hi]), as: UTF8.self)
        }
    }
    /// The UTF-8 byte of `target` at `offset` (received, not necessarily revealed), nil past its end. O(1).
    public func byte(at offset: Int) -> UInt8? {
        var t = target
        return t.withUTF8 { b in offset >= 0 && offset < b.count ? b[offset] : nil }
    }
    public var backlog: Int { target.utf8.count - shown }
    /// The reveal has caught up with a finished stream: nothing is left to animate.
    public var isComplete: Bool { finished && backlog == 0 }

    /// The message text changed. Appends keep the revealed prefix; any other change (a new version, an edit, the
    /// final text differing from the streamed one) restarts the reveal from the common prefix.
    public mutating func update(target new: String, finished: Bool) {
        // Contiguous byte compares (memcmp): the per-tick check runs on the whole reply (A-M1-T09b profile).
        var a = new, b = target
        let n = shown
        let kept = a.withUTF8 { x in
            b.withUTF8 { y in x.count >= n && (n == 0 || memcmp(x.baseAddress!, y.baseAddress!, n) == 0) }
        }
        if kept {
            target = new
        } else {
            let common = a.withUTF8 { x in b.withUTF8 { y in zip(x, y.prefix(n)).prefix { $0 == $1 }.count } }
            target = new
            shown = a.withUTF8 { Self.wordBoundary(atOrBefore: common, in: $0) }
            budget = 0
        }
        self.finished = finished
    }

    /// Shows everything now (Stop / interrupted: the screen must equal the persisted text, A-M1-T06a a).
    public mutating func revealAll() {
        shown = target.utf8.count
        budget = 0
    }

    /// Advances the clock by `dt` seconds. Returns the number of words revealed by this tick (0 = no change).
    @discardableResult
    public mutating func tick(_ dt: Double) -> Int {
        guard backlog > 0, dt > 0 else { budget = 0; return 0 }
        let window = finished ? finishCatchUp : catchUp
        let rate = minRate + Double(backlog) / window
        budget += rate * min(dt, 0.1)
        var t = target
        var words = 0
        let finished = finished
        var shown = shown, budget = budget
        let total = t.withUTF8 { bytes in
            while shown < bytes.count {
                guard let next = Self.nextWordEnd(after: shown, in: bytes, finished: finished) else { break }
                let cost = Double(next - shown)
                if cost > budget { break }
                budget -= cost
                shown = next
                words += 1
            }
            return bytes.count
        }
        self.shown = shown
        self.budget = shown >= total ? 0 : budget
        return words
    }

    // MARK: - Word boundaries (UTF-8; multi-byte scalars are never whitespace, so cuts never split a character)

    static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x09 || b == 0x0D }

    /// The end of the word after `i` (leading whitespace included), or nil when it is not complete yet.
    static func nextWordEnd<C: RandomAccessCollection<UInt8>>(after i: Int, in bytes: C, finished: Bool) -> Int?
    where C.Index == Int {
        var j = i
        while j < bytes.count, isSpace(bytes[j]) { j += 1 }
        while j < bytes.count, !isSpace(bytes[j]) { j += 1 }
        if j < bytes.count || finished { return j > i ? j : nil }
        return nil  // the last word may still grow
    }

    static func wordBoundary<C: RandomAccessCollection<UInt8>>(atOrBefore i: Int, in bytes: C) -> Int
    where C.Index == Int {
        var j = min(i, bytes.count)
        if j == bytes.count { return j }
        while j > 0, !isSpace(bytes[j - 1]) { j -= 1 }
        return j
    }
}
