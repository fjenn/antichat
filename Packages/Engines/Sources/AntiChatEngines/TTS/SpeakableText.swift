// M3.T07 step 1 (R-054 AC2, R-282 "Markdown never spoken"; P-media-04): what the synthesiser may hear. The vendored
// osaurus `MarkdownStripper` does the inline work (headings, quotes, list markers, emphasis, links, inline code); our
// patch around it: each fenced code block becomes one sentence `voice.codeOmitted` ("code omitted", R-054 AC2
// verbatim — the app passes the localized phrase in `Speak.codeOmitted`), Markdown tables are skipped silently (the
// copy deck has no "table omitted"), bare URLs become their host, and the symbols `*` `#` `` ` `` `|` `>` never reach
// the synthesiser (a final scan replaces any that survive).
import Foundation
import OsaurusVendored

public enum SpeakableText {
    public static let defaultCodeOmitted = "code omitted"
    /// Characters that must never be spoken (unit-tested with a symbol scan).
    public static let forbidden: Set<Character> = ["*", "#", "`", "|", ">"]

    public static func from(markdown: String, codeOmitted: String = defaultCodeOmitted) -> String {
        var t = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let omitted = codeOmitted.hasSuffix(".") ? codeOmitted : codeOmitted + "."
        // Fenced code (``` or ~~~, closed or still open at the end of a streamed reply) → one sentence each.
        t = replace(#"(?m)^[ \t]{0,3}(```|~~~)[^\n]*\n[\s\S]*?(?:^[ \t]{0,3}\1[ \t]*$|\z)"#, in: t, with: "\n\n" + omitted + "\n\n")
        // Tables: a header row, its |---| separator and the body rows.
        t = replace(#"(?m)^[ \t]*\|.*\|[ \t]*$\n?"#, in: t, with: "")
        t = replace(#"(?m)^[ \t]*:?-{3,}:?(?:[ \t]*\|[ \t]*:?-{3,}:?)+[ \t]*$\n?"#, in: t, with: "")
        // Links keep their text (MarkdownStripper); bare URLs → host.
        t = replace(#"\[([^\]]+)\]\((?:[^()]|\([^)]*\))*\)"#, in: t, with: "$1")
        t = hosts(t)
        t = MarkdownStripper.plainText(from: t)
        t = String(t.map { forbidden.contains($0) ? " " : $0 })
        t = replace(#"[ \t]+"#, in: t, with: " ")
        t = replace(#" +([.,;:!?])"#, in: t, with: "$1")
        t = replace(#"\n{3,}"#, in: t, with: "\n\n")
        return t.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `https://www.example.com/a/b?c` → `example.com`.
    static func hosts(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\b(?:https?://|www\.)[^\s<>()\]]+"#) else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: s) else { continue }
            var raw = String(s[r])
            while let last = raw.last, ".,;:!?".contains(last) { raw.removeLast() }
            let url = URL(string: raw.hasPrefix("www.") ? "https://" + raw : raw)
            var host = url?.host ?? raw
            if host.hasPrefix("www.") { host.removeFirst(4) }
            let trail = String(s[r].dropFirst(raw.count))
            out.replaceSubrange(Range(m.range, in: out)!, with: host + trail)
        }
        return out
    }

    static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
