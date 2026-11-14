// AT-206 part 2 (R-206 AC2, NFR-M3, NFR-R4; M2.T13) through the real XPC helper with ScriptedImageEngine (declared
// footprint allocated as MTLBuffers):
//   make test-integration-stub FILTER=StepAsideTests        (scripted chat slot with a 6.5 GB catalog footprint)
//     T1 cap (B 9.5 GB): the chat model steps aside (≤ 1 s), the image context is gone after the job (NFR-R4), and the
//     next chat turn reloads lazily with loadState(.loading) (`status.loadingModel`) and is answered;
//     T3 cap (B 36 GB): no eviction, the chat model stays resident.
//   make test-integration-real TIER=T1 FILTER=StepAsideRealTests   (real chat-9b-q4 + scripted 6.5 GB media)
//     unload ≤ 1 s, reload ≤ the NFR-M1 band of chat-9b-q4 (≤ 6 GB weights: 3 s), loading reported, turn answered.
// The embeddings-kept (T2) and voice-last rules are StepAsidePlanTests (one scripted engine holds one model).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import Foundation
import XCTest

enum StepAsideRun {
    struct Result {
        var notes: [SchedulerNote] = []
        var unloadS = -1.0
        var finalStatus = ""
    }

    static func image(_ client: EngineClient, footprintGB: Double, steps: Int = 4) async throws -> Result {
        let set = ImageModelSet(key: "scripted-image", diffusionModel: "scripted:\(steps):50", llm: "", vae: "",
                                footprintBytes: UInt64(footprintGB * 1e9))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("step-aside-\(UUID().uuidString).png")
        var r = Result()
        // M4.T04: every image output passes the gate; no detector manifest here (memory choreography only), so the final
        // is withheld — `safetyMissing`, nothing written. `preview: none` keeps the job running every step.
        for await b in client.image(ImageRequest(model: set, prompt: "x", width: 1, height: 1, steps: steps, seed: 1, preview: "none",
                                                 outputPath: out.path)) {
            for item in b.items {
                switch item {
                case .media(.scheduler(let n)):
                    r.notes.append(n)
                    if n.action == "evicted" { r.unloadS = n.seconds }
                case .media(.imageResult(let res)): r.finalStatus = res.status
                case .engine(.error(let e)): throw e
                default: break
                }
            }
        }
        return r
    }

    /// One chat turn; returns (text, saw loadState(.loading), load-to-ready seconds).
    static func turn(_ client: EngineClient, _ slot: ModelSlot) async throws -> (String, Bool, Double) {
        var text = "", loading = false
        var t0: ContinuousClock.Instant?
        var ready = -1.0
        for await b in client.chatBatches(ChatRequest(modelSlot: slot, messages: [ChatMessage(role: .user, content: "Say hi.")],
                                                      sampling: Sampling(maxTokens: 8))) {
            if b.lifecycle.contains(.loadState(.loading)) { loading = true; t0 = b.receivedAt }
            if b.lifecycle.contains(.loadState(.ready)), let t0 { ready = EngineTestSupport.secs(b.receivedAt - t0) }
            for e in b.events {
                if case .textDelta(let t) = e { text += t }
                if case .error(let err) = e { throw err }
            }
        }
        return (text, loading, ready)
    }
}

