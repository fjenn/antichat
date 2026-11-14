// M7.T03 follow-up, AT-250 c2 attempt 2 (R-250 AC2, A-M7-05): a deterministic post-generation check of every cited
// sentence against the text the model saw for the cited sources (the evidence chunks of a fetched page, or the SERP
// snippet when only the snippet was in the results). The claim's checkable details must appear in that text:
//   numbers   every number of the sentence (years, versions, amounts, percents; "1,000" = "1000"; 0–20 also as words)
//   months    every month name
//   names     every capitalised word that is not the sentence's first word or a common word
//   words     (attempt 3) at least `minCoverage` of the sentence's content words (≥ 4 letters, not a function word)
//             occur in that text (whole word or its 5-letter stem): catches added qualifiers, extra list items and
//             embellishments the source does not state ("signage", "paints and lubricants", "stagnation")
//   recency   (attempt 5) a recency claim ("latest", "most recent", "newest", "current", "next", "upcoming") needs a
//             recency word within 150 characters of one of the claim's anchors in that text (its numbers, else its
//             capitalised names): a version list or a release note dated X does not say X is the latest
//   qualifier (attempt 5) a scope or strength word of the claim ("main", "only", "first", "largest", "often",
//             "steadily", "decisive", …) must occur within 150 characters of one of the claim's anchors in that text
//             (its numbers, capitalised names or long content words): "the main use", "by far the most prevalent"
//             (bars-2) the same for strengthenings, backed by any of their forms: "headquartered" (headquarters, HQ),
//             "essential", "pioneering", "must" (required, mandatory), "as little as", "foundational", "crucial"
//   stage     (attempt 5) a release stage ("alpha", "beta", "preview", "release candidate" / "RC") must be the one the
//             text names (a passage at "RC 1" does not back "in beta")
// A sentence that fails keeps its text but loses its citation marker (it is no longer shown as backed by that
// source): a pill only stands for what its passage says. Names and numbers only; no meaning judgement, no filtering of
// what the model may say (R-241: the answer text is unchanged apart from the markers).
import Foundation

public enum CitationGrounding {
    public struct Result: Sendable, Equatable {
        public var text: String
        /// Cited sentences checked / marked uncited.
        public var checked: Int
        public var uncited: Int
        /// Per uncited sentence, the details its passage lacked (logs / reports, no content beyond the tokens).
        public var missing: [[String]]
        /// bars-3: the uncited sentences themselves (bench replay on labelled runs; never logged by the app).
        public var removedClaims: [String] = []
    }

    /// M7.T15 (R-241 audit): only spaces/tabs before a marker are part of it (a removed marker never joins paragraphs).
    static let marker = try! NSRegularExpression(pattern: #"(?:[ \t]*\[\d{1,3}(?:\s*,\s*\d{1,3})*\])+"#)
    static let code = try! NSRegularExpression(pattern: #"```[\s\S]*?(?:```|$)|`[^`\n]+`"#)

    /// The citation markers of `text` outside fenced and inline code (M7.T15: `arr[1]` or `[1, 2]` in code is code, not a
    /// citation, so the checks never remove it and the answer's words and code stay exactly as written).
    public static func markers(in text: String) -> [NSTextCheckingResult] {
        let range = NSRange(location: 0, length: (text as NSString).length)
        let found = marker.matches(in: text, range: range)
        guard text.contains("`") else { return found }
        let spans = code.matches(in: text, range: range).map(\.range)
        return found.filter { m in !spans.contains { NSIntersectionRange($0, m.range).length > 0 } }
    }
    /// M7 bars: `text` without its citation markers (outside code), words unchanged: a reply whose checks never
    /// finished (the app quit) keeps no unchecked pill.
    public static func removingMarkers(_ text: String) -> String {
        let ns = text as NSString
        var out = "", cursor = 0
        for m in markers(in: text) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            cursor = m.range.location + m.range.length
        }
        return out + ns.substring(from: cursor)
    }
    static let number = try! NSRegularExpression(pattern: #"\d+(?:[.,]\d+)*"#)
    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
                         "november", "december"]
    static let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
                        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
    static let common: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "it", "its", "in", "on", "at", "for", "of", "and", "or", "but",
        "as", "by", "to", "from", "with", "however", "also", "according", "both", "each", "while", "although", "since",
        "after", "before", "during", "there", "their", "they", "he", "she", "his", "her", "we", "you", "i", "if", "when",
        "where", "which", "who", "what", "how", "why", "yes", "no", "not", "note", "overall", "today", "currently",
        "additionally", "furthermore", "meanwhile", "instead", "finally", "first", "second", "third", "some", "many",
        "most", "all", "other", "another", "such", "here", "so", "then", "thus", "key", "summary", "source", "sources",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]

