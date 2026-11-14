// M7 verifier (AT-248 c1, retrieval quality; generic by query intent, never by product): a question about the latest /
// current version of something is only answerable with a citation when a fetched page says in words which version is
// the latest (the citation checks never back "X is the latest" from an undated list). For such a step:
//   1. one more query goes out: the step's first recency query with its recency word swapped (latest ↔ current), so
//      pages phrased the other way ("Which macOS is the latest?", "current version") are among the candidates; a
//      year in it is dropped there (M7 final: the recency word already asks for the newest, and a year pulls in dated
//      round-ups instead of the pages that state the current version — live, "latest macOS version 2026" left Apple's
//      "Find out which macOS your Mac is using" out of the first 8 results, "current macOS version" ranks it 3rd–4th);
//   2. results whose title or snippet state which version is the latest/current ("X is the latest version of Y",
//      "Which Y is the latest?", "latest versions of each …") move into the fetched window (at most `promoteLimit`),
//      ahead of the window's last results that do not.
// Nothing is filtered (D-005): every result stays in the list, only the order of the fetched window changes.
import Foundation
import OsaurusVendored

public enum SearchRecency {
    static let recency = #"latest|newest|current|most recent|up-to-date"#
    static let intent = try! NSRegularExpression(
        pattern: #"\b(?:\#(recency))\b[^.?!]{0,40}\b(?:version|release|update|build)s?\b|\b(?:version|release|update|build)s?\b[^.?!]{0,30}\b(?:\#(recency))\b|\bwhat\s+version\b"#,
        options: [.caseInsensitive])
    static let states = try! NSRegularExpression(pattern: [
        #"\b(?:which|what)\b[^.?!]{0,60}\b(?:is|are)\s+(?:the\s+)?(?:\#(recency))\b"#,
        #"\b(?:is|are)\s+the\s+(?:\#(recency))\s+(?:major\s+|stable\s+|public\s+)?(?:version|release|update)s?\b"#,
        #"\b(?:\#(recency))\s+(?:stable\s+|major\s+)?(?:version|release)s?\s+(?:is|are|of)\b"#,
    ].joined(separator: "|"), options: [.caseInsensitive])
    public static let promoteLimit = 2

    /// The step asks for the latest / current version of something.
    public static func asksLatest(_ queries: [String]) -> Bool {
        queries.contains { intent.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
    }

    static let year = try! NSRegularExpression(pattern: #"\s*\b(?:in\s+|of\s+|for\s+)?(?:19|20)\d\d\b"#, options: [.caseInsensitive])

    /// The queries plus one with the first recency query's recency word swapped and any year dropped (none when that
    /// one is already there).
    public static func queries(_ qs: [String]) -> [String] {
        guard let q = qs.first(where: { asksLatest([$0]) }) else { return qs }
        let swap = try! NSRegularExpression(pattern: #"\b(latest|newest|most recent|current)\b"#, options: [.caseInsensitive])
        let ns = q as NSString
        guard let m = swap.firstMatch(in: q, range: NSRange(location: 0, length: ns.length)) else { return qs }
        let word = ns.substring(with: m.range).lowercased()
        let swapped = ns.replacingCharacters(in: m.range, with: word == "current" ? "latest" : "current")
        let variant = year.stringByReplacingMatches(in: swapped, range: NSRange(location: 0, length: (swapped as NSString).length),
                                                    withTemplate: "").trimmingCharacters(in: .whitespaces)
        return qs.contains { $0.caseInsensitiveCompare(variant) == .orderedSame } ? qs : qs + [variant]
    }

    /// The result's title or snippet states which version is the latest / current.
    public static func statesLatest(_ hit: SearchHit) -> Bool {
        let t = hit.title + ". " + hit.snippet
        return states.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil
    }

    /// Moves up to `limit` results past the first `window` that state the latest version into the window, each in
    /// place of the window's last result that does not; every result is kept.
    public static func promote(_ hits: [SearchHit], window: Int, limit: Int = promoteLimit) -> [SearchHit] {
        guard hits.count > window, window > 0 else { return hits }
        var head = Array(hits.prefix(window)), tail = Array(hits.dropFirst(window))
        var moved = 0
        while moved < limit, let i = tail.firstIndex(where: statesLatest),
              let j = head.lastIndex(where: { !statesLatest($0) }) {
            let out = head.remove(at: j)
            head.append(tail.remove(at: i))
            tail.insert(out, at: 0)
            moved += 1
        }
        return head + tail
    }
}