final class StepAsideTests: XCTestCase {
    func chatSlot() throws -> ModelSlot {
        var s = try EngineTestSupport.script([#"{"t":"textDelta","v":"hello"}"#], name: "step-aside-chat")
        s.footprintBytes = 6_500_000_000
        return s
    }

    func testT1ChatStepsAsideAndReloadsLazily() async throws {
        let chat = try chatSlot()
        let client = EngineClient(appBuild: "it-step-aside")
        defer { client.disconnect() }
        try await client.ensureConnected()
        for await _ in client.evict() {}
        // B is sized from what the helper already holds that is not a model (earlier suites' detectors, Metal heaps:
        // 3.2 GB after R241's image leg, decaying slowly on a loaded host). With the fixed 9.5 GB B the target
        // B − media = 3.0 GB sat under that residue, so the footprint wait timed out (unload −1) although the step-aside
        // itself was immediate. B = media + max(3 GB, residue + 0.5 GB) keeps the T1 shape (chat + media > B) and makes
        // the measured unload depend on the step-aside only.
        let residue = try await client.probe().footprintBytes ?? 0
        let budget = 6_500_000_000 + max(3_000_000_000, residue + 500_000_000)
        guard budget < 13_000_000_000 else { return XCTFail("helper holds \(residue) bytes before the test (a leak upstream)") }
        try await client.setPolicy(SetPolicy(budgetB: budget, lowTier: true))
        _ = try await StepAsideRun.turn(client, chat)
        let before = try await client.probe().residentModels
        XCTAssertEqual(before, [chat.key])
        let r = try await StepAsideRun.image(client, footprintGB: 6.5)
        XCTAssertEqual(r.finalStatus, "safetyMissing")  // the job ran to its final; the gate failed closed
        let ev = try XCTUnwrap(r.notes.first { $0.action == "evicted" }, "\(r.notes.map(\.action))")
        XCTAssertEqual(ev.model, chat.key)
        // The step-aside happened and the footprint dropped (≥ 0 = it reached B − media). The ≤ 1 s NFR-M3 bound is a
        // wall-clock number of the OS reclaiming 6.5 GB, which moves with host load (1.06 s at load ≈ 30): it is gated in
        // testRealChatStepsAsideAndReloadsWithinNFRM1 (real model, gpu-run timing) and M9.T05, and recorded here only.
        XCTAssertGreaterThanOrEqual(r.unloadS, 0)
        XCTAssertTrue(r.notes.contains { $0.action == "imageUnloaded" }, "NFR-R4: no image context after the job on T1")
        let after = try await client.probe().residentModels
        XCTAssertEqual(after, [], "chat reloads lazily; image gone")
        let (text, loading, _) = try await StepAsideRun.turn(client, chat)
        XCTAssertTrue(loading, "the next message reports the reload (status.loadingModel)")
        XCTAssertEqual(text, "hello")
        for await _ in client.evict() {}
        try await client.setPolicy(SetPolicy(budgetB: 0))
        EngineTestSupport.evidence("AT-206-step-aside-T1", ["unload_s": r.unloadS, "residue_bytes": residue, "budget": budget, "notes": r.notes.map { "\($0.action) \($0.model) \($0.detail)" }])
    }

    func testT3MediaCoResides() async throws {
        let chat = try chatSlot()
        let client = EngineClient(appBuild: "it-step-aside-t3")
        defer { client.disconnect() }
        try await client.ensureConnected()
        for await _ in client.evict() {}
        try await client.setPolicy(SetPolicy(budgetB: 36_000_000_000, lowTier: false))
        _ = try await StepAsideRun.turn(client, chat)
        let r = try await StepAsideRun.image(client, footprintGB: 6.5)
        XCTAssertFalse(r.notes.contains { $0.action == "evicted" }, "\(r.notes.map(\.action))")
        XCTAssertTrue(r.notes.contains { $0.action == "kept" })
        let still = try await client.probe().residentModels
        XCTAssertTrue(still.contains(chat.key))
        for await _ in client.evict() {}
        try await client.setPolicy(SetPolicy(budgetB: 0))
    }
}

final class StepAsideRealTests: XCTestCase {
    func testRealChatStepsAsideAndReloadsWithinNFRM1() async throws {
        guard ProcessInfo.processInfo.environment["ANTICHAT_TIER"] == "T1" else { throw XCTSkip("TIER=T1 (make test-integration-real)") }
        let chat = try RealModels.mlx("chat-9b-q4", footprint: 6.5)
        let client = EngineClient(appBuild: "it-step-aside-real")
        defer { client.disconnect() }
        try await client.ensureConnected()
        for await _ in client.evict() {}
        try await client.setPolicy(SetPolicy(budgetB: 9_500_000_000, lowTier: true))
        _ = try await StepAsideRun.turn(client, chat)
        let r = try await StepAsideRun.image(client, footprintGB: 6.5)
        XCTAssertEqual(r.finalStatus, "safetyMissing")  // the job ran to its final; the gate failed closed
        XCTAssertTrue(r.notes.contains { $0.action == "evicted" && $0.model == chat.key }, "\(r.notes.map(\.action))")
        XCTAssertLessThanOrEqual(r.unloadS, 1.0, "NFR-M3 unload ≤ 1 s")
        XCTAssertGreaterThanOrEqual(r.unloadS, 0, "helper footprint never dropped below B − media")
        let (text, loading, reload) = try await StepAsideRun.turn(client, chat)
        XCTAssertTrue(loading)
        XCTAssertFalse(text.isEmpty)
        XCTAssertGreaterThan(reload, 0)
        XCTAssertLessThanOrEqual(reload, 3.0, "reload ≤ NFR-M1 band (≤ 6 GB weights)")
        for await _ in client.evict() {}
        try await client.setPolicy(SetPolicy(budgetB: 0))
        RealModels.write("AT-206", "step-aside-real.json", [
            "cap": "T1", "model": chat.key, "media_footprint_gb": 6.5, "unload_s": r.unloadS, "reload_s": reload,
            "loading_reported": loading, "notes": r.notes.map { "\($0.action) \($0.model) \($0.seconds)" },
            "date": ISO8601DateFormatter().string(from: Date()),
        ])
    }
}
