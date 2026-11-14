// M2.T22 test support: a deterministic embedder (hashed character trigrams → 256-d unit vectors) and the stub tools
// the router exposes (`create_image`, `create_video`, `web_search`, `create_file`, `memory_write`; read-only, so no
// ApprovalCard), plus M1's get_time / echo / write_note: eight tools in all.
import AntiChatEngineProtocol
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

final class TrigramEmbedding: RouteEmbedding {
    let calls = Mutex(0)
    let texts = Mutex(0)
    var modelID: String? { "trigram-256" }

    func embed(_ batch: [String]) async throws -> [[Float]] {
        calls.withLock { $0 += 1 }
        texts.withLock { $0 += batch.count }
        return batch.map(Self.vector)
    }

    static func vector(_ s: String) -> [Float] {
        var v = [Float](repeating: 0, count: 256)
        let chars = Array(" " + s.lowercased() + " ")
        for i in 0..<max(0, chars.count - 2) {
            var h: UInt32 = 2166136261
            for c in chars[i..<i + 3] { for u in c.unicodeScalars { h = (h ^ u.value) &* 16777619 } }
            v[Int(h % 256)] += 1
        }
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }
}

enum RouterStubs {
    static func tool(_ name: String) -> RegisteredTool {
        // `web_search` keeps the real schema: on T0/T1 the chip's call is the harness's ({"queries": […]}, M7 bars).
        RegisteredTool(name: name, description: "Stub \(name).",
                       parametersJSON: name == "web_search" ? WebSearchTools.webSearchParameters
                           : #"{"type":"object","properties":{"prompt":{"type":"string"}},"required":["prompt"]}"#,
                       outputIsUntrusted: false) { _ in "{\"ok\":true}" }
    }

    static let names = ["create_image", "create_video", "web_search", "create_file", "memory_write"]

    static var all: [RegisteredTool] {
        names.map(tool) + [ScriptedTools.getTime(), ScriptedTools.echo(), ScriptedTools.writeNote()]
    }

    /// A router over the bundled prototypes and the trigram embedder, prepared (cache in a temp dir).
    static func router(_ embedding: TrigramEmbedding = TrigramEmbedding(), enabled: Bool = true) async throws -> PreRouter {
        let p = try #require(RoutePrototypes.bundled)
        let dir = FileManager.default.temporaryDirectory.appending(path: "router-\(UUID().uuidString)")
        let scorer = RouteScorer(prototypes: p, embedding: embedding, cacheDirectory: dir)
        #expect(await scorer.prepare())
        var r = PreRouter(scorer: scorer, enabled: { enabled })
        // These suites test the scores, not the 10 ms send budget (RoutePrefetchTests owns that): without a budget a
        // loaded host can't turn a decision into `.timedOut` (seen at load ~80).
        r.sendBudget = nil
        return r
    }
}
