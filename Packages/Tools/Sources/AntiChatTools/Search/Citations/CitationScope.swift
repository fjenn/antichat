// M7 bars-3 (A-M7-T03c, lead decision 2 of 2026-11-10): scope checks of CitationGrounding. The deterministic checks
// asked only whether each detail of a cited sentence occurs *somewhere* in its source; the held-out-4 T1 misses had
// every word in the source but under the wrong heading:
//   version  a release-notes page lists several versions of one product; an item of one version was cited as part of
//            another (FreeBSD 15.0-RELEASE items under "the most recent release is 15.1"; Neo4j fixes listed under
//            5.26.33 / 2026.10.1 given as 2026.10.2's). The version a sentence is about is the one it names, else the
//            one its heading names: the nearest earlier sentence naming a version on its line, or on a line that heads
//            it (a heading, a lead-in, a parent list item; a sibling list item does not) — and when that sentence names
//            several versions, the one the answer called latest / current before. The span of the source that states
//            the sentence (a window holding most of its content words) must sit under a compatible version of the same
//            product line: the line's versions inside the span, else the nearest one before it. Versions of other
//            products on the page (a bundled "Go 1.27.3", "Electron 42.11.18") and reference points ("changes since
//            2.568.3") are not headings; a sentence stated next to the version it names passes.
//   entity   a rank stated for another entity level than the source's ("the sixth-most populous city" where the
//            source ranks the metropolitan area): the level a rank is bound to (the level word right after it, else
//            the nearest level word before it in its sentence) must be the claim's, for some occurrence of that rank.
// Measured on the dev labels (held-out-3 and held-out-4, all tiers; `antichat-bench citations --stage
// grounding-replay`); a span form for every capitalised name was tried and dropped there (it removed 88 supported
// sentences for 10 partial ones: list labels and paraphrases spread over a page). Generic word lists and positions
// only; no fixture or site is special-cased. A sentence that fails keeps its words and loses its marker, like every
// other grounding check (R-241: no word of the answer changes).
import Foundation

extension CitationGrounding {
    /// A version-like number in a text: its position and numeric parts ("15.1-RELEASE" → [15, 1]).
    struct Version: Equatable {
        var location: Int
        var parts: [Int]
        /// The product word before it ("neo4j", "freebsd", "go"), nil when none ("version 1.2", "15.0-RELEASE").
        var name: String?
        /// Named as a reference point ("changes since 2.568.3", "introduced in 0.162.0"), not as a heading.
        var reference = false
    }

    static let referenceWords: Set<String> = ["since", "from", "than", "before", "after", "until", "prior", "older",
                                              "replaces", "supersedes", "introduced", "deprecated", "upgrading", "upgrade",
                                              "migrating", "migrate", "previous", "earlier"]

    /// The word right before a version (skipping "v", "version", "in", "to").
    static func referenced(before location: Int, in text: NSString) -> Bool {
        let lo = max(0, location - 32)
        var words = text.substring(with: NSRange(location: lo, length: location - lo)).lowercased()
            .split { !$0.isLetter }.map(String.init)
        while let w = words.last, versionWords.contains(w) || ["in", "to", "the", "of"].contains(w) { words.removeLast() }
        return words.last.map { referenceWords.contains($0) } ?? false
    }

    /// Dotted numbers of a text (bare), as versions: a claim's "26.08 series", a heading's "major changes in 2.1".
    static func dotted(in text: String) -> [Version] {
        let ns = text as NSString
        let re = try! NSRegularExpression(pattern: #"(?<![\d.])\d{1,4}(?:\.\d{1,4}){1,3}(?![\d]|\.\d)"#)
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            Version(location: $0.range.location, parts: ns.substring(with: $0.range).split(separator: ".").compactMap { Int($0) },
                    name: productName(before: $0.range.location, in: ns), reference: referenced(before: $0.range.location, in: ns))
        }
    }