    /// Attempt 3: the share of a cited sentence's content words its passage must contain (chosen on the
    /// independently labelled attempt-1 spot-check: 0.6 lifts its supported share from 0.77 to 0.86 and keeps 51 of
    /// its 58 supported sentences cited).
    public static let minCoverage = 0.6

    /// Function words and answer boilerplate that carry no claim (coverage ignores them).
    static let function: Set<String> = [
        "this", "that", "these", "those", "with", "from", "into", "over", "under", "between", "through", "within",
        "without", "about", "after", "before", "during", "while", "although", "since", "however", "also", "according",
        "both", "each", "there", "their", "they", "them", "then", "than", "when", "where", "which", "what", "whose",
        "have", "has", "had", "were", "been", "being", "will", "would", "could", "should", "might", "must", "does",
        "more", "less", "very", "some", "many", "most", "other", "another", "such", "here", "thus", "only", "just",
        "note", "overall", "today", "currently", "additionally", "furthermore", "meanwhile", "instead", "finally",
        "first", "second", "third", "summary", "source", "sources", "based", "search", "results", "result", "official",
        "officially", "latest", "current", "recent", "recently", "well", "known", "used", "uses", "using", "include",
        "includes", "including", "like", "often", "generally", "typically", "around", "approximately", "nearly",
        "roughly", "important", "notably", "specifically", "particularly", "even", "still", "make", "makes",
    ]

