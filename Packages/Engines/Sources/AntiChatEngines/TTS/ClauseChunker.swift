// M3.T07 step 2 (R-282 AC1 first clause ≥ 4 words; R-054 AC2 streaming starts on the first sentence): the streaming
// chunker between the reply's token feed and the synthesiser. The first chunk goes out at the first clause boundary
// (`,` `;` `:` `—` followed by a space) once it holds ≥ 4 words, or at the first sentence end, or after 5 words
// (NFR-V1, A-M3-T09b/T09c), whichever comes first; every later chunk is one sentence (`.` `!` `?` `…` and the CJK enders, then a space or a line break; a
// line break alone ends a list item / heading too), capped at 240 characters like osaurus `TTSTextChunker` (a longer
// sentence splits at its last clause boundary or space before the cap). Feeding token by token yields exactly the
// chunks of feeding the whole text at once (`ClauseChunkerTests`), so read aloud of a finished reply and speech
// during generation agree. Text goes through `SpeakableText` before it reaches the chunker.
import Foundation

public struct ClauseChunker: Sendable {
    public static let maxChars = 240
    public static let minFirstWords = 4
    public static let maxFirstWords = 5
    static let clauseMarks: Set<Character> = [",", ";", ":", "—", "，", "；", "："]
    static let sentenceMarks: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]

    private var buffer = ""
    private var emittedFirst = false
    /// Characters of the speakable text consumed by earlier chunks (for ChunkTable ranges).
    public private(set) var consumed = 0

    public init() {}

    /// Appends `text` (a token or more) and returns the chunks it completed.
    public mutating func feed(_ text: String) -> [String] {
        buffer += text
        return drain(final: false).map(\.text)
    }

    /// The end of the reply: whatever is left is the last chunk(s).
    public mutating func finish() -> [String] { drain(final: true).map(\.text) }

    /// M3.T10: the same chunks with the Character range each one covers in everything fed so far (trimmed of
    /// surrounding whitespace), so a spoken position maps back to the source text.
    public struct Ranged: Sendable, Equatable {
        public var text: String
        public var range: Range<Int>
    }

    public mutating func feedRanged(_ text: String) -> [Ranged] {
        buffer += text
        return drain(final: false)
    }

    public mutating func finishRanged() -> [Ranged] { drain(final: true) }

    /// Batch form (read aloud of a finished reply).
    public static func chunks(_ text: String) -> [String] {
        var c = ClauseChunker()
        return c.feed(text) + c.finish()
    }

    private mutating func drain(final: Bool) -> [Ranged] {
        var out: [Ranged] = []
        while let cut = nextCut(final: final) {
            let head = String(buffer[..<cut])
            let base = consumed
            consumed += head.count
            buffer = String(buffer[cut...])
            if let r = Self.trimmed(head, base: base) {
                out.append(r)
                emittedFirst = true
            }
        }
        if final {
            let base = consumed
            let rest = buffer
            consumed += buffer.count
            buffer = ""
            if let r = Self.trimmed(rest, base: base) {
                out.append(contentsOf: Self.split(r.text).reduce(into: [Ranged]()) { acc, piece in
                    let from = acc.last?.range.upperBound ?? r.range.lowerBound
                    let sub = Array(r.text)
                    let local = from - r.range.lowerBound
                    let at = Self.find(Array(piece), in: sub, from: local) ?? local
                    acc.append(Ranged(text: piece, range: (r.range.lowerBound + at)..<(r.range.lowerBound + at + piece.count)))
                })
                emittedFirst = true
            }
        }
        return out
    }

    private static func trimmed(_ head: String, base: Int) -> Ranged? {
        let chars = Array(head)
        guard let a = chars.firstIndex(where: { !$0.isWhitespace && !$0.isNewline }),
              let b = chars.lastIndex(where: { !$0.isWhitespace && !$0.isNewline }) else { return nil }
        return Ranged(text: String(chars[a...b]), range: (base + a)..<(base + b + 1))
    }

    private static func find(_ needle: [Character], in hay: [Character], from: Int) -> Int? {
        guard !needle.isEmpty, needle.count <= hay.count else { return nil }
        var i = max(0, from)
        while i + needle.count <= hay.count {
            if Array(hay[i..<i + needle.count]) == needle { return i }
            i += 1
        }
        return nil
    }

    /// Where the next chunk ends in `buffer` (exclusive), or nil while it is still open.
    private func nextCut(final: Bool) -> String.Index? {
        let chars = Array(buffer)
        var words = 0, inWord = false
        var lastSoft: Int?  // last clause boundary / space before the cap (for an over-long sentence)
        for (i, c) in chars.enumerated() {
            if c.isWhitespace { inWord = false } else if !inWord { inWord = true; words += 1 }
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            // A boundary needs its follower to be sure it is one ("3.5", "e.g" mid-stream); at the end, `final` decides.
            let followed = next.map { $0.isWhitespace } ?? false
            if c == "\n", i > 0 { return buffer.index(buffer.startIndex, offsetBy: i + 1) }
            if Self.sentenceMarks.contains(c), followed || Self.isCJK(c) { return buffer.index(buffer.startIndex, offsetBy: i + 1) }
            if Self.clauseMarks.contains(c), followed || Self.isCJK(c) {
                if !emittedFirst, words >= Self.minFirstWords { return buffer.index(buffer.startIndex, offsetBy: i + 1) }
                lastSoft = i + 1
            } else if c == " " {
                // NFR-V1: the first chunk never waits past `maxFirstWords` words for a clause mark (voice starts sooner,
                // and the synthesiser gets a short first input); it still holds ≥ `minFirstWords` (R-282 AC1).
                if !emittedFirst, words >= Self.maxFirstWords { return buffer.index(buffer.startIndex, offsetBy: i) }
                lastSoft = lastSoft.map { max($0, i) } ?? i
            }
            if i + 1 >= Self.maxChars {
                let at = (lastSoft ?? Self.maxChars)
                return buffer.index(buffer.startIndex, offsetBy: max(1, at))
            }
        }
        _ = final
        return nil
    }

    static func isCJK(_ c: Character) -> Bool { "。！？，；：".contains(c) }

    /// A finished remainder over the cap, split like `nextCut` would.
    static func split(_ s: String) -> [String] {
        guard s.count > maxChars else { return [s] }
        var c = ClauseChunker()
        c.emittedFirst = true
        var out = c.feed(s)
        let rest = c.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { out.append(rest) }
        return out
    }
}