    /// Numbers read as versions: three or more dotted parts (not a dd.mm.yyyy date); two parts after "version",
    /// "release", "v", "update", "patch" or a product-like name, or before "-release", "lts", "beta", "rc".
    static let versionPatterns: [NSRegularExpression] = [
        #"(?<![\d.])(\d{1,4}(?:\.\d{1,4}){2,3})(?![\d]|\.\d)"#,
        #"\b(?:version|versions|release|releases|v|ver|update|patch)\.?\s?(\d{1,4}\.\d{1,4})(?![\d]|\.\d)"#,
        #"(?<![\d.])(\d{1,4}\.\d{1,4})(?=[-\s]?(?:release|stable|lts|beta|rc\d?|alpha)\b)"#,
        #"\b([a-z][a-z0-9+#]*\d?[a-z0-9+#]*)\s(\d{1,3}\.\d{1,3})(?![\d]|\.\d|\s*(?:%|percent|per\b|million|billion|trillion|thousand|hundred|km|kilomet|mi\b|miles|metres|meters|m\b|cm|mm|kg|g\b|lb|tons|tonnes|times|x\b|hours|minutes|seconds|years|days|months|weeks|degrees|°|points|stars|out\b|/))"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// Words before a two-part number that make it a figure, not a version ("about 1.5", "rated 4.5").
    static let notProduct: Set<String> = [
        "about", "around", "approximately", "nearly", "almost", "over", "under", "than", "only", "just", "some", "roughly",
        "is", "was", "are", "were", "be", "been", "of", "to", "by", "at", "from", "in", "on", "and", "or", "with", "the", "a",
        "an", "rated", "rating", "score", "scored", "gpa", "population", "grew", "fell", "rose", "gdp", "height", "weight",
        "density", "average", "mean", "median", "magnitude", "ph", "ratio", "rate", "index", "up", "down", "least", "most",
        "between", "for", "per", "total", "reached", "measured", "estimated", "estimate", "est", "chapter", "section",
        "figure", "fig", "table", "page", "step", "article", "verse", "rule", "act", "art", "no", "number", "nr", "now",
        "new", "stable", "lts", "previous", "prior", "older", "newer", "major", "minor", "released", "named", "called",
        "series", "branch", "line", "channel", "build", "is", "it", "be", "has", "had", "have", "was", "were", "will",
    ]

    static func versions(in text: String) -> [Version] {
        let ns = text as NSString
        var out: [Int: [Int]] = [:]
        for (k, re) in versionPatterns.enumerated() {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let g = m.range(at: m.numberOfRanges - 1)
                let v = ns.substring(with: g)
                if k == 3 {
                    let name = ns.substring(with: m.range(at: 1)).lowercased()
                    if notProduct.contains(name) || common.contains(name) || function.contains(name) || name.count < 2 { continue }
                    if name.allSatisfy(\.isNumber) { continue }
                }
                let parts = v.split(separator: ".").compactMap { Int($0) }
                if k == 0, parts.count == 3, parts[2] >= 1900, parts[0] <= 31, parts[1] <= 12 { continue }  // 06.11.2026
                if out[g.location] == nil { out[g.location] = parts }
            }
        }
        return out.sorted { $0.key < $1.key }.map {
            Version(location: $0.key, parts: $0.value, name: productName(before: $0.key, in: ns), reference: referenced(before: $0.key, in: ns))
        }
    }

    static let versionWords: Set<String> = ["v", "ver", "version", "versions", "release", "releases", "update", "patch", "build", "edition"]

