// M2.T16 step 3 (real model, skipped when `embed` is not in the dev store; `make models-dev`): Qwen3-Embedding-0.6B
// through EmbeddingService gives 1024-d unit vectors whose nearest document is the semantically related one, with no
// shared words between query and document.
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatEngines

@Suite("EmbeddingServiceRealTests", .serialized) struct EmbeddingServiceRealTests {
    @Test func qwen3EmbeddingRanksByMeaning() async throws {
        guard let dir = DevModels.path("embed") else { return }
        let service = EmbeddingService()
        let slot = ModelSlot(engine: .mlx, key: "embed", path: dir.path)
        _ = try await service.load(slot)
        let docs = ["My puppy chewed the sofa again last night", "We went sailing on a small yacht",
                    "The sourdough starter needs feeding twice a day", "Keep every receipt for the accountant"]
        let d = try await service.embed(docs, kind: .document, key: "embed")
        let q = try await service.embed(["How do I stop my dog from destroying furniture?", "boat trip", "bread recipe",
                                         "filing my taxes"], kind: .query, key: "embed")
        #expect(d.count == 4 && d.allSatisfy { $0.count == 1024 })
        #expect(abs(d[0].reduce(0) { $0 + $1 * $1 } - 1) < 1e-3)
        for (i, v) in q.enumerated() {
            let sims = d.map { zip($0, v).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
            #expect(sims.firstIndex(of: sims.max()!) == i, "query \(i): \(sims)")
        }
        // AT-295: the query-embedding stage of ⌘K (one short query, warm model), 20 runs.
        var ms: [Double] = []
        for i in 0..<20 {
            let t = ContinuousClock.now
            _ = try await service.embed(["what did we say about \(i) dogs"], kind: .query, key: "embed")
            let d = ContinuousClock.now - t
            ms.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
        ms.sort()
        if let out = ProcessInfo.processInfo.environment["ANTICHAT_QUERY_EMBED_OUT"] {
            try #"{"runs": 20, "p50_ms": \#(ms[9]), "p95_ms": \#(ms[18])}"#.write(toFile: out, atomically: true, encoding: .utf8)
        }
        await service.unload("embed")
        #expect(await !service.holds("embed"))
    }
}
