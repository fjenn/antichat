// M7.T03 follow-up, AT-250 c2 (R-250 AC2, A-M7-T03c option c): the per-sentence entailment check at finalize, after
// the deterministic CitationGrounding. For every citation marker that is left, each cited source is scored by the
// helper's `cite_check` model (MiniCheck; premise = the text the model saw for that source — its evidence chunks, or
// the SERP snippet of a snippet-only source; hypothesis = the sentence). A source scoring below `threshold` is taken
// out of the marker; a marker with no source left is removed, so the sentence stays as written but uncited (the copy
// rule: a pill only stands for what its passage says; R-241: no words of the answer change). One request per sentence,
// every sentence × source × window of the answer in one batched helper request.
// Attempt 6 (A-M7-T03c, lead decision 2026-11-08): claim decomposition before MiniCheck. A cited sentence is split into
// atomic claims (`claims`: the sentence itself, one claim per item of a list, the parts of coordinated clauses, a
// dash/colon appositive as "<head> is <description>"); every claim must reach the threshold on at least one cited
// source, else the marker is removed. A source stays in the marker when it supports at least one claim.
// Language: the published MiniCheck is English-only, so a non-English answer keeps the deterministic check only.
import Foundation
import NaturalLanguage

public enum CitationEntailment {
    /// P(supported) for each (claim, premise) pair, in order (the helper's `cite_check` model; one batched request).
    public typealias Scorer = @Sendable (_ pairs: [Pair]) async throws -> [Float]
    public struct Pair: Sendable, Equatable {
        public var claim: String
        public var premise: String
        public init(claim: String, premise: String) { self.claim = claim; self.premise = premise }
    }

    /// Fitted on the independently labelled attempt-1 + attempt-2 spot-checks only (131 sentences): the lowest
    /// threshold whose kept share of supported sentences is ≥ 0.92 there (0.5: 72/78 = 0.92, keeps 72 of 98 supported).
    /// Attempt 3 (50, held out) gave 32/33 at 0.5. Also MiniCheck's own decision threshold.
    public static let threshold: Float = 0.5
    /// Pairs per answer: markers past it keep the deterministic result (a long answer citing many sources per sentence
    /// would not fit the turn's time bound).
    public static let maxPairs = 96
    /// Atomic claims per sentence (the sentence itself counts as one).
    public static let maxClaims = 6

    public struct Result: Sendable, Equatable {
        public var text: String
        /// Markers scored / markers removed / single source numbers taken out of a marker that kept another.
        public var checked: Int
        public var uncited: Int
        public var narrowed: Int
        /// Pairs scored and the time the scorer took (ms), for the bench and the log.
        public var pairs: Int
        public var millis: Double
        /// Per scored marker: the sentence's best score (reports; no content).
        public var scores: [Float]
        /// nil = ran; else why it did not (language, no scorer error text).
        public var skipped: String?
    }