    /// The word naming the product before a version, in its sentence ("Neo4j 5.26.33", "the latest release of Neo4j is
    /// 2026.10.2", "FreeBSD 15.0-RELEASE"): the nearest earlier word within 48 characters that is not a function word,
    /// a version word, a month or a number.
    static func productName(before location: Int, in text: NSString) -> String? {
        let lo = max(0, location - 48)
        var seg = text.substring(with: NSRange(location: lo, length: location - lo)).lowercased()
        if let cut = seg.range(of: #"[.!?:;]\s|\n"#, options: [.regularExpression, .backwards]) { seg = String(seg[cut.upperBound...]) }
        var words = seg.split { !($0.isLetter || $0.isNumber || $0 == "+" || $0 == "#") }.map(String.init)
        if lo > 0, seg.count == location - lo, !words.isEmpty { words.removeFirst() }  // possibly cut
        while let w = words.last {
            if versionWords.contains(w) || w.allSatisfy(\.isNumber) || notProduct.contains(w) || common.contains(w)
                || function.contains(w) || months.contains(w) || monthAbbreviations.contains(w) || w.count < 2 || w.first?.isLetter != true {
                words.removeLast()
                continue
            }
            return w
        }
        return nil
    }
    static let monthAbbreviations: Set<String> = ["jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"]

    /// A passage version of the scope's product line: the same product word; a named scope and an unnamed heading
    /// ("15.0-RELEASE") with the same major and part count; never a named heading for an unnamed scope ("Go 1.27.3"
    /// on a Syncthing page, "logging 2.0.19" on a Jenkins changelog are other products).
    static func sameLine(_ scope: Version, _ head: Version) -> Bool {
        if let x = scope.name, let y = head.name { return x == y }
        if scope.name == nil, head.name != nil { return false }  // an unnamed scope says nothing about named products
        return scope.parts.count == head.parts.count && scope.parts.first == head.parts.first
    }

    /// One version is a prefix of the other (2026.10 and 2026.10.2; 2026.11.0 and 2026.11.1 — a trailing ".0" of a
    /// three-part version names the series; not 15.0 and 15.1).
    static func compatible(_ a: [Int], _ b: [Int]) -> Bool {
        let a = a.count >= 3 && a.last == 0 ? Array(a.dropLast()) : a, b = b.count >= 3 && b.last == 0 ? Array(b.dropLast()) : b
        let n = min(a.count, b.count)
        return n > 0 && Array(a.prefix(n)) == Array(b.prefix(n))
    }

    /// The versions the claim is about: its own, else the answer's subject version at that point. `context` = the
    /// answer up to the claim's marker. The candidates are the sentences before the claim on its line, then the earlier
    /// lines that head it: for a list item, lines that are not list items at its indent or deeper (a heading, a
    /// lead-in, a parent item); for prose, lines that are not list items. In a candidate sentence every dotted number
    /// counts once one version is named ("15.0/15.1").
    static func scopeVersions(_ claim: String, context: String) -> [Version] {
        let own = versions(in: normalize(claim))
        if !own.isEmpty { return own }
        let lines = removingMarkers(context).components(separatedBy: "\n")
        let item = try! NSRegularExpression(pattern: #"^(\s*)(?:[-*+•]|\d{1,3}[.)])\s"#)
        func listIndent(_ l: String) -> Int? {
            guard let m = item.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) else { return nil }
            return m.range(at: 1).length
        }
        let claimLine = lines.last ?? ""
        let claimIndent = listIndent(claimLine)
        var heads = [splitLast(claimLine).head]
        for l in lines.dropLast() {
            if let i = listIndent(l) {
                guard let c = claimIndent, i < c else { continue }
            }
            heads.append(l)
        }
        // order: earlier lines first, the claim's own line last
        let ordered = Array(heads.dropFirst()) + [heads[0]]
        let sentences = ordered.flatMap { splitSentences($0) }.map { normalize($0) }
        func all(_ s: String) -> [Version] {
            let named = versions(in: s)
            let ns = s as NSString
            let bare = try! NSRegularExpression(pattern: #"(?<![\d.])\d{1,4}(?:\.\d{1,4}){1,3}(?![\d]|\.\d)"#)
            let extra = bare.matches(in: s, range: NSRange(location: 0, length: ns.length))
                .filter { m in !named.contains { $0.location == m.range.location } }
                .map { Version(location: $0.range.location, parts: ns.substring(with: $0.range).split(separator: ".").compactMap { Int($0) },
                               name: productName(before: $0.range.location, in: ns)) }
            return named + extra
        }
        // the nearest earlier sentence naming a version; when it names several and the answer called one of them
        // the latest / current one before, that one
        guard let near = sentences.last(where: { !versions(in: $0).isEmpty || (recencyClaim($0) && !all($0).isEmpty) }) else { return [] }
        let set = all(near)
        if Set(set.map(\.parts)).count > 1, !recencyClaim(near),
           let subject = sentences.last(where: { recencyClaim($0) && !versions(in: $0).isEmpty }) {
            let latest = all(subject).filter { v in set.contains { $0.parts == v.parts } }
            if !latest.isEmpty { return latest }
        }
        return set
    }

    static func splitSentences(_ text: String) -> [String] {
        let ns = text as NSString
        var out: [String] = [], start = 0
        for m in boundary.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if ns.substring(with: NSRange(location: m.range.location, length: 1)) != "\n",
               endsAbbreviation(ns.substring(to: m.range.location + 1)) { continue }
            out.append(ns.substring(with: NSRange(location: start, length: NSMaxRange(m.range) - start)))
            start = NSMaxRange(m.range)
        }
        if start < ns.length { out.append(ns.substring(from: start)) }
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // MARK: Span

    /// Width of the window that locates the claim in the passage.
    static let spanWidth = 300

    /// The claim's spans in the passage: the `spanWidth` windows holding the most distinct content words of the claim
    /// (whole word or 5-letter stem), as (first, last) hit positions; empty when the claim has fewer than three such
    /// words or no window holds at least two of them and 40 % of them (the claim cannot be placed; the other checks
    /// decide).
    static func spans(_ claim: String, passage: String) -> [(first: Int, last: Int)] {
        let words = Array(Set(claim.lowercased().split { !($0.isLetter || $0 == "'" || $0 == "-") }.map(String.init)
            .filter { $0.count >= 4 && !function.contains($0) && !common.contains($0) }))
        guard words.count >= 3 else { return [] }  // two words place a claim anywhere on a long page
        let pns = passage as NSString
        var hits: [(pos: Int, word: Int)] = []
        for (k, w) in words.enumerated() {
            let stem = w.count > 5 ? String(w.prefix(5)) : w
            guard let re = try? NSRegularExpression(pattern: #"(?<![a-z])"# + NSRegularExpression.escapedPattern(for: stem)) else { continue }
            for m in re.matches(in: passage, range: NSRange(location: 0, length: pns.length)) { hits.append((m.range.location, k)) }
        }
        hits.sort { $0.pos < $1.pos }
        let need = max(2, Int((Double(words.count) * 0.4).rounded(.up)))
        var top: [(count: Int, first: Int, last: Int)] = []
        var lo = 0
        var counts: [Int: Int] = [:]
        for hi in hits.indices {
            counts[hits[hi].word, default: 0] += 1
            while hits[hi].pos - hits[lo].pos > spanWidth {
                counts[hits[lo].word]! -= 1
                if counts[hits[lo].word] == 0 { counts[hits[lo].word] = nil }
                lo += 1
            }
            let best = top.first?.count ?? 0
            if counts.count > best { top = [(counts.count, hits[lo].pos, hits[hi].pos)] }
            else if counts.count == best, best > 0, let last = top.last, hits[lo].pos > last.last { top.append((counts.count, hits[lo].pos, hits[hi].pos)) }
        }
        guard let first = top.first, first.count >= need else { return [] }
        return top.map { ($0.first, $0.last) }
    }

    // MARK: Entity level

    /// Entity levels a figure or rank can belong to; a sentence's level must be the one its source ties the figure to.
    static let levels: [(String, [String])] = [
        ("city", ["city", "cities", "town", "municipality", "municipal", "commune", "proper"]),
        ("metro", ["metropolitan", "metro", "metropolis", "urban", "agglomeration", "conurbation"]),
        ("county", ["county", "counties"]), ("region", ["region", "regions", "regional"]),
        ("province", ["province", "provinces", "provincial"]), ("district", ["district", "districts"]),
        ("department", ["department", "departement"]), ("country", ["country", "countries", "nationwide"]),
    ]
    static let rank = try! NSRegularExpression(pattern:
        #"\b(?:(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|\d{1,2}(?:st|nd|rd|th))[\s-]+)?(?:most[\s-]+(populous|populated|visited)|(largest|biggest|smallest|busiest))\b"#,
        options: [.caseInsensitive])
    static let ordinalWords = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]

    struct Rank: Equatable {
        var order: Int
        var word: String
        var level: String?
        /// The level word follows the rank ("sixth-most populous city").
        var bound = false
    }

    /// The ranks of a text ("sixth-most populous", "second-largest", "7th most populous city") with the level each is
    /// bound to: a level word within the next two words, else the nearest level word before it in its sentence.
    static func ranks(in text: String) -> [Rank] {
        let ns = text as NSString
        return rank.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            var order = 1
            if m.range(at: 1).location != NSNotFound {
                let o = ns.substring(with: m.range(at: 1)).lowercased()
                order = (ordinalWords.firstIndex(of: o).map { $0 + 1 }) ?? Int(o.prefix { $0.isNumber }) ?? 1
            }
            let word = (m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ns.substring(with: m.range(at: 3))).lowercased()
            let after = ns.substring(with: NSRange(location: NSMaxRange(m.range), length: min(40, ns.length - NSMaxRange(m.range)))).lowercased()
            let next = after.split { !($0.isLetter || $0 == "-") }.prefix(2).map(String.init)
            var level = levels.first { l in next.contains { l.1.contains($0) } }?.0
            let bound = level != nil
            if level == nil {
                let lo = max(0, m.range.location - 200)
                var before = ns.substring(with: NSRange(location: lo, length: m.range.location - lo)).lowercased()
                if let cut = before.range(of: #"[.!?]\s|\n"#, options: [.regularExpression, .backwards]) { before = String(before[cut.upperBound...]) }
                var best = -1
                for (l, forms) in levels {
                    for f in forms {
                        if let r = before.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: f) + #"\b"#, options: [.regularExpression, .backwards]) {
                            let pos = before.distance(from: before.startIndex, to: r.lowerBound)
                            if pos > best { best = pos; level = l }
                        }
                    }
                }
            }
            return Rank(order: order, word: word, level: level, bound: bound)
        }
    }

