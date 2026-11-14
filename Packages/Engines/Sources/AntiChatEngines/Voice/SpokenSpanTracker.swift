// M3.T10 steps 2, 4, 5 (R-282 AC1–AC3; P-media-03 "Residual custom": played time fused with the chunk table).
// `VoiceReplyText` turns the streamed assistant reply (raw Markdown deltas, in order) into spoken chunks: the clause
// chunker cuts the raw text (first clause ≥ 4 words, then sentences, a line break ends a line), each chunk goes
// through `SpeakableText` (Markdown never spoken), fenced code becomes one "code omitted" sentence and table rows are
// skipped. Every spoken chunk keeps the UTF-16 range of the raw reply it speaks.
// `SpokenSpanTracker` maps the played sample count (the output clock at the stop) through those ranges to the offset in
// the stored reply that was actually heard — the word in progress counts as spoken, rounded to that word's end — so a
// barge-in stores exactly the spoken span (± 1 word).
import Foundation

public struct SpokenChunk: Sendable, Equatable {
    public var index: Int
    /// What the synthesiser speaks.
    public var text: String
    /// UTF-16 range of the raw reply this chunk speaks (empty for "code omitted": it stands for the fence).
    public var source: Range<Int>
}

public struct VoiceReplyText: Sendable {
    private var chunker = ClauseChunker()
    private var raw: [Character] = []
    private var utf16Prefix: [Int] = [0]  // utf16Prefix[i] = UTF-16 length of raw[..<i]
    private var inFence = false
    private var next = 0
    public let codeOmitted: String

    public init(codeOmitted: String = SpeakableText.defaultCodeOmitted) {
        self.codeOmitted = codeOmitted.hasSuffix(".") ? codeOmitted : codeOmitted + "."
    }

    /// The reply so far (what the app persists for this turn).
    public var text: String { String(raw) }

    public mutating func feed(_ delta: String) -> [SpokenChunk] {
        append(delta)
        return speakable(chunker.feedRanged(delta))
    }

    public mutating func finish() -> [SpokenChunk] { speakable(chunker.finishRanged()) }

    private mutating func append(_ delta: String) {
        for c in delta {
            raw.append(c)
            utf16Prefix.append(utf16Prefix[utf16Prefix.count - 1] + c.utf16.count)
        }
    }

    private func utf16(_ r: Range<Int>) -> Range<Int> {
        utf16Prefix[min(r.lowerBound, raw.count)]..<utf16Prefix[min(r.upperBound, raw.count)]
    }

    private mutating func speakable(_ pieces: [ClauseChunker.Ranged]) -> [SpokenChunk] {
        var out: [SpokenChunk] = []
        for piece in pieces {
            let line = piece.text.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if !inFence {
                    let at = utf16(piece.range).lowerBound
                    out.append(SpokenChunk(index: next, text: codeOmitted, source: at..<at))
                    next += 1
                }
                inFence.toggle()
                continue
            }
            if inFence || line.hasPrefix("|") { continue }
            if line.allSatisfy({ "-:| ".contains($0) }) { continue }  // table separator / thematic break
            let spoken = SpeakableText.from(markdown: piece.text, codeOmitted: codeOmitted)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard spoken.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            out.append(SpokenChunk(index: next, text: spoken, source: utf16(piece.range)))
            next += 1
        }
        return out
    }
}

public struct SpokenSpanTracker: Sendable {
    public struct Entry: Sendable, Equatable {
        public var chunk: SpokenChunk
        /// Sample offset of the chunk's first sample in the turn's output.
        public var startSample: Int
        public var sampleCount: Int
        /// Word starts inside the chunk (samples) from the synthesiser; nil = estimated by character share.
        public var wordStarts: [Int]? = nil
    }

    public private(set) var entries: [Entry] = []
    private var scheduled = 0
    /// UTF-16 view of the raw reply, for snapping to a word end.
    private var source: [UInt16] = []

    public init() {}

    /// Chunk `chunk` was handed to the output with `samples` samples, right after the previous one.
    public mutating func scheduled(_ chunk: SpokenChunk, samples: Int, wordStarts: [Int]? = nil) {
        entries.append(Entry(chunk: chunk, startSample: scheduled, sampleCount: samples, wordStarts: wordStarts))
        scheduled += samples
    }

    public mutating func updateSource(_ text: String) { source = Array(text.utf16) }

    /// The UTF-16 offset of the raw reply heard after `played` samples (0 = nothing heard).
    public func spokenOffset(playedSamples played: Int) -> Int {
        var offset = 0
        for e in entries {
            if played >= e.startSample + e.sampleCount {
                offset = max(offset, e.chunk.source.upperBound)
                continue
            }
            if played <= e.startSample { break }
            offset = max(offset, partial(e, played: played - e.startSample))
            break
        }
        return min(offset, source.isEmpty ? offset : source.count)
    }

    /// Inside chunk `e`: the spoken words whose audio has started (the word in progress counts as heard) — word starts
    /// from Kokoro's predicted token durations, else by character share (A-M3-T07a (b)) — mapped onto the same share
    /// of the source words, snapped to a word end.
    private func partial(_ e: Entry, played: Int) -> Int {
        let words = e.chunk.text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, !e.chunk.source.isEmpty else { return e.chunk.source.lowerBound }
        let starts = e.wordStarts ?? ChunkTable.estimate(words: words.map(String.init), samples: e.sampleCount)
        let heard = starts.filter { $0 < played }.count
        let srcWords = wordEnds(in: e.chunk.source)
        guard !srcWords.isEmpty, !starts.isEmpty else { return e.chunk.source.lowerBound }
        let k = Int((Double(heard) / Double(starts.count) * Double(srcWords.count)).rounded(.up))
        return k <= 0 ? e.chunk.source.lowerBound : srcWords[min(k, srcWords.count) - 1]
    }

    /// End offsets of the words (runs of letters/digits, with attached punctuation) inside `r` of the source.
    private func wordEnds(in r: Range<Int>) -> [Int] {
        guard !source.isEmpty else { return [r.upperBound] }
        var ends: [Int] = []
        var inWord = false
        let upper = min(r.upperBound, source.count)
        var i = r.lowerBound
        while i < upper {
            let space = source[i] == 0x20 || source[i] == 0x0A || source[i] == 0x09 || source[i] == 0x0D
            if !space { inWord = true } else if inWord { ends.append(i); inWord = false }
            i += 1
        }
        if inWord { ends.append(upper) }
        return ends
    }
}
