// SettingsSearch (components §6 SettingsSidebar "search results"): the Settings window's search field over
// `SettingsRegistry`. Word-based and forgiving: every word of the query (minus filler like "my" or "the") must start
// a word of the row's title, its one-line description or its synonyms ("delete my chats" finds "Delete all chats").
// Rows on the page come first. A row inside a page's Advanced group is listed only when nothing on a page matches, or
// when the query names it (most of its title's words) — so "model" does not list a dozen developer rows.
import AntiChatDesign
import Foundation

public enum SettingsSearch {
    /// Words that carry no meaning in a settings query.
    static let stopWords: Set<String> = [
        "a", "an", "the", "my", "me", "i", "to", "of", "for", "in", "on", "at", "is", "it", "and", "or", "do", "does",
        "how", "can", "where", "what", "please", "change", "set", "setting", "settings", "option", "options",
    ]
    static let limit = 8

    /// Rows matching `query`, best first (empty query: none).
    public static func results(_ query: String, rows: [SettingsRowSpec] = SettingsRegistry.rows) -> [SettingsRowSpec] {
        let all = words(query)
        guard !all.isEmpty else { return [] }
        let meaningful = all.filter { !stopWords.contains($0) }
        let tokens = meaningful.isEmpty ? all : meaningful

        struct Hit { let row: SettingsRowSpec; let score: Int; let named: Bool; let order: Int }
        var hits: [Hit] = []
        for (order, row) in rows.enumerated() {
            let title = words(row.label.string())
            let synonyms = row.keywords.flatMap(words)
            let note = row.note.map { words($0.string()) } ?? []
            let page = words(row.section.title.string())
            var score = 0, inTitle = 0, onlyPage = true, matched = true
            for t in tokens {
                let best = max(strength(t, title) * 4, strength(t, synonyms) * 2, strength(t, note))
                if best > 0 {
                    score += best
                    onlyPage = false
                    if strength(t, title) > 0 { inTitle += 1 }
                } else if strength(t, page) > 0 {
                    score += 1
                } else {
                    matched = false
                    break
                }
            }
            guard matched, !onlyPage else { continue }
            // "Named": every query word is in the title and they cover most of it ("keep models loaded", "safe search").
            let titleWords = title.filter { !stopWords.contains($0) }.count
            let named = inTitle == tokens.count && inTitle * 3 >= max(1, titleWords) * 2
            hits.append(Hit(row: row, score: score + (named ? 8 : 0), named: named, order: order))
        }
        let onPage = hits.filter { !$0.row.advanced }
        let shown = onPage.isEmpty ? hits : hits.filter { !$0.row.advanced || $0.named }
        return shown.sorted { a, b in
            if a.row.advanced != b.row.advanced { return !a.row.advanced }
            return a.score != b.score ? a.score > b.score : a.order < b.order
        }
        .prefix(limit).map(\.row)
    }

    /// Lower-cased words, without accents or punctuation.
    static func words(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// How well `token` matches any of `words`: 4 the word itself, 3 its singular or plural, 2 its start, 1 one typo
    /// away (longer words only: "model" is not "mode"), 0 none.
    static func strength(_ token: String, _ words: [String]) -> Int {
        var best = 0
        for w in words {
            if w == token { return 4 }
            if stem(w) == stem(token) {
                best = max(best, 3)
            } else if w.hasPrefix(token) || (token.count >= 4 && w.hasPrefix(stem(token))) {
                best = max(best, 2)
            } else if best == 0, token.count >= 6, abs(w.count - token.count) <= 1, oneEditApart(token, w) {
                best = 1
            }
        }
        return best
    }

    /// "chats" → "chat", "memories" → "memory" (enough for English settings words).
    static func stem(_ w: String) -> String {
        if w.count > 4, w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
        if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { return String(w.dropLast()) }
        return w
    }

    /// One letter changed, added or missing.
    static func oneEditApart(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        let (s, l) = x.count <= y.count ? (x, y) : (y, x)
        var i = 0, j = 0, edits = 0
        while i < s.count, j < l.count {
            if s[i] == l[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if s.count == l.count { i += 1 }
            j += 1
        }
        return edits + (l.count - j) + (s.count - i) <= 1
    }
}
