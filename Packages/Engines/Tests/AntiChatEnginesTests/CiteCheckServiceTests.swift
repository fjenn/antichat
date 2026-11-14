// AT-250 c2 (A-M7-T03c): the helper's citation entailment model — windowing, the batched pair encoding, and (with
// ANTICHAT_CITE_IT=1 and the dev model at <AntiChat-Dev>/Models/cite-check) a real MiniCheck smoke on Core ML.
import AntiChatEngineProtocol
@testable import AntiChatEngines
import Foundation
import Testing

@Suite struct CiteCheckServiceTests {
    @Test func shortDocumentsAreOneWindowLongOnesOverlap() {
        #expect(CiteCheckService.windows(document: Array(0..<100), claimCount: 20) == [Array(0..<100)])
        let w = CiteCheckService.windows(document: Array(0..<1200), claimCount: 28)  // room 480, stride 360
        #expect(w.count == 3 && w.allSatisfy { $0.count <= 480 })
        #expect(w[0].first == 0 && w[1].first == 360 && w.last?.last == 1199)
    }

    @Test func bestWindowsShareTheMostClaimTokens() {
        let w = [[1, 2, 3], [4, 5, 6], [7, 8, 9], [5, 6, 9]]
        #expect(CiteCheckService.best(w, claim: [5, 6, 9], keep: 2) == [[4, 5, 6], [5, 6, 9]])
        #expect(CiteCheckService.best(w, claim: [5], keep: 0) == w)
        #expect(CiteCheckService.best([[1]], claim: [5], keep: 2) == [[1]])
    }

    @Test func pairsFromAQueryOrFromSeparatedDocuments() {
        let a = CiteCheckService.pairs(query: "claim", documents: ["p1", "p2"])
        #expect(a.map(\.claim) == ["claim", "claim"] && a.map(\.premise) == ["p1", "p2"])
        let b = CiteCheckService.pairs(query: "", documents: ["c1\u{1F}p1", "c2\u{1F}p\u{1F}2", "no separator"])
        #expect(b.map(\.claim) == ["c1", "c2", ""] && b.map(\.premise) == ["p1", "p\u{1F}2", "no separator"])
    }

    @Test func handlesOnlyCoreMLCiteSlots() {
        #expect(CiteCheckService.handles(ModelSlot(engine: .coreml, key: "cite-check", path: "")))
        #expect(!CiteCheckService.handles(ModelSlot(engine: .coreml, key: "stt", path: "")))
        #expect(!CiteCheckService.handles(ModelSlot(engine: .mlx, key: "cite-check", path: "")))
    }

    static var devModel: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/AntiChat-Dev/Models/cite-check")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_CITE_IT"] == "1"
          && FileManager.default.fileExists(atPath: CiteCheckServiceTests.devModel.path)))
    func realModelSeparatesSupportedFromUnsupported() async throws {
        let s = CiteCheckService()
        let slot = ModelSlot(engine: .coreml, key: "cite-check", path: Self.devModel.path)
        _ = try await s.load(slot)
        let doc = "Mozilla Spaces are our offices around the world. San Francisco 235 Pine Street 7th floor San Francisco, CA 94104 USA."
        let scores = try await s.score(pairs: [("Mozilla's San Francisco office is at 235 Pine Street.", doc),
                                               ("Mozilla's San Francisco office is at 100 Market Street.", doc)], key: "cite-check")
        #expect(scores[0] > 0.5 && scores[1] < 0.5, "\(scores)")
    }

    /// Parity with the Python evaluation (A-M7-T03c): ANTICHAT_CITE_PAIRS=<jsonl {claim, premise}> → `<file>.scores.json`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_CITE_PAIRS"] != nil
          && FileManager.default.fileExists(atPath: CiteCheckServiceTests.devModel.path)))
    func scoresAPairFile() async throws {
        let path = ProcessInfo.processInfo.environment["ANTICHAT_CITE_PAIRS"]!
        struct P: Decodable { var claim: String; var premise: String }
        let pairs = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(P.self, from: Data($0.utf8)) }
        let s = CiteCheckService()
        _ = try await s.load(ModelSlot(engine: .coreml, key: "cite-check", path: Self.devModel.path))
        let t = ContinuousClock.now
        let k = Int(ProcessInfo.processInfo.environment["ANTICHAT_CITE_TOPK"] ?? "") ?? CiteCheckService.windowsPerPair
        let scores = try await s.score(pairs: pairs.map { ($0.claim, $0.premise) }, key: "cite-check", windowsPerPair: k)
        let ms = Double((ContinuousClock.now - t).components.attoseconds) / 1e15 + Double((ContinuousClock.now - t).components.seconds) * 1000
        try JSONSerialization.data(withJSONObject: ["scores": scores.map(Double.init), "ms": ms]).write(to: URL(fileURLWithPath: path + ".scores.json"))
    }
}
