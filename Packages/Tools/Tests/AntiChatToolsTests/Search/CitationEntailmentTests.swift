// AT-250 c2 (A-M7-T03c): the per-sentence entailment check at finalize (scorer stubbed; the model runs in the helper).
@testable import AntiChatTools
import Foundation
import Testing

@Suite struct CitationEntailmentTests {
    let ev = [1: "The museum opened in 1902 and has 40 rooms.", 2: "Snippet: the museum is closed on Mondays.", 3: "Unrelated page."]

    /// Scores 0.9 when the premise contains `needle` from the claim's last word, else 0.1.
    static func stub(_ supported: [String: Set<Int>], evidence: [Int: String]) -> CitationEntailment.Scorer {
        { pairs in
            pairs.map { p in
                let ok = supported.contains { key, ns in p.claim.contains(key) && ns.contains { evidence[$0] == p.premise } }
                return ok ? 0.9 : 0.1
            }
        }
    }

    @Test func unsupportedSourcesLeaveTheMarkerAndSupportedOnesStay() async {
        let t = "The museum opened in 1902 [1]. It is closed on Mondays [1,2]. It has a famous café [3]."
        let r = await CitationEntailment.apply(t, evidence: ev, scorer: Self.stub(["1902": [1], "Mondays": [2]], evidence: ev))
        #expect(r.text == "The museum opened in 1902 [1]. It is closed on Mondays [2]. It has a famous café.")
        #expect(r.checked == 3 && r.uncited == 1 && r.narrowed == 1 && r.pairs == 4 && r.skipped == nil)
    }

    @Test func oneBatchedRequestPerAnswer() async {
        let calls = Counter()
        let scorer: CitationEntailment.Scorer = { pairs in calls.add(); return pairs.map { _ in 0.8 } }
        let t = "The museum opened in 1902 [1]. It has 40 rooms [1]. Closed on Mondays [2]."
        let r = await CitationEntailment.apply(t, evidence: ev, scorer: scorer)
        #expect(r.text == t && calls.value == 1 && r.pairs == 3)
    }

    @Test func numbersWithoutEvidenceAndEmptyClaimsAreLeftAlone() async {
        let t = "The museum opened in 1902 [1,9]. [2]"
        let r = await CitationEntailment.apply(t, evidence: ev, scorer: { $0.map { _ in 0.9 } })
        #expect(r.text == t && r.checked == 1)
    }

    @Test func aFailingScorerKeepsTheText() async {
        struct Down: Error {}
        let t = "The museum opened in 1902 [1]."
        let r = await CitationEntailment.apply(t, evidence: ev, scorer: { _ in throw Down() })
        #expect(r.text == t && r.checked == 0 && r.skipped?.hasPrefix("scorer") == true)
    }

    @Test func nonEnglishAnswersAreSkipped() async {
        let t = "Das Museum wurde im Jahr 1902 eröffnet und hat vierzig Räume, die man besuchen kann [1]."
        let r = await CitationEntailment.apply(t, evidence: ev, scorer: { $0.map { _ in 0.0 } })
        #expect(r.text == t && r.skipped == "language")
    }

    @Test func thresholdIsTheFittedValue() { #expect(CitationEntailment.threshold == 0.5) }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    /// Attempt 6: claim decomposition — list items, coordinated clauses and appositives become separate claims, and
    /// one unsupported claim removes the marker.
    @Test func claimsAreDecomposed() {
        let c = CitationEntailment.claims("CRISPR is used in medicine, agriculture and research.")
        #expect(c.first == "CRISPR is used in medicine, agriculture and research.")
        #expect(c.contains("CRISPR is used in medicine.") && c.contains("CRISPR is used in agriculture.") && c.contains("CRISPR is used in research."))
        let a = CitationEntailment.claims("Frederick Banting – a Canadian surgeon who led the experiments")
        #expect(a.contains("Frederick Banting is a Canadian surgeon who led the experiments"))
        let k = CitationEntailment.claims("Insulin lowers blood sugar, and it is made in the pancreas")
        #expect(k.contains("Insulin lowers blood sugar") && k.contains("it is made in the pancreas"))
        #expect(CitationEntailment.claims("Short.").count == 1)
    }

    @Test func oneUnsupportedClaimRemovesTheMarker() async {
        let ev = [1: "CRISPR is used in medicine and research."]
        let r = await CitationEntailment.apply("CRISPR is used in medicine, farming and research [1].", evidence: ev) { pairs in
            pairs.map { $0.claim.contains("farming") && !$0.claim.contains("medicine") ? 0.1 : 0.9 }
        }
        #expect(r.uncited == 1 && r.text == "CRISPR is used in medicine, farming and research.")
        let ok = await CitationEntailment.apply("CRISPR is used in medicine and research [1].", evidence: ev) { pairs in pairs.map { _ in 0.9 } }
        #expect(ok.uncited == 0 && ok.text.hasSuffix("[1]."))
    }
}