    /// English (or too short to tell)? The model is English-only.
    public static func english(_ text: String) -> Bool {
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(2000)))
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first else { return true }
        return lang == .english || p < 0.6
    }

    /// Atomic claims of a sentence: the sentence, then (deduplicated, at most `maxClaims` in all) one claim per list
    /// item ("used in A, B and C" → "used in A", …), the parts of coordinated clauses (", and", ", but", ", while",
    /// ";") with at least four words, and a dash/colon appositive "<head> – <description>" as "<head> is <description>".
    public static func claims(_ sentence: String) -> [String] {
        let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = [s]
        func add(_ c: String) {
            let t = c.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—–-")).trimmingCharacters(in: .whitespaces)
            if t.split(separator: " ").count >= 3, !out.contains(t), out.count < maxClaims { out.append(t) }
        }
        // appositive: "Head – description" / "Head: description" (head ≤ 6 words)
        if let r = s.range(of: #"^([^–—:]{2,60}?)\s*(?:[–—]|:)\s+(.+)$"#, options: .regularExpression) {
            let line = String(s[r])
            if let sep = line.range(of: #"\s*(?:[–—]|:)\s+"#, options: .regularExpression) {
                let head = String(line[..<sep.lowerBound]), rest = String(line[sep.upperBound...])
                if head.split(separator: " ").count <= 6 { add("\(head) is \(rest.prefix(1).lowercased() + rest.dropFirst())") }
            }
        }
        // lists "prefix A, B(, C)*(,)? and|or D suffix" → "prefix A suffix", …; an item has as many words as the one
        // just before the conjunction (so "used in medicine, agriculture and research" → "used in medicine.", …)
        if let conj = s.range(of: #",? (?:and|or) "#, options: [.regularExpression, .backwards]) {
            let left = String(s[..<conj.lowerBound]), right = String(s[conj.upperBound...])
            let parts = left.components(separatedBy: ", ")
            if parts.count >= 2 {
                let k = parts.last!.split(separator: " ").count
                let head = parts[0].split(separator: " ")
                let rightWords = right.split(separator: " ", omittingEmptySubsequences: false)
                if k >= 1, k <= 3, head.count > k, rightWords.count >= k,
                   parts.dropFirst().allSatisfy({ $0.split(separator: " ").count == k }) {
                    let prefix = head.dropLast(k).joined(separator: " ")
                    var lastItem = rightWords.prefix(k).joined(separator: " ")
                    var suffix = rightWords.dropFirst(k).joined(separator: " ")
                    // a trailing full stop or comma belongs to the suffix
                    while let ch = lastItem.last, ".,;:!?".contains(ch) { lastItem.removeLast(); suffix = String(ch) + (suffix.isEmpty ? "" : " " + suffix) }
                    let tail = suffix.isEmpty ? "" : (suffix.first.map { ".,;:!?".contains($0) } == true ? suffix : " " + suffix)
                    let items = [head.suffix(k).joined(separator: " ")] + parts.dropFirst().map { $0 } + [lastItem]
                    for it in items { add(prefix + " " + it + tail) }
                }
            }
        }
        // coordinated clauses
        let ns = s as NSString
        let clauseRE = try! NSRegularExpression(pattern: #"(?:;\s+|,\s+(?:and|but|while|whereas)\s+|\s+while\s+)"#)
        var last = 0
        for m in clauseRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            add(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = NSMaxRange(m.range)
        }
        if last > 0 { add(ns.substring(from: last)) }
        return out
    }

    public static func apply(_ text: String, evidence: [Int: String], threshold: Float = threshold,
                             scorer: Scorer) async -> Result {
        let ns = text as NSString
        let matches = CitationGrounding.markers(in: text)
        var result = Result(text: text, checked: 0, uncited: 0, narrowed: 0, pairs: 0, millis: 0, scores: [], skipped: nil)
        guard !matches.isEmpty else { return result }
        var plain = text
        for m in matches.reversed() { plain = (plain as NSString).replacingCharacters(in: m.range, with: "") }
        guard english(plain) else { result.skipped = "language"; return result }
        // 1. the markers and their (claim, source) pairs
        struct Mark { var range: NSRange; var text: String; var nums: [Int]; var known: [Int]; var claims: Int; var first: Int }
        var marks: [Mark] = [], pairs: [Pair] = []
        var lastEnd = 0
        for m in matches {
            let before = ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd))
            lastEnd = m.range.location + m.range.length
            let claim = CitationGrounding.lastSentence(before)
            let markerText = ns.substring(with: m.range)
            let nums = markerText.matches(of: /\d{1,3}/).compactMap { Int($0.output) }
            var known = claim.count > 1 ? nums.filter { evidence[$0] != nil } : []
            var parts = known.isEmpty ? [] : claims(claim)
            if pairs.count + known.count * parts.count > maxPairs { parts = [claim] }
            if pairs.count + known.count * parts.count > maxPairs { known = []; parts = [] }
            marks.append(Mark(range: m.range, text: markerText, nums: nums, known: known, claims: parts.count, first: pairs.count))
            for c in parts { pairs += known.map { Pair(claim: c, premise: evidence[$0]!) } }
        }
        guard !pairs.isEmpty else { return result }
        // 2. one batched request
        let start = ContinuousClock.now
        let scores: [Float]
        do {
            scores = try await scorer(pairs)
        } catch {
            // the check could not run (model missing / helper down): keep what the deterministic check kept
            result.skipped = "scorer: \(error)"
            return result
        }
        let d = (ContinuousClock.now - start).components
        result.millis = Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
        guard scores.count == pairs.count else { result.skipped = "scorer: \(scores.count) scores for \(pairs.count) pairs"; return result }
        result.pairs = pairs.count
        // 3. rewrite the markers
        var out = "", cursor = 0
        for mk in marks {
            out += ns.substring(with: NSRange(location: cursor, length: mk.range.location - cursor))
            cursor = mk.range.location + mk.range.length
            guard !mk.known.isEmpty else { out += mk.text; continue }
            // scores are claim-major: claim c, source k at first + c * known.count + k
            let k = mk.known.count
            let grid = (0..<mk.claims).map { c in Array(scores[(mk.first + c * k)..<(mk.first + (c + 1) * k)]) }
            result.checked += 1
            let claimBest = grid.map { $0.max() ?? 0 }
            result.scores.append(claimBest.min() ?? 0)
            // every claim must be backed by some cited source; a source stays if it backs at least one claim
            let allBacked = claimBest.allSatisfy { $0 >= threshold }
            let keep: Set<Int> = allBacked
                ? Set(mk.known.indices.filter { j in grid.contains { $0[j] >= threshold } }.map { mk.known[$0] }) : []
            // numbers without evidence are not this check's business (CitationValidator handles unfetched ones)
            let kept = mk.nums.filter { keep.contains($0) || evidence[$0] == nil }
            if keep.isEmpty {
                result.uncited += 1
                // M7.T15: numbers this check did not score stay (CitationValidator decides those)
                if !kept.isEmpty { out += mk.text.prefix { $0.isWhitespace } + "[" + kept.map(String.init).joined(separator: ",") + "]" }
            } else if kept.count < mk.nums.count {
                result.narrowed += mk.nums.count - kept.count
                out += mk.text.prefix { $0.isWhitespace } + "[" + kept.map(String.init).joined(separator: ",") + "]"
            } else {
                out += mk.text
            }
        }
        out += ns.substring(from: cursor)
        result.text = out
        return result
    }
}
