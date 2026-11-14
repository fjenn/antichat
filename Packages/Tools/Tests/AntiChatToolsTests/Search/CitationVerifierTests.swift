// AT-250 c2 attempts 6–7 (A-M7-T03c): the generative citation verifier, batched (generator stubbed; the model runs
// in the engine).
@testable import AntiChatTools
import Foundation
import Testing

@Suite struct CitationVerifierTests {
    let ev = [1: "Museum page — example.org\nThe museum opened in 1902 and has 40 rooms.",
              2: "Opening hours — example.com\nThe museum is closed on Mondays."]

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var prompts: [String] = []
        func add(_ p: String) { lock.withLock { prompts.append(p) } }
        var all: [String] { lock.withLock { prompts } }
    }

    /// The numbered sentences of a batch prompt.
    static func sentences(_ prompt: String) -> [String] {
        let list = prompt.components(separatedBy: "SENTENCES:\n").last?.components(separatedBy: "\n\n").first ?? ""
        return list.split(separator: "\n").map { String($0) }
    }

    /// One line per sentence: SUPPORTED when it contains a key.
    static func stub(_ supported: [String], log: Log? = nil) -> CitationVerifier.Generator {
        { prompt, _ in
            log?.add(prompt)
            return sentences(prompt).enumerated().map { k, s in
                "\(k + 1): " + (supported.contains { s.contains($0) } ? "SUPPORTED" : "UNSUPPORTED: café")
            }.joined(separator: "\n")
        }
    }

    @Test func anUnsupportedVerdictRemovesTheMarkerAndKeepsTheWords() async {
        let t = "The museum opened in 1902 [1]. It has a famous café and 40 rooms [1]. It is closed on Mondays [2]."
        let log = Log()
        let r = await CitationVerifier.apply(t, evidence: ev, generate: Self.stub(["1902", "Mondays"], log: log))
        #expect(r.text == "The museum opened in 1902 [1]. It has a famous café and 40 rooms. It is closed on Mondays [2].")
        #expect(r.checked == 3 && r.uncited == 1 && r.unverified == 0 && r.skipped == nil)
        #expect(log.all.count == 1, "one request for the whole answer")
    }

    @Test func theBatchPromptPrintsEachSourceOnceAndTheCitesOfEachSentence() async {
        let log = Log()
        _ = await CitationVerifier.apply("It opened in 1902 [1]. It has 40 rooms [1]. Closed on Mondays [2].", evidence: ev,
                                         generate: Self.stub(["1902"], log: log))
        let p = try! #require(log.all.first)
        #expect(p.components(separatedBy: "[1] Museum page — example.org").count == 2)
        #expect(p.contains("[2] Opening hours — example.com\nThe museum is closed on Mondays."))
        #expect(Self.sentences(p) == ["1. [cites 1] It opened in 1902", "2. [cites 1] It has 40 rooms", "3. [cites 2] Closed on Mondays"])
        #expect(p.contains("exactly 3 lines"))
    }

    @Test func batchesOfBatchSize() async {
        let log = Log()
        let t = (1...10).map { "Fact number \($0) about 1902 [1]." }.joined(separator: " ")
        var config = CitationVerifier.Config()
        config.batchSize = 4
        let r = await CitationVerifier.apply(t, evidence: ev, config: config, generate: Self.stub(["1902"], log: log))
        #expect(log.all.count == 3 && r.checked == 10 && r.uncited == 0)
    }

    @Test func batchReplyParsing() {
        #expect(CitationVerifier.parseBatch("1: SUPPORTED\n2: UNSUPPORTED: x\n**3.** Supported", count: 3) == [true, false, true])
        #expect(CitationVerifier.parseBatch("2: SUPPORTED", count: 3) == [nil, true, nil])
        #expect(CitationVerifier.parseBatch("<think>1: no</think>\n1) MISSING: y\n9: SUPPORTED", count: 2) == [false, nil])
        #expect(CitationVerifier.verdict("NOT SUPPORTED: the year") == false && CitationVerifier.verdict("The passage") == nil)
    }

    /// M7 verifier: a sentence without a verdict (no line even when asked alone, or a generator error) loses its pill.
    @Test func noLineOrAGeneratorErrorRemovesTheMarker() async {
        let t = "The museum opened in 1902 [1]. It has 40 rooms [1]."
        let log = Log()
        let partial = await CitationVerifier.apply(t, evidence: ev, generate: { p, _ in log.add(p); return "2: UNSUPPORTED: rooms" })
        #expect(partial.text == "The museum opened in 1902. It has 40 rooms.")
        #expect(partial.checked == 1 && partial.uncited == 1 && partial.unverified == 1 && partial.retried == 1)
        #expect(log.all.count == 2 && Self.sentences(log.all[1]) == ["1. [cites 1] The museum opened in 1902"], "asked again alone")
        struct Boom: Error {}
        let failed = await CitationVerifier.apply(t, evidence: ev, generate: { _, _ in throw Boom() })
        #expect(failed.text == "The museum opened in 1902. It has 40 rooms." && failed.unverified == 2 && failed.skipped != nil)
    }

    /// M7 verifier: a sentence its batch reply skipped is asked alone and gets that verdict.
    @Test func aSentenceTheBatchReplySkippedIsAskedAlone() async {
        let t = "The museum opened in 1902 [1]. It has 40 rooms [1]. It is closed on Mondays [2]."
        let r = await CitationVerifier.apply(t, evidence: ev, generate: { p, _ in
            Self.sentences(p).count == 3 ? "1: SUPPORTED\n2: UNSUPPORTED: rooms" : "1: SUPPORTED"
        })
        #expect(r.text == "The museum opened in 1902 [1]. It has 40 rooms. It is closed on Mondays [2].")
        #expect(r.checked == 3 && r.uncited == 1 && r.unverified == 0 && r.retried == 1)
    }

    /// M7 verifier (the accuracy hole): a model that writes a long detail for an early sentence and stops at the
    /// token budget must still leave a verdict line for every sentence of the batch. The stub writes ~4 characters per
    /// token and cuts its reply at `maxTokens`; at the old 14 tokens per sentence sentences 3–8 had no line.
    @Test func aLongDetailLineDoesNotStarveTheLaterSentences() async {
        let t = (1...8).map { "The museum opened in 1902 and fact \($0) holds [1]." }.joined(separator: " ")
        let detail = String(repeating: "the source says something else entirely here ", count: 10)  // ≈ 460 chars
        let gen: CitationVerifier.Generator = { p, maxTokens in
            let n = Self.sentences(p).count
            let full = (1...n).map { $0 == 1 ? "1: UNSUPPORTED: \(detail)" : "\($0): SUPPORTED" }.joined(separator: "\n")
            return String(full.prefix(maxTokens * 4))
        }
        #expect(CitationVerifier.tokens(count: 8) >= 8 * 64)
        let r = await CitationVerifier.apply(t, evidence: ev, generate: gen)
        #expect(r.checked == 8 && r.uncited == 1 && r.unverified == 0 && r.retried == 0)
        let old: CitationVerifier.Generator = { p, _ in try await gen(p, 14 * Self.sentences(p).count + 8) }
        let o = await CitationVerifier.apply(t, evidence: ev, generate: old)
        #expect(o.retried > 0 && o.unverified == 0, "even a starved batch reply is completed by the one-by-one retry")
    }

    @Test func pastTheBudgetTheMarkersGo() async {
        let t = "The museum opened in 1902 [1]. It has 40 rooms [1]."
        let slow: CitationVerifier.Generator = { _, _ in try await Task.sleep(for: .seconds(30)); return "1: UNSUPPORTED: x" }
        var config = CitationVerifier.Config()
        config.budget = .milliseconds(50)
        let r = await CitationVerifier.apply(t, evidence: ev, config: config, generate: slow)
        #expect(r.text == "The museum opened in 1902. It has 40 rooms." && r.checked == 0 && r.unverified == 2)
    }

    /// M7 bars: the app's pass has no whole-answer bound (every sentence of a long answer is reached), a time limit
    /// per batch, and awaits the gate before each batch request.
    @Test func theAppPassIsUnboundedAndGatedPerBatch() async {
        #expect(CitationVerifier.Config.standard.budget == nil && CitationVerifier.batchTimeout >= .seconds(60))
        let many = (1...20).map { "The museum opened in 1902 and part \($0) has 40 rooms [1]." }.joined(separator: " ")
        let gates = Log()
        let r = await CitationVerifier.apply(many, evidence: ev, beforeBatch: { gates.add("gate") },
                                             generate: { _, _ in (1...8).map { "\($0): SUPPORTED" }.joined(separator: "\n") })
        #expect(r.checked == 20 && r.unverified == 0 && r.uncited == 0)
        #expect(gates.all.count == 3, "one gate per batch of 8")
    }

    @Test func aStuckBatchHitsItsTimeLimit() async {
        let t = "The museum opened in 1902 [1]. It has 40 rooms [1]."
        var config = CitationVerifier.Config()
        config.batchTimeout = .milliseconds(50)
        let r = await CitationVerifier.apply(t, evidence: ev, config: config,
                                             generate: { _, _ in try await Task.sleep(for: .seconds(30)); return "1: UNSUPPORTED: x" })
        #expect(r.text == "The museum opened in 1902. It has 40 rooms." && r.unverified == 2)
    }

    @Test func markersWithoutEvidenceAndEmptyClaimsAreLeftAlone() async {
        let t = "The museum opened in 1902 [9]. [1]"
        let r = await CitationVerifier.apply(t, evidence: ev, generate: { _, _ in "1: UNSUPPORTED: all" })
        #expect(r.text == t && r.checked == 0)
    }

    @Test func thePassageIsTheBestWindowsWithinTheBound() {
        let filler = String(repeating: "Unrelated text about weather and sports here. ", count: 60)
        let src = "Long page — example.net\n" + filler + "The bridge was completed in 1937 by Joseph Strauss. " + filler
        let p = CitationVerifier.passage(sentence: "The bridge was completed in 1937.", sources: [(4, src)], chars: 700)
        #expect(p.hasPrefix("[4] Long page — example.net\n"))
        #expect(p.contains("completed in 1937"))
        #expect(p.count < 900)
    }

    /// M7.T16 review #1: `[n]` inside code is never treated as a citation, so an unsupported verdict never edits code.
    @Test func markersInCodeAreNeverChecked() async {
        let t = "Read it with `rooms[1]`:\n\n```\nx = arr[1]\n```\nIt has a famous café [1]."
        let r = await CitationVerifier.apply(t, evidence: ev, generate: { _, _ in "1: UNSUPPORTED: all" })
        #expect(r.text == "Read it with `rooms[1]`:\n\n```\nx = arr[1]\n```\nIt has a famous café.")
        #expect(r.checked == 1 && r.uncited == 1)
    }
}
