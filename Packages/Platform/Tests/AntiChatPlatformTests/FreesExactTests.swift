// AT-293 (R-293 AC2) — M2.T10: "frees X GB" for removing Evil = the measured `du` delta after remove + GC, within ±1 %.
@testable import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing

@Suite(.serialized) struct FreesExactTests {
    @Test func freesMatchesDu() async throws {
        let f = try StoreFixture("frees", sizesMB: ["tokenizer.json": 8, "model.safetensors": 20, "config.json": 1, "evil.gguf": 30])
        try await f.install(["norm", "evil"])
        let frees = SpaceAccountant.frees(["evil"], models: f.models)
        #expect(frees >= f.blobs["evil.gguf"]!.size)  // the gguf alone; the shared tokenizer frees nothing
        #expect(frees < f.blobs["evil.gguf"]!.size + f.blobs["tokenizer.json"]!.size)
        let before = try f.du()
        try InstallView.remove("evil", models: f.models)
        try GarbageCollector(models: f.models, database: nil).sweep()
        let delta = before - (try f.du())
        let err = abs(Double(delta - frees)) / Double(delta)
        #expect(err <= 0.01, "frees \(frees) vs du delta \(delta)")
        ATLog.write("AT-293", "frees.csv", "fixture,evil,\(frees),\(delta),\(String(format: "%.4f", err))")
    }
}
