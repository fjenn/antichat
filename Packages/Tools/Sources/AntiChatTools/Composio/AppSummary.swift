// The one line under an app the bundled catalogue has no hand-written summary for: derived from Composio's
// description with the rules of `generated_summary` in tools/composio/build-catalog.py (the first sentence, without
// the app's name, "is a", filler adjectives and trailing clauses; at most 45 characters, cut at a word boundary,
// no joining word or full stop at the end, first letter upper case). "" = nothing usable.
import Foundation

public enum AppSummary {
    public static let limit = 45

    private static let dangling: Set<String> = [
        "and", "or", "for", "to", "with", "of", "in", "on", "the", "a", "an", "by", "that", "which", "from", "as", "at",
        "your", "their", "its", "is", "are", "via", "into", "through", "using", "such", "like", "including", "other", "&",
        "-", "it", "you", "can", "who", "where", "when", "while", "across", "between", "within",
    ]
    private static let brandLead = #"^[^,.;:]{1,40}?\s+(?=(?:is|are|provides|offers|delivers|enables|allows|lets|helps)\s)"#
    private static let lead = #"^(?:(?:is|are|provides?|offers?|delivers?|enables?|allows?|lets?|helps?|gives?)\s+)"#
        + #"(?:(?:users?|you|businesses|teams|developers|companies|organizations|customers)\s+(?:to\s+)?)?(?:(?:the|a|an)\s+)?"#
    private static let filler = #"^(?:(?:the|a|an)\s+)?(?:(?:powerful|leading|comprehensive|popular|modern|simple|robust|flexible|"#
        + #"all-in-one|cloud-based|cloud based|online|web-based|ai-powered|ai powered|open-source|open source|versatile|"#
        + #"user-friendly|unified|complete|innovative)[\s,]+)*"#
    private static let clause = #"\s+(?:that|which|designed to|built to|enabling|allowing|offering|providing|featuring|helping)\s+"#
    private static let breakAt = #"[;:(—–]| - "#

    public static func derive(name: String, description: String) -> String {
        var s = firstSentence(description)
        let low = s.lowercased()
        let plain = name.lowercased()
        let prefixes = [plain, String(plain.unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) })]
        if let p = prefixes.first(where: { !$0.isEmpty && low.hasPrefix($0) && low.count == s.count }) {
            s = String(s.dropFirst(p.count))
            for possessive in ["'s ", "’s "] where s.hasPrefix(possessive) { s = String(s.dropFirst(2)) }
            s = String(s.drop { " ,:-–—".contains($0) })
        } else if let r = s.range(of: brandLead, options: .regularExpression) {
            // "<Brand words> is a ..." where the brand is spelled differently from the listed name.
            s = String(s[r.upperBound...])
        }
        s = removing(#"^\([^)]*\)\s*"#, from: s)
        s = removing(lead, from: s, caseInsensitive: true)
        s = removing(filler, from: s, caseInsensitive: true)
        if s.count > limit { s = before(clause, in: s) }
        if s.count > limit { s = before(breakAt, in: s) }
        s = clip(s)
        if s.count < 8 { s = clip(firstSentence(description)) }
        return s.isEmpty ? "" : s.prefix(1).uppercased() + s.dropFirst()
    }

    /// The text up to its first full stop, question or exclamation mark that ends a word; whitespace collapsed.
    static func firstSentence(_ text: String) -> String {
        let t = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let s = t.range(of: #"^.+?[.!?](?=\s|$)"#, options: .regularExpression).map { String(t[$0]) } ?? t
        return trimmingEnd(s, ".!? ")
    }

    /// `text` cut at a word boundary to at most `limit` characters, without a dangling joining word.
    static func clip(_ text: String, limit: Int = AppSummary.limit) -> String {
        let t = trimmingEnd(text.trimmingCharacters(in: .whitespacesAndNewlines), ".,;:!? ")
        if t.count <= limit { return t }
        var cut = String(t.prefix(limit + 1))
        cut = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(t.prefix(limit))
        var words = cut.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        while words.count > 1, let last = words.last,
              dangling.contains(last.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))) {
            words.removeLast()
        }
        var kept = words.joined(separator: " ")
        // A list cut in the middle ("…ideas, manage") ends at its last whole item.
        if let comma = kept.lastIndex(of: ","), kept[kept.index(after: comma)...].split(separator: " ").count <= 2,
           kept[..<comma].count >= 12 {
            kept = String(kept[..<comma])
        }
        return trimmingEnd(kept, ".,;:!?-&/ ")
    }

    private static func trimmingEnd(_ s: String, _ characters: String) -> String {
        var s = Substring(s)
        while let c = s.last, characters.contains(c) { s.removeLast() }
        return String(s)
    }

    private static func removing(_ pattern: String, from s: String, caseInsensitive: Bool = false) -> String {
        let options: String.CompareOptions = caseInsensitive ? [.regularExpression, .caseInsensitive] : .regularExpression
        guard let r = s.range(of: pattern, options: options), !r.isEmpty else { return s }
        return String(s[r.upperBound...])
    }

    private static func before(_ pattern: String, in s: String) -> String {
        s.range(of: pattern, options: .regularExpression).map { String(s[..<$0.lowerBound]) } ?? s
    }
}
