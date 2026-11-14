// M9.T05 (AT-254 T3, A-M9-T05b follow-up): sub-queries for a multi-part question, written by rules (no model step).
// On the direct-search tiers the harness searches with the user's message; a question about two things ("the ECB and
// the US Federal Reserve", "Who won … and what was it awarded for?") then found pages for one of them only (10
// hand-written multi-part questions at T3: 8/10 with ≥ 2 pills and 3.8 pills mean, against 9/10 and 5.9 when the 35B
// model wrote the queries at ≈ 3 s more first-token time). The sub-queries go out with the message in the same
// `web_search` step, in parallel (the broker races every query at once and interleaves their hits), so the step takes
// no longer. Rules, in order (at most `max` sub-queries; the message stays the first query):
//   1. Two names joined by and / or / vs / versus ("Lyon and Marseille", "iPhone 17 and the Pixel 10", "macOS and
//      iOS") in a question about several things (a plural or comparison word): the message once with each name in
//      place of the pair.
//   2. Clauses joined by ", and" / "; " / "and" before a question word ("… Physics and what was it awarded for?"):
//      each clause; a clause that refers back (it, they, its, …) gets the first clause's content words appended.
// Only the user's own words are used (no added personal data). A single-part question yields no sub-queries.
import Foundation

public enum SearchQuerySplit {
    static let questionWords: Set<String> = ["what", "when", "which", "who", "whom", "whose", "where", "why", "how", "is", "are",
                                             "was", "were", "does", "do", "did", "will", "can", "has", "have"]
    static let backReferences: Set<String> = ["it", "its", "they", "their", "them", "he", "his", "she", "her", "this", "these",
                                              "those", "that", "there"]
    static let stopwords: Set<String> = ["the", "a", "an", "of", "in", "on", "for", "to", "and", "or", "is", "are", "was", "were",
                                         "what", "when", "which", "who", "whom", "whose", "where", "why", "how", "does", "do",
                                         "did", "will", "can", "has", "have", "with", "about", "from", "by", "at", "as", "be",
                                         "what's", "who's", "compare", "tell", "me", "please"]
    static let joiners: Set<String> = ["and", "or", "vs", "vs.", "versus"]

    /// Sub-queries of `message` (not including it), at most `max`.
    public static func subQueries(_ message: String, max: Int) -> [String] {
        guard max > 0 else { return [] }
        let text = message.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= SearchPlan.maxQueryLength else { return [] }
        var out = names(text)
        if out.isEmpty { out = clauses(text) }
        var seen: Set<String> = [normal(text)], kept: [String] = []
        for q in out where seen.insert(normal(q)).inserted && !q.isEmpty {
            kept.append(q)
            if kept.count == max { break }
        }
        return kept
    }

    static func normal(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }

    /// A token that reads as a name: any capital letter or digit ("Lyon", "macOS", "ECB", "17", "3.14").
    static func nameLike(_ t: Substring) -> Bool {
        let w = t.trimmingCharacters(in: .punctuationCharacters)
        return !w.isEmpty && w.contains { $0.isUppercase || $0.isNumber }
    }

    static let pairCues: Set<String> = ["compare", "compared", "comparison", "vs", "vs.", "versus", "between", "both", "difference", "differences"]
    static let notPlural: Set<String> = ["is", "was", "has", "does", "us", "its", "this", "his", "news", "series", "status", "always", "less"]

    /// The question asks about several things: a plural word ("rates", "versions", "populations") or a comparison
    /// word, so "Who wrote War and Peace?" (one title) is not split.
    static func asksForMany(_ tokens: [Substring]) -> Bool {
        tokens.contains { t in
            let w = t.trimmingCharacters(in: .punctuationCharacters).lowercased()
            guard !w.isEmpty, w == t.trimmingCharacters(in: .punctuationCharacters) || pairCues.contains(w) else { return false }
            return pairCues.contains(w) || (w.count > 3 && w.hasSuffix("s") && !w.hasSuffix("ss") && !notPlural.contains(w))
        }
    }

    /// Rule 1: "<name> and [the] <name>" → the message with each name in place of the pair.
    static func names(_ text: String) -> [String] {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true)
        guard asksForMany(tokens) else { return [] }
        for (j, t) in tokens.enumerated() where j > 0 && joiners.contains(t.lowercased()) {
            // the name run ending right before the joiner (no comma inside it)
            var a = j - 1
            guard nameLike(tokens[a]), !tokens[a].hasSuffix(",") else { continue }
            while a > 0, nameLike(tokens[a - 1]), !tokens[a - 1].hasSuffix(",") { a -= 1 }
            // the name run after it, an article allowed first
            var b = j + 1
            if b < tokens.count, ["the", "a", "an"].contains(tokens[b].lowercased()) { b += 1 }
            guard b < tokens.count, nameLike(tokens[b]) else { continue }
            var e = b
            while e + 1 < tokens.count, nameLike(tokens[e + 1]), !tokens[e].hasSuffix(",") && !tokens[e].hasSuffix("?") { e += 1 }
            // the second name keeps the punctuation that closed the pair (", and when …", "?")
            let left = tokens[..<a].joined(separator: " "), right = tokens[(e + 1)...].joined(separator: " ")
            let first = tokens[a..<j].joined(separator: " ")
            let secondRaw = tokens[b...e].joined(separator: " ")
            let trail = String(secondRaw.reversed().prefix { $0.isPunctuation }.reversed())
            let second = String(secondRaw.dropLast(trail.count))
            func join(_ name: String) -> String {
                [left, name + trail, right].filter { !$0.isEmpty }.joined(separator: " ")
            }
            return [join(first), join(second)]
        }
        return []
    }

    /// Rule 2: clauses joined before a question word.
    static func clauses(_ text: String) -> [String] {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var parts: [[String]] = [[]]
        for (i, t) in tokens.enumerated() {
            let next = i + 1 < tokens.count ? tokens[i + 1].lowercased() : ""
            let prevEndsClause = parts[parts.count - 1].last.map { $0.hasSuffix(",") || $0.hasSuffix(";") || $0.hasSuffix("?") } ?? false
            if t.lowercased() == "and", questionWords.contains(next), !parts[parts.count - 1].isEmpty {
                parts.append([])
                continue
            }
            if prevEndsClause, questionWords.contains(t.lowercased()), !parts[parts.count - 1].isEmpty {
                parts.append([t])
                continue
            }
            parts[parts.count - 1].append(t)
        }
        let clauses = parts.map { $0.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",;?. ")) }
            .filter { $0.split(separator: " ").count >= 2 }
        guard clauses.count >= 2 else { return [] }
        let topic = clauses[0].split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && !stopwords.contains($0.lowercased()) }.joined(separator: " ")
        return clauses.enumerated().map { i, c in
            let refers = c.split(separator: " ").contains { backReferences.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
            return i > 0 && refers && !topic.isEmpty ? "\(c) \(topic)" : c
        }
    }
}
