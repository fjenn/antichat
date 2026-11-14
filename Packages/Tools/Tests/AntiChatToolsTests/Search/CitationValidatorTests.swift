// M7.T03 (AT-250 c1, R-250 AC1): pills only for fetched sources; invalid and unfetched indices are dropped.
@testable import AntiChatTools
import Foundation
import Testing

struct CitationValidatorTests {
    static func src(_ n: Int, _ fetched: Bool) -> WebSource {
        WebSource(n: n, url: "https://s\(n).test/", title: "S\(n)", site: "s\(n).test", date: nil, snippet: "", fetched: fetched)
    }
    static let sources = (1...9).map { src($0, $0 <= 4) }

    @Test func onlyFetchedIndicesBecomePills() {
        let r = CitationValidator.validate("A [1]. B [2,7]. C [9]. D [3][4]. E [12].", sources: Self.sources)
        #expect(r.text == "A [1]. B [2]. C . D [3][4]. E .")
        #expect(r.citations.map(\.sources) == [[1], [2], [3], [4]])
        #expect(r.dropped == 3)
        #expect(r.citations.allSatisfy { c in c.sources.allSatisfy { n in Self.sources[n - 1].fetched } })
    }

    @Test func everyRenderedPillMapsToAFetchedSourceAcrossRandomAnswers() {
        var g = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let answer = (0..<8).map { _ in "x [\(Int.random(in: 0...12, using: &g))]" }.joined(separator: " ")
            let r = CitationValidator.validate(answer, sources: Self.sources)
            #expect(r.citations.flatMap(\.sources).allSatisfy { (1...4).contains($0) })
        }
    }

    @Test func plainBracketsWithoutNumbersStay() {
        let r = CitationValidator.validate("array[i] and [note] stay", sources: Self.sources)
        #expect(r.text == "array[i] and [note] stay" && r.citations.isEmpty)
    }

    /// M7.T16 review #2: markers inside fenced or inline code are code, never pills and never dropped.
    @Test func markersInCodeAreLeftAsWritten() {
        let t = "Use `arr[1]` here [2].\n\n```python\nx = arr[0] + arr[3]\n```\nDone [4]."
        let r = CitationValidator.validate(t, sources: Self.sources)
        #expect(r.text == t)
        #expect(r.citations.map(\.sources) == [[2], [4]] && r.dropped == 0)
    }
}