/// M3.T07 step 2: one row per spoken chunk — the table M3.T10 truncates the stored reply with (R-282 AC2).
public struct ChunkTable: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var chunkIndex: Int
        /// UTF-16 offsets in the stored assistant text (Markdown) that this chunk speaks.
        public var textRange: Range<Int>
        public var sampleCount: Int
        /// Sample offset of each word's start within the chunk's audio.
        public var wordOffsets: [Int]
    }

    public private(set) var entries: [Entry] = []
    private var cursor = 0
    public let source: String
    private let utf16: [UInt16]

    public init(source: String) {
        self.source = source
        utf16 = Array(source.utf16)
    }

    /// Records chunk `index` with its synthesised `samples`; `wordStarts` (sample offsets) when the synthesiser gave
    /// word timing, else estimated by each word's share of the chunk's characters.
    public mutating func append(index: Int, text: String, samples: Int, wordStarts: [Int]? = nil) {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let range = locate(words)
        let offsets = wordStarts ?? Self.estimate(words: words, samples: samples)
        entries.append(Entry(chunkIndex: index, textRange: range, sampleCount: samples, wordOffsets: offsets))
    }

    /// The stored-text offset spoken up to `playedSamples` of chunk `index` (the word in progress counts as spoken).
    public func spokenOffset(chunk index: Int, playedSamples: Int) -> Int? {
        guard let e = entries.first(where: { $0.chunkIndex == index }) else { return nil }
        guard playedSamples < e.sampleCount else { return e.textRange.upperBound }
        let done = e.wordOffsets.filter { $0 <= playedSamples }.count
        let share = Double(done) / Double(max(1, e.wordOffsets.count))
        return e.textRange.lowerBound + Int((Double(e.textRange.count) * share).rounded())
    }

    static func estimate(words: [String], samples: Int) -> [Int] {
        let total = max(1, words.reduce(0) { $0 + $1.count + 1 })
        var acc = 0
        return words.map { w in
            defer { acc += w.count + 1 }
            return Int(Double(samples) * Double(acc) / Double(total))
        }
    }

    /// The source span from the chunk's first word to its last, searched forward from the previous chunk; a chunk whose
    /// words are not in the source ("code omitted") spans the skipped source up to the next match (or nothing).
    private mutating func locate(_ words: [String]) -> Range<Int> {
        let start = cursor
        guard let first = words.first, let a = find(first, from: cursor) else { return start..<start }
        var end = a.upperBound
        var found = 1
        for w in words.dropFirst() {
            if let r = find(w, from: end) { end = r.upperBound; found += 1 }
        }
        // Mostly absent words ("code omitted" over a fence that happens to contain "code") are not this chunk's source.
        guard Double(found) / Double(words.count) > 0.6 else { return start..<start }
        cursor = end
        return a.lowerBound..<end
    }

    private func find(_ word: String, from: Int) -> Range<Int>? {
        let core = word.trimmingCharacters(in: .punctuationCharacters)
        guard !core.isEmpty else { return nil }
        let needle = Array(core.utf16)
        guard needle.count <= utf16.count - from, from >= 0 else { return nil }
        var i = from
        while i + needle.count <= utf16.count {
            if utf16[i] == needle[0], Array(utf16[i..<i + needle.count]) == needle { return i..<i + needle.count }
            i += 1
        }
        return nil
    }
}