    /// `evidence[n]` = what the model saw for source `n` (chunks, or the snippet).
    public static func apply(_ text: String, evidence: [Int: String]) -> Result {
        let ns = text as NSString
        let matches = markers(in: text)
        guard !matches.isEmpty else { return Result(text: text, checked: 0, uncited: 0, missing: []) }
        let lowered = evidence.mapValues { normalize($0) }
        var out = "", cursor = 0, checked = 0, uncited = 0
        var missing: [[String]] = [], removed: [String] = []
        var lastEnd = 0
        for m in matches {
            let before = ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd))
            let claim = lastSentence(before)
            let nums = ns.substring(with: m.range).matches(of: /\d{1,3}/).compactMap { Int($0.output) }
            let passage = nums.compactMap { lowered[$0] }.joined(separator: "\n")
            let context = ns.substring(to: m.range.location)
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            cursor = m.range.location + m.range.length
            lastEnd = cursor
            guard !passage.isEmpty, !claim.isEmpty else { out += ns.substring(with: m.range); continue }
            checked += 1
            let lack = unsupported(claim, passage: passage, context: context, sources: nums.compactMap { lowered[$0] })
            if lack.isEmpty {
                out += ns.substring(with: m.range)
            } else {
                uncited += 1
                missing.append(lack)
                removed.append(claim)
            }
        }
        out += ns.substring(from: cursor)
        return Result(text: out, checked: checked, uncited: uncited, missing: missing, removedClaims: removed)
    }

    /// M7 bars-2 (AT-248 c1 "≥ 2 pills per run", lead decision 2026-11-10: the bar means ≥ 2 distinct sources per
    /// answer). When the answer (after `apply`) cites fewer than two distinct sources and another source of the turn
    /// supports a cited sentence on its own, that source is added to the sentence's marker. "Supports" is the same
    /// deterministic check as `apply` (every number, month, name, recency word, stage and qualifier of the sentence in
    /// that source's text) with a stricter coverage (`spreadCoverage` of its content words) and at least one anchor
    /// (a number or a name) in common, so a second citation is never made up; the entailment check and the verifier
    /// then judge the added source like any other (they remove it when it does not hold). Only `candidates` (fetched
    /// sources) are added; at most one source per marker.
    public struct Spread: Sendable, Equatable {
        public var text: String
        public var added: Int
    }
    public static let spreadCoverage = 0.8

    public static func spread(_ text: String, evidence: [Int: String], candidates: Set<Int>) -> Spread {
        let ns = text as NSString
        let matches = markers(in: text)
        let cited = Set(matches.flatMap { ns.substring(with: $0.range).matches(of: /\d{1,3}/).compactMap { Int($0.output) } })
        let pool = candidates.subtracting(cited).filter { evidence[$0] != nil }
        guard !matches.isEmpty, cited.count < 2, !pool.isEmpty else { return Spread(text: text, added: 0) }
        let lowered = evidence.mapValues { normalize($0) }
        var out = "", cursor = 0, added = 0
        for m in matches {
            let before = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += before
            cursor = NSMaxRange(m.range)
            let raw = ns.substring(with: m.range)
            let nums = raw.matches(of: /\d{1,3}/).compactMap { Int($0.output) }
            let claim = lastSentence(before)  // as in `apply`: the text since the previous marker
            var best: (n: Int, share: Double)?
            if !claim.isEmpty, hasAnchor(claim) {
                for n in pool.sorted() where !nums.contains(n) {
                    guard let passage = lowered[n], unsupported(clauseCased(claim), passage: passage).isEmpty else { continue }
                    let share = coverage(withoutLabel(claim), passage: passage).0
                    if share >= spreadCoverage, share > (best?.share ?? -1) { best = (n, share) }
                }
            }
            if let best {
                let lead = String(raw.prefix { $0 == " " || $0 == "\t" })
                out += lead + "[" + (nums + [best.n]).map(String.init).joined(separator: ", ") + "]"
                added += 1
            } else {
                out += raw
            }
        }
        out += ns.substring(from: cursor)
        return Spread(text: out, added: added)
    }

    /// M7 bars-3 (AT-248 c1, lead decision 3 of 2026-11-10): when the answer cites fewer than two distinct sources (M7
    /// at248: or shows fewer than two pills), an
    /// UNCITED factual sentence (a number or a name to check, at least four words; not a heading, table row, lead-in or
    /// code) gets a fetched source of the turn that alone passes the full deterministic check — every number, month,
    /// name, recency word, stage, qualifier and scope of the sentence in that source's text, coverage
    /// ≥ `spreadCoverage` — preferring a source not yet cited. The entailment check and the verifier then judge it like
    /// every other marker; the app attaches after the answer's own markers were checked, runs MiniCheck and the
    /// verifier on the attached markers alone (`keeping`) and keeps only those both pass, none when either did not
    /// finish (`standing`, `detach`). Never a source for a sentence no source supports; the words never change.
    public struct Attached: Sendable, Hashable {
        public var claim: String
        public var source: Int
        public init(claim: String, source: Int) {
            self.claim = claim
            self.source = source
        }
    }
    public struct Attach: Sendable, Equatable {
        public var text: String
        public var attached: [Attached]
        public var added: Int { attached.count }
        public init(text: String, attached: [Attached]) {
            self.text = text
            self.attached = attached
        }
    }
    public static let attachMinWords = 4

    public static func attach(_ text: String, evidence: [Int: String], candidates: Set<Int>) -> Attach {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let found = markers(in: text)
        let numbers = found.map { ns.substring(with: $0.range).matches(of: /\d{1,3}/).compactMap { Int($0.output) } }
        var cited = Set(numbers.flatMap { $0 })
        let pool = candidates.filter { evidence[$0] != nil }
        // M7 at248 (AT-248 c1 = ≥ 2 rendered pills): also when the answer shows fewer than two pills — a marker naming
        // a fetched source draws one pill, a combined `[1, 2]` is one pill however many sources it names.
        let pills = numbers.filter { !Set($0).isDisjoint(with: candidates) }.count
        guard cited.count < 2 || pills < 2, !pool.isEmpty else { return Attach(text: text, attached: []) }
        let lowered = evidence.mapValues { normalize($0) }
        let codeSpans = text.contains("`") ? code.matches(in: text, range: all).map(\.range) : []
        // sentence segments, split like `lastSentence` reads them
        var segments: [NSRange] = [], start = 0
        for m in boundary.matches(in: text, range: all) {
            if ns.substring(with: NSRange(location: m.range.location, length: 1)) != "\n",
               endsAbbreviation(ns.substring(to: m.range.location + 1)) { continue }
            segments.append(NSRange(location: start, length: NSMaxRange(m.range) - start))
            start = NSMaxRange(m.range)
        }
        if start < ns.length { segments.append(NSRange(location: start, length: ns.length - start)) }
        var inserts: [(at: Int, n: Int)] = [], attached: [Attached] = []
        for seg in segments {
            if found.contains(where: { NSIntersectionRange($0.range, seg).length > 0 }) { continue }
            if codeSpans.contains(where: { NSIntersectionRange($0, seg).length > 0 }) { continue }
            let raw = ns.substring(with: seg)
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("|") || line.hasPrefix(">") || line.hasSuffix(":")
                || line.hasSuffix(":**") || line.contains("```") { continue }
            // the claim exactly as `apply` will read it once the marker stands before the sentence's end
            var body = raw
            while let last = body.last, last.isWhitespace || ".!?;:".contains(last) { body.removeLast() }
            let claim = cleanClaim(body)
            let wordCount = claim.split { !($0.isLetter || $0.isNumber) }.count
            guard wordCount >= attachMinWords, hasAnchor(claim) else { continue }
            let context = ns.substring(to: seg.location) + body
            var best: (n: Int, fresh: Bool, share: Double)?
            for n in pool.sorted() {
                guard let passage = lowered[n], unsupported(clauseCased(claim), passage: passage, context: context).isEmpty else { continue }
                let share = coverage(withoutLabel(claim), passage: passage).0
                guard share >= spreadCoverage else { continue }
                let fresh = !cited.contains(n)
                if best == nil || (fresh && !best!.fresh) || (fresh == best!.fresh && share > best!.share) { best = (n, fresh, share) }
            }
            guard let best else { continue }
            inserts.append((seg.location + (body as NSString).length, best.n))
            attached.append(Attached(claim: claim, source: best.n))
            cited.insert(best.n)
        }
        guard !inserts.isEmpty else { return Attach(text: text, attached: []) }
        var out = text as NSString
        for i in inserts.reversed() { out = out.replacingCharacters(in: NSRange(location: i.at, length: 0), with: " [\(i.n)]") as NSString }
        return Attach(text: out as String, attached: attached)
    }

    /// Dev diagnostics (bench `attach-replay`): per uncited candidate sentence, what each candidate source lacks.
    public static func attachDiagnosis(_ text: String, evidence: [Int: String], candidates: Set<Int>) -> [[String: String]] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let found = markers(in: text)
        let lowered = evidence.mapValues { normalize($0) }
        var out: [[String: String]] = [], start = 0
        var segments: [NSRange] = []
        for m in boundary.matches(in: text, range: all) {
            if ns.substring(with: NSRange(location: m.range.location, length: 1)) != "\n",
               endsAbbreviation(ns.substring(to: m.range.location + 1)) { continue }
            segments.append(NSRange(location: start, length: NSMaxRange(m.range) - start))
            start = NSMaxRange(m.range)
        }
        if start < ns.length { segments.append(NSRange(location: start, length: ns.length - start)) }
        for seg in segments where !found.contains(where: { NSIntersectionRange($0.range, seg).length > 0 }) {
            var body = ns.substring(with: seg)
            while let last = body.last, last.isWhitespace || ".!?;:".contains(last) { body.removeLast() }
            let claim = cleanClaim(body)
            guard claim.split(separator: " ").count >= 3 else { continue }
            var row = ["claim": claim, "anchor": hasAnchor(claim) ? "yes" : "no"]
            for n in candidates.sorted() {
                guard let p = lowered[n] else { row["\(n)"] = "no evidence"; continue }
                let lack = unsupported(clauseCased(claim), passage: p, context: ns.substring(to: seg.location) + body)
                let share = coverage(withoutLabel(claim), passage: p).0
                row["\(n)"] = (lack.isEmpty ? "ok" : lack.joined(separator: "; ")) + " | cov \(Int(share * 100))"
            }
            out.append(row)
        }
        return out
    }

    /// `text` with only the attached markers (every other marker removed, words unchanged): the attached sentences
    /// alone go through the entailment check and the verifier.
    public static func keeping(_ text: String, only attached: [Attached]) -> String {
        let ns = text as NSString
        var out = "", cursor = 0
        for m in markers(in: text) {
            let before = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += before
            cursor = NSMaxRange(m.range)
            let nums = ns.substring(with: m.range).matches(of: /\d{1,3}/).compactMap { Int($0.output) }
            if nums.count == 1, attached.contains(Attached(claim: lastSentence(before), source: nums[0])) { out += ns.substring(with: m.range) }
        }
        return out + ns.substring(from: cursor)
    }

    /// The attached markers still standing in `text`.
    /// M7 verifier: every (claim, source) pair the text's markers state (a combined marker gives one pair per source).
    public static func pairs(_ text: String) -> Set<Attached> {
        let ns = text as NSString
        var out = Set<Attached>(), cursor = 0
        for m in markers(in: text) {
            let before = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            cursor = NSMaxRange(m.range)
            let claim = lastSentence(before)
            for n in ns.substring(with: m.range).matches(of: /\d{1,3}/).compactMap({ Int($0.output) }) { out.insert(Attached(claim: claim, source: n)) }
        }
        return out
    }

    public static func standing(_ text: String, attached: [Attached]) -> [Attached] {
        let ns = text as NSString
        var out: [Attached] = [], cursor = 0
        for m in markers(in: text) {
            let before = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            cursor = NSMaxRange(m.range)
            let nums = ns.substring(with: m.range).matches(of: /\d{1,3}/).compactMap { Int($0.output) }
            let a = nums.count == 1 ? Attached(claim: lastSentence(before), source: nums[0]) : nil
            if let a, attached.contains(a) { out.append(a) }
        }
        return out
    }

    /// The attached markers in `text` removed (their checks failed or did not all finish).
    public static func detach(_ text: String, attached: [Attached]) -> String {
        guard !attached.isEmpty else { return text }
        let ns = text as NSString
        var out = "", cursor = 0
        for m in markers(in: text) {
            let before = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += before
            cursor = NSMaxRange(m.range)
            let nums = ns.substring(with: m.range).matches(of: /\d{1,3}/).compactMap { Int($0.output) }
            let claim = lastSentence(before)
            if nums.count == 1, attached.contains(Attached(claim: claim, source: nums[0])) { continue }
            out += ns.substring(with: m.range)
        }
        return out + ns.substring(from: cursor)
    }

    /// The claim names something checkable: a number or a capitalised name after its first word.
    static func hasAnchor(_ claim: String) -> Bool {
        if number.firstMatch(in: claim, range: NSRange(location: 0, length: (claim as NSString).length)) != nil { return true }
        let tokens = claim.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "-") }.map(String.init)
        return tokens.dropFirst().contains { ($0.first?.isUppercase ?? false) && $0.count >= 3 && !common.contains($0.lowercased()) }
    }

    /// The sentence a marker closes: the text after the previous sentence end (or line break) in `before`.
    public static func lastSentence(_ before: String) -> String {
        cleanClaim(splitLast(before).last)
    }

    /// bars-3: `before` split into the text up to the last sentence boundary (`head`, the claim's context in the
    /// answer) and the sentence after it (`last`, uncleaned).
    static func splitLast(_ before: String) -> (head: String, last: String) {
        var s = before
        while let last = s.last, last.isWhitespace || ".!?;:".contains(last) { s.removeLast() }
        let ns = s as NSString
        for m in boundary.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            if ns.substring(with: NSRange(location: m.range.location, length: 1)) != "\n",
               endsAbbreviation(ns.substring(to: m.range.location + 1)) { continue }
            return (ns.substring(to: NSMaxRange(m.range)), ns.substring(from: NSMaxRange(m.range)))
        }
        return ("", s)
    }
    static let boundary = try! NSRegularExpression(pattern: #"[.!?](?:\s+|$)|\n"#)

    public static func cleanClaim(_ s: String) -> String {
        s.replacingOccurrences(of: #"^(?:\s*(?:[-*+#]+|\d{1,3}[.)])(?:\s+|$))+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    public static func endsAbbreviation(_ s: String) -> Bool {
        s.range(of: #"(?:\b[A-Z]\.){2,}$"#, options: .regularExpression) != nil
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: #"(?<=\d),(?=\d{3})"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\d)[\u{00A0}\u{202F} ](?=\d{3}\b)"#, with: "", options: .regularExpression)
    }

    /// The claim's details that the passage does not contain (empty = supported as far as this check can tell).
    /// bars-3: `context` = the answer's text up to the marker (the claim included; the version the answer is about,
    /// `scopeVersions`), `sources` = the cited sources' texts one by one (the scope checks pass when one source backs
    /// the claim; default: `passage` as one source).
    static func unsupported(_ claim: String, passage: String, context: String = "", sources: [String] = []) -> [String] {
        var lack: [String] = []
        let c = normalize(claim)
        let cns = c as NSString
        for m in number.matches(in: c, range: NSRange(location: 0, length: cns.length)) {
            var n = cns.substring(with: m.range)
            while n.hasSuffix(".") || n.hasSuffix(",") { n.removeLast() }
            if containsNumber(n, in: passage) { continue }
            if let v = Int(n), v >= 0, v < words.count, containsWord(words[v], in: passage) { continue }
            lack.append(n)
        }
        for month in months where containsWord(month, in: c) && !containsWord(month, in: passage) {
            // "may" is also a verb: only a capitalised May counts as the month
            if month == "may", !claim.contains("May") { continue }
            lack.append(month)
        }
        let tokens = claim.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "-") }.map(String.init)
        // M7 at248: a list item's lead-in label ("Hardware Requirement: It is …") is a heading in title case, not a
        // name: like the sentence's first word, its words are not checked as names (its numbers still are, and its
        // words still count toward coverage).
        let labelled = withoutLabel(claim)
        let skip = labelled == claim ? 1
            : max(1, String(claim.dropLast(labelled.count)).split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "-") }.count)
        for (i, t) in tokens.enumerated() where i >= skip {
            guard let f = t.first, f.isUppercase, t.count >= 3 else { continue }
            let w = t.lowercased().replacingOccurrences(of: #"'s$"#, with: "", options: .regularExpression)
            if common.contains(w) || months.contains(w) || containsWord(w, in: passage) { continue }
            // a hyphenated or plural form: accept when its stem is in the passage
            let stem = w.split(separator: "-").first.map(String.init) ?? w
            if stem.count >= 3, passage.contains(stem) { continue }
            lack.append(t)
        }
        if recencyClaim(c), !recencyBacked(claim, passage: passage) { lack.append("recency") }
        for (claimTerm, forms) in stages where containsWord(claimTerm, in: c) {
            if !forms.contains(where: { containsWord($0, in: passage) }) { lack.append(claimTerm) }
        }
        for q in qualifiers where containsWord(q, in: c) && !qualifierBacked(q, claim: claim, passage: passage) {
            lack.append("qualifier \(q)")
        }
        for (q, forms) in strengthenings where containsWord(q, in: c) && !qualifierBacked(forms, claim: claim, passage: passage) {
            lack.append("qualifier \(q)")
        }
        let scoped = (sources.isEmpty ? [passage] : sources).map { scopeLack(claim, passage: $0, context: context) }
        if !scoped.contains(where: \.isEmpty) { lack += scoped.first ?? [] }
        let (share, absent) = coverage(claim, passage: passage)
        if share < minCoverage { lack.append("coverage \(Int((share * 100).rounded()))%: " + absent.joined(separator: " ")) }
        return lack
    }

    /// Attempt 5 (A-M7-T03c): recency words. A claim using one of `recencyClaims` needs any of `recency` in its passage.
    static let recencyClaims = ["latest", "most recent", "newest", "current", "currently", "next", "upcoming"]
    static let recency = ["latest", "most recent", "newest", "recent", "recently", "current", "currently", "next", "upcoming"]
    static func recencyClaim(_ c: String) -> Bool { recencyClaims.contains { containsWord($0, in: c) } }
    static let recencyWindow = 150

    /// A recency word near an anchor of the claim (its numbers; without numbers its capitalised names; without either,
    /// anywhere in the passage).
    static func recencyBacked(_ claim: String, passage: String) -> Bool {
        let c = normalize(claim), cns = c as NSString
        var anchors: [String] = number.matches(in: c, range: NSRange(location: 0, length: cns.length)).map {
            var n = cns.substring(with: $0.range)
            while n.hasSuffix(".") || n.hasSuffix(",") { n.removeLast() }
            return #"(?<![\d.,])"# + NSRegularExpression.escapedPattern(for: n) + #"(?![\d]|[.,]\d)"#
        }
        if anchors.isEmpty {
            let tokens = claim.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "-") }.map(String.init)
            anchors = tokens.enumerated().filter { $0.offset > 0 && ($0.element.first?.isUppercase ?? false) && $0.element.count >= 3 }
                .map { #"\b"# + NSRegularExpression.escapedPattern(for: $0.element.lowercased()) + #"\b"# }
        }
        guard !anchors.isEmpty else { return recency.contains { containsWord($0, in: passage) } }
        let pns = passage as NSString
        for a in anchors {
            guard let re = try? NSRegularExpression(pattern: a, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: passage, range: NSRange(location: 0, length: pns.length)) {
                let lo = max(0, m.range.location - recencyWindow), hi = min(pns.length, NSMaxRange(m.range) + recencyWindow)
                let seg = pns.substring(with: NSRange(location: lo, length: hi - lo))
                if recency.contains(where: { containsWord($0, in: seg) }) { return true }
            }
        }
        return false
    }
    /// Attempt 5: release stages; the claim's stage must be named in the passage (any of its forms).
    static let stages: [(String, [String])] = [
        ("alpha", ["alpha"]), ("beta", ["beta"]), ("preview", ["preview"]),
        ("release candidate", ["release candidate", "rc", "rc1", "rc2", "rc3"]), ("rc", ["release candidate", "rc", "rc1", "rc2", "rc3"]),
    ]

    /// Attempt 5: scope/strength qualifiers (superlatives, exclusivity, frequency, degree) that a source must state.
    static let qualifiers = [
        "main", "mainly", "primarily", "primary", "sole", "solely", "only", "first", "largest", "biggest", "smallest",
        "best", "steadily", "always", "never", "widely", "often", "commonly", "usually", "decades", "entirely",
        "completely", "fully", "exclusively", "leading", "dominant", "prevalent", "decisive", "invisible", "frictionless",
        "thinnest", "strongest", "fastest", "oldest", "newest", "highest", "lowest",
    ]
    /// M7 bars-2 (A-M7-T03c, lead decision 2026-11-10): strengthenings seen in the held-out-3 T3 misses. The word of
    /// the claim must be backed by one of its forms near an anchor: "headquartered" for an imprint address, "essential",
    /// "pioneering", "must" where the source says "usually", "as little as", "foundational". Replayed on the held-out-3
    /// labels of all three tiers (now dev): 0 supported sentences lose their marker, 6 partial ones do.
    static let strengthenings: [(String, [String])] = {
        let hq = ["headquarters", "headquartered", "headquarter", "hq", "head office", "head-office"]
        let pioneer = ["pioneer", "pioneers", "pioneered", "pioneering"]
        let must = ["must", "required", "requires", "require", "mandatory", "obliged", "have to", "has to"]
        return [
            ("headquartered", hq), ("headquarters", hq), ("headquarter", hq),
            ("essential", ["essential"]), ("essentially", ["essential", "essentially"]),
            ("pioneering", pioneer), ("pioneered", pioneer), ("pioneer", pioneer),
            ("must", must), ("mandatory", ["mandatory", "must", "required", "compulsory"]),
            ("foundational", ["foundation", "foundations", "foundational"]), ("as little as", ["as little as"]),
            ("crucial", ["crucial"]), ("vital", ["vital"]), ("critical", ["critical"]),
        ]
    }()
    static let strengthWords = Set(strengthenings.map(\.0))
    static let anchorStop: Set<String> = ["which", "where", "there", "their", "about", "these", "those", "while", "other",
                                          "being", "after", "before", "during", "under", "first", "through", "between"]

    /// The qualifier occurs near one of the claim's anchors (numbers, capitalised names, words of ≥ 6 letters).
    static func qualifierBacked(_ q: String, claim: String, passage: String) -> Bool {
        qualifierBacked([q], claim: claim, passage: passage)
    }

    /// Any of `forms` occurs near one of the claim's anchors.
    static func qualifierBacked(_ forms: [String], claim: String, passage: String) -> Bool {
        let tokens = claim.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "-") }.map(String.init)
        var anchors = number.matches(in: claim, range: NSRange(location: 0, length: (claim as NSString).length))
            .map { NSRegularExpression.escapedPattern(for: (claim as NSString).substring(with: $0.range)) }
        for (i, t) in tokens.enumerated() {
            let w = t.lowercased()
            let name = i > 0 && (t.first?.isUppercase ?? false) && t.count >= 3
            if name || (t.count >= 6 && !anchorStop.contains(w) && !qualifiers.contains(w) && !strengthWords.contains(w)) {
                anchors.append(#"\b"# + NSRegularExpression.escapedPattern(for: t) + #"\b"#)
            }
        }
        let pns = passage as NSString
        for a in anchors {
            guard let re = try? NSRegularExpression(pattern: a, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: passage, range: NSRange(location: 0, length: pns.length)) {
                let lo = max(0, m.range.location - recencyWindow), hi = min(pns.length, NSMaxRange(m.range) + recencyWindow)
                let seg = pns.substring(with: NSRange(location: lo, length: hi - lo))
                if forms.contains(where: { containsWord($0, in: seg) }) { return true }
            }
        }
        return false
    }

    /// The share of the claim's content words found in the passage, and the ones that are not.
    /// M7 at248 (spread / attach coverage only): a list item's lead-in label ("Release date: …", "Previous patch: …",
    /// ≤ 4 words before a colon, followed by a sentence of ≥ `attachMinWords` words) names the topic, it states nothing:
    /// its words do not count toward the content-word coverage of a source considered for the sentence. The label's
    /// numbers and names are still checked (`unsupported` reads the whole claim), and `apply`'s check of the model's own
    /// markers is unchanged.
    static func withoutLabel(_ claim: String) -> String {
        guard let r = claim.range(of: #"^[^:\n]{1,40}:\s+"#, options: .regularExpression) else { return claim }
        let label = claim[r].dropLast().split { !($0.isLetter || $0.isNumber) }
        let rest = String(claim[r.upperBound...])
        guard label.count <= 4, rest.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).count >= attachMinWords else { return claim }
        return rest
    }

    /// M7 at248 (spread / attach only): the word that opens a clause after a colon ("…: Provides bug fixes") is
    /// capitalised as a sentence start, not as a name: it is lowercased so the name check skips it like a sentence's
    /// first word (it still counts toward coverage). All-caps or mixed-case words ("AI", "macOS") are left alone.
    static func clauseCased(_ claim: String) -> String {
        guard claim.contains(": ") else { return claim }
        let r = try! NSRegularExpression(pattern: #"(?<=: )(\p{Lu})(?=\p{Ll}+\b)"#)
        let ns = NSMutableString(string: claim)
        for m in r.matches(in: claim, range: NSRange(location: 0, length: ns.length)).reversed() {
            ns.replaceCharacters(in: m.range, with: ns.substring(with: m.range).lowercased())
        }
        return ns as String
    }

    static func coverage(_ claim: String, passage: String) -> (Double, [String]) {
        let words = claim.lowercased().split { !($0.isLetter || $0 == "'" || $0 == "-") }.map(String.init)
            .filter { $0.count >= 4 && !function.contains($0) }
        guard !words.isEmpty else { return (1, []) }
        let absent = words.filter { !passage.contains($0) && !passage.contains(String($0.prefix(5))) }
        return (1 - Double(absent.count) / Double(words.count), absent)
    }

    static func containsNumber(_ n: String, in passage: String) -> Bool {
        guard let r = try? NSRegularExpression(pattern: #"(?<![\d.,])"# + NSRegularExpression.escapedPattern(for: n) + #"(?![\d]|[.,]\d)"#)
        else { return passage.contains(n) }
        return r.firstMatch(in: passage, range: NSRange(location: 0, length: (passage as NSString).length)) != nil
    }

    static func containsWord(_ w: String, in text: String) -> Bool {
        text.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: w) + #"\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
