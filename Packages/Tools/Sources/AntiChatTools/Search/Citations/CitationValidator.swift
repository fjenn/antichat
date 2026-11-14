// M7.T03 step 7 (R-250 AC1): `[n]` / `[n,m]` / `[n][m]` in the answer become citation pills only when `n` is a source
// with `fetched == true`. Other indices are dropped from the rendered text and counted (logged without content).
// Markers inside fenced or inline code are left as written (code, not citations).
import Foundation

public struct Citation: Sendable, Equatable {
    /// The cited source numbers (each fetched).
    public var sources: [Int]
    /// Range of the marker in the cleaned text (UTF-16 offsets), where the pill is drawn.
    public var location: Int
}

public enum CitationValidator {
    public struct Result: Sendable, Equatable {
        public var text: String
        public var citations: [Citation]
        public var dropped: Int
    }

    static let marker = try! NSRegularExpression(pattern: #"\[(\d{1,3}(?:\s*,\s*\d{1,3})*)\]"#)

    public static func validate(_ answer: String, sources: [WebSource]) -> Result {
        let fetched = Set(sources.filter(\.fetched).map(\.n))
        let ns = answer as NSString
        var out = "", cursor = 0, citations: [Citation] = [], dropped = 0
        let all = NSRange(location: 0, length: ns.length)
        // M7.T16 review #2: `arr[1]` / `[0, 1]` inside fenced or inline code is code: never a pill, never dropped.
        let code = answer.contains("`") ? CitationGrounding.code.matches(in: answer, range: all).map(\.range) : []
        for m in marker.matches(in: answer, range: all) where !code.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            cursor = m.range.location + m.range.length
            let nums = ns.substring(with: m.range(at: 1)).split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let ok = nums.filter { fetched.contains($0) }
            dropped += nums.count - ok.count
            guard !ok.isEmpty else { continue }
            citations.append(Citation(sources: ok, location: (out as NSString).length))
            out += "[" + ok.map(String.init).joined(separator: ",") + "]"
        }
        out += ns.substring(from: cursor)
        return Result(text: out, citations: citations, dropped: dropped)
    }
}