    // MARK: Check

    /// A claim naming its version, stated next to that version in the passage (its content words within 400
    /// characters of an occurrence): the version check is satisfied there.
    static func anchoredAtOwnVersion(_ claim: String, passage: String) -> Bool {
        let own = dotted(in: normalize(claim))
        guard !own.isEmpty else { return false }
        let pns = passage as NSString
        for v in dotted(in: passage) where own.contains(where: { $0.parts == v.parts }) {
            let lo = max(0, v.location - 400), hi = min(pns.length, v.location + 400)
            if !spans(claim, passage: pns.substring(with: NSRange(location: lo, length: hi - lo))).isEmpty { return true }
        }
        return false
    }

    /// M7 at248: "<product> <major>" in a passage (no dotted part: "macOS 27 Experience the new Siri AI") for a product
    /// whose dotted versions the passage lists — the heading of that series; not a reference point.
    static func seriesHeadings(in passage: String, products: Set<String>) -> [Version] {
        guard !products.isEmpty else { return [] }
        let ns = passage as NSString
        var out: [Version] = []
        for p in products {
            guard let re = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: p) + #"\s(\d{1,4})(?![\d]|\.\d|\s*(?:%|percent))"#,
                                                    options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: passage, range: NSRange(location: 0, length: ns.length)) {
                let g = m.range(at: 1)
                guard let n = Int(ns.substring(with: g)), !referenced(before: g.location, in: ns) else { continue }
                out.append(Version(location: g.location, parts: [n], name: p))
            }
        }
        return out
    }

    /// The scope details the passage does not back ("version", "level <x>").
    static func scopeLack(_ claim: String, passage: String, context: String) -> [String] {
        var lack: [String] = []
        // version
        let pv = versions(in: passage).filter { !$0.reference }
        let places = spans(claim, passage: passage)
        if Set(pv.map(\.parts)).count >= 2, !places.isEmpty, !anchoredAtOwnVersion(claim, passage: passage) {
            // a scope version without a product word takes the word the passage gives it ("Jenkins 2.580.2")
            let scope = scopeVersions(claim, context: context).map { v in
                var v = v
                if v.name == nil { v.name = pv.first { $0.parts == v.parts && $0.name != nil }?.name }
                return v
            }
            let rivals = pv.filter { h in scope.contains { sameLine($0, h) } }
            // a bare series number compatible with the scope ("major changes in 2.1") also heads a span
            let series = dotted(in: passage).filter { d in !d.reference && scope.contains { compatible($0.parts, d.parts) } }
            // M7 at248: a series heading with the product word and a bare major ("macOS 27" over "Introducing Siri AI",
            // after a "macOS 27.0.1" entry) heads its span too — before, the dotted entry above it was read as the heading
            // (only a heading compatible with the scope: an other-major one was measured to cost supported sentences)
            let majors = seriesHeadings(in: passage, products: Set(rivals.compactMap(\.name)))
                .filter { h in scope.contains { compatible($0.parts, h.parts) } }
            let heads = (rivals + series + majors).sorted { $0.location < $1.location }
            if !scope.isEmpty, !rivals.isEmpty {
                let fits = places.contains { place in
                    let before = heads.last { $0.location <= place.first && place.first - $0.location <= 2000 }
                    let inside = heads.filter { $0.location > place.first && $0.location <= place.last }
                    let over = (before.map { [$0] } ?? []) + inside
                    return over.isEmpty || over.contains { h in scope.contains { compatible($0.parts, h.parts) } }
                }
                if !fits { lack.append("version") }
            }
        }
        // entity level of a rank
        for r in ranks(in: normalize(claim)) where r.bound || r.word == "populous" || r.word == "populated" {
            guard let level = r.level else { continue }
            let occ = ranks(in: passage).filter { $0.order == r.order && $0.word == r.word }
            guard !occ.isEmpty else { continue }  // a rank the passage does not state: coverage / entailment decide
            if !occ.contains(where: { $0.level == nil || $0.level == level }) { lack.append("level \(level)") }
        }
        return lack
    }
}
