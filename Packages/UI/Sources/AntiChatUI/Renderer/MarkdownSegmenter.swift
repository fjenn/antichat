// Root-block segmentation of a streamed reply (fix/u5-renderer, NFR-U5). The reply renders as one MarkdownView per
// root block (A-M1-T09a b). Before this file the block boundaries came from MarkdownView's StreamingMarkdownReader:
// every reveal tick re-sliced every block of the reply out of the latest parse and re-diffed the whole block stack,
// with the `now` of the fade threaded through it. The binder now keeps the blocks itself, append-only:
// - blocks that can no longer change are frozen once (the same rule as MarkdownView's incremental parser: a block
//   followed by a blank line and another block);
// - each reveal re-parses only the unstable tail (normally the last block), so the per-tick cost is bounded by the
//   size of the last block, not the reply.
// Pure and nonisolated: finished replies are segmented off the main thread, streaming tails on it (they are small).
import Foundation
import Markdown

enum MarkdownSegmenter {
    struct Result: Equatable, Sendable {
        /// Root blocks as UTF-8 byte ranges of the input (separators — blank lines — excluded).
        var blocks: [Range<Int>]
        /// The leading `stable` blocks are final: text appended later cannot change them.
        var stable: Int
    }

    /// Splits `text` into root blocks.
    static func split(_ text: String) -> Result {
        var text = text
        guard !text.isEmpty else { return Result(blocks: [], stable: 0) }
        let document = Document(parsing: text)
        return text.withUTF8 { bytes in
            var lineStarts = [0]
            for i in 0..<bytes.count where bytes[i] == 0x0A { lineStarts.append(i + 1) }
            /// swift-markdown locations: 1-based line, 1-based UTF-8 column; upper bounds are exclusive.
            func offset(_ loc: SourceLocation) -> Int? {
                guard loc.line >= 1, loc.column >= 1 else { return nil }
                guard loc.line <= lineStarts.count else { return bytes.count }  // cmark: end on the line after
                let start = lineStarts[loc.line - 1]
                let end = loc.line < lineStarts.count ? lineStarts[loc.line] - 1 : bytes.count
                return min(start + loc.column - 1, end)
            }
            var ranges: [Range<Int>] = []
            ranges.reserveCapacity(document.childCount)
            for child in document.children {
                guard let r = child.range, let lo = offset(r.lowerBound), let hi = offset(r.upperBound), lo <= hi,
                    lo >= (ranges.last?.upperBound ?? 0)
                else {
                    // Unexpected source ranges: one block for everything (correct, just not incremental).
                    return Result(blocks: Self.trimmed(0..<bytes.count, bytes).map { [$0] } ?? [], stable: 0)
                }
                if hi > lo { ranges.append(lo..<hi) }
            }
            let merged = mergeDisplayMath(ranges, bytes)
            return Result(blocks: merged, stable: stableCount(merged, bytes))
        }
    }

    /// fix/u5-renderer-4: a table that is still streaming shows whole rows only — `source` cut after its last
    /// complete line — or nil when `source` is not a table. A table re-renders as a whole (every cell re-built, the
    /// grid re-measured), and doing that on every reveal tick while a row filled in was a main-thread pass over 33 ms
    /// on nearly every tick of a table on the S1 stand-in (AT-008 at 0.25: 15–20 passes per table).
    /// `lineEnded`: the received text already holds the newline after `source` (block ranges exclude it), so its
    /// last line is complete too.
    static func completeTableRows(_ source: String, lineEnded: Bool = false) -> String? {
        let lines = source.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard lines.count >= 2, lines[0].contains("|") else { return nil }
        let sep = lines[1]
        guard sep.contains("-"), sep.allSatisfy({ "|-: \t".contains($0) }) else { return nil }
        guard !lineEnded, let nl = source.lastIndex(of: "\n") else { return source }
        return String(source[..<nl])
    }

    /// fix/u5-renderer-4: a fenced code block that is still streaming shows whole lines only — `source` cut after
    /// its last newline — or nil when `source` is not a fenced code block. A code block re-renders as a whole (its
    /// highlighted text re-built and re-laid out, its scroll view re-measured); in the long chat that was a pass
    /// over 33 ms on most ticks of a streaming code block on the S1 stand-in. Its highlighting already follows
    /// completed lines (`CodeBlockView.highlightSource`).
    static func completeCodeLines(_ source: String, lineEnded: Bool = false) -> String? {
        let trimmed = source.drop { $0 == " " }
        guard source.count - trimmed.count <= 3, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
        guard !lineEnded, let nl = source.lastIndex(of: "\n") else { return source }
        return String(source[..<nl])
    }

    /// The text of a block (`range` within `text`'s UTF-8).
    static func slice(_ text: String, _ range: Range<Int>) -> String {
        var text = text
        return text.withUTF8 { bytes in
            let lo = min(max(0, range.lowerBound), bytes.count)
            let hi = min(max(lo, range.upperBound), bytes.count)
            return String(decoding: UnsafeBufferPointer(rebasing: bytes[lo..<hi]), as: UTF8.self)
        }
    }

    /// MarkdownView swaps `$$ … $$` for a placeholder before parsing, so display math that spans a blank line is one
    /// block there; keep it one block here (a block with an odd number of `$$` opens math until the next odd one).
    static func mergeDisplayMath(_ ranges: [Range<Int>], _ bytes: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        var out: [Range<Int>] = []
        out.reserveCapacity(ranges.count)
        var open = false
        for r in ranges {
            if open, let last = out.popLast() {
                out.append(last.lowerBound..<r.upperBound)
            } else {
                out.append(r)
            }
            if dollarPairs(in: r, bytes) % 2 == 1 { open.toggle() }
        }
        return out
    }

    static func dollarPairs(in r: Range<Int>, _ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        var n = 0
        var i = r.lowerBound
        while i + 1 < r.upperBound {
            if bytes[i] == 0x24, bytes[i + 1] == 0x24 {
                n += 1
                i += 2
            } else {
                i += 1
            }
        }
        return n
    }

    /// MarkdownView's `reparsedRootBlockIndex`: walking back from the last block, the first separator that holds a
    /// blank line ends the unstable tail; every block before it is final.
    static func stableCount(_ ranges: [Range<Int>], _ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        guard ranges.count > 1 else { return 0 }
        var i = ranges.count - 1
        while i > 0 {
            if hasBlankLine(ranges[i - 1].upperBound..<ranges[i].lowerBound, bytes) { break }
            i -= 1
        }
        return i
    }

    static func hasBlankLine(_ r: Range<Int>, _ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var newlines = 0
        for i in r {
            switch bytes[i] {
            case 0x0A:
                newlines += 1
                if newlines >= 2 { return true }
            case 0x20, 0x09, 0x0D:
                continue
            default:
                newlines = 0
            }
        }
        return false
    }

    static func trimmed(_ r: Range<Int>, _ bytes: UnsafeBufferPointer<UInt8>) -> Range<Int>? {
        var lo = r.lowerBound, hi = r.upperBound
        func space(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x09 || b == 0x0D }
        while lo < hi, space(bytes[lo]) { lo += 1 }
        while hi > lo, space(bytes[hi - 1]) { hi -= 1 }
        return lo < hi ? lo..<hi : nil
    }
}
