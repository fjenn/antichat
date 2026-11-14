// M2.T12 real-model legs, through the real XPC helper and its ModelScheduler (GPU runs: wrap in lockf).
//   AT-NFR-M2  make test-integration-real TIER=min FILTER=KeepAliveRealTests   (chat-0.8b; SetPolicy testClockScale 60:
//              battery / Low Power → unload at 5 min, AC → 15 min, Never → still resident at 60 min; ±5 s scaled)
// Residency is read with the helper probe (`residentModels` = scheduler entries + the sd-server image set).
//   AT-NFR-R4  make test-integration-real TIER=T1 FILTER=ResidentSetTests      (chat-9b-q4 at the T1 cap + a real
//              sd-server image job, then 10 min idle (scaled): resident ⊆ {chat, embed, voice}; no image model)
// Artefacts: build/at/AT-NFR-M2/keepalive-real.json, build/at/AT-NFR-R4/resident-set.json (repo-relative).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import Foundation
import XCTest

enum RealModels {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func view(_ key: String) -> URL { PrefixReuseTests.view(key) }

    /// `footprint` = the catalog footprint in GB the scheduler's fit rule uses (0 = unknown).
    static func mlx(_ key: String, footprint: Double = 0) throws -> ModelSlot {
        let dir = view(key)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path) else {
            throw XCTSkip("\(key) not fetched (make models-dev)")
        }
        return ModelSlot(engine: .mlx, key: key, path: dir.path, footprintBytes: UInt64(footprint * 1e9))
    }

    static func write(_ at: String, _ name: String, _ obj: [String: Any]) {
        let dir = repoRoot.appendingPathComponent("build/at/\(at)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent(name))
        }
        print("evidence \(at)/\(name): \(obj)")
    }

    /// Polls the helper until `key` is no longer resident; returns the real seconds waited (nil = timeout).
    static func waitUnloaded(_ client: EngineClient, _ key: String, timeout: Double) async throws -> Double? {
        let t0 = ContinuousClock.now
        while EngineTestSupport.secs(ContinuousClock.now - t0) < timeout {
            if try await !client.probe().residentModels.contains(key) { return EngineTestSupport.secs(ContinuousClock.now - t0) }
            try await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}

final class KeepAliveRealTests: XCTestCase {
    static let scale = 60.0
    /// ±5 s of scheduler (virtual) time.
    static let tolerance = 5.0 / scale

    /// Teardown time of an explicit unload (Evict → no longer resident), real seconds: the test clock multiplies it
    /// by 60, so it is measured and taken off the keep-alive reading (NFR-M2 bounds the decision, not the teardown).
    func teardown(_ client: EngineClient, _ slot: ModelSlot) async throws -> Double {
        var xs: [Double] = []
        for _ in 0..<3 {
            if let err = await client.warmup(slot) { throw err }
            let t0 = ContinuousClock.now
            for await _ in client.evict(key: slot.key) {}
            xs.append(EngineTestSupport.secs(ContinuousClock.now - t0))
        }
        return xs.sorted()[1]
    }

    func leg(_ client: EngineClient, _ slot: ModelSlot, keepAlive: Int, lowPower: Bool, expect: Double?, teardown: Double) async throws -> [String: Any] {
        for await _ in client.evict() {}
        try await client.setPolicy(SetPolicy(budgetB: 0, keepAliveSeconds: keepAlive, lowPower: lowPower, testClockScale: Self.scale))
        if let err = await client.warmup(slot) { throw err }  // the warm-up's lease ends at once: keep-alive starts
        let wanted = expect.map { $0 / Self.scale }
        let raw = try await RealModels.waitUnloaded(client, slot.key, timeout: (wanted ?? 60) + 3)
        let waited = raw.map { $0 - teardown }
        var row: [String: Any] = ["keep_alive_s": keepAlive, "low_power": lowPower, "expected_virtual_s": expect ?? -1,
                                  "unloaded_after_real_s": raw ?? -1, "teardown_real_s": teardown, "unloaded_after_virtual_s": (waited ?? -1) * Self.scale]
        if let wanted {
            let w = try XCTUnwrap(waited, "not unloaded within \(wanted + 3) s real")
            // The 20 ms poll + a probe round trip add ≤ 0.1 s real on top of the scheduler's own error.
            XCTAssertEqual(w, wanted, accuracy: Self.tolerance + 0.1, "unload at \(w * Self.scale) virtual s, want \(expect!)")
            row["within_5s_scaled"] = abs(w - wanted) <= Self.tolerance
        } else {
            XCTAssertNil(waited, "Never: unloaded after \(waited ?? -1) s")
            row["still_resident_at_virtual_s"] = 3600
        }
        return row
    }

    func testUnloadTimesMatchNFRM2() async throws {
        guard ProcessInfo.processInfo.environment["ANTICHAT_TIER"] == "min" else { throw XCTSkip("TIER=min (make test-integration-real)") }
        let slot = try RealModels.mlx("chat-0.8b")
        let client = EngineClient(appBuild: "it-keepalive-real")
        defer { client.disconnect() }
        try await client.ensureConnected()
        var rows: [[String: Any]] = []
        try await client.setPolicy(SetPolicy(budgetB: 0))
        let td = try await teardown(client, slot)
        rows.append(try await leg(client, slot, keepAlive: 900, lowPower: true, expect: 300, teardown: td))   // battery:50 → 5 min
        rows.append(try await leg(client, slot, keepAlive: 900, lowPower: false, expect: 900, teardown: td))  // AC → 15 min
        rows.append(try await leg(client, slot, keepAlive: 0, lowPower: false, expect: nil, teardown: td))    // Never → 60 min
        for await _ in client.evict() {}
        try await client.setPolicy(SetPolicy(budgetB: 0))
        RealModels.write("AT-NFR-M2", "keepalive-real.json", ["model": slot.key, "test_clock_scale": Self.scale, "legs": rows,
                                                             "date": ISO8601DateFormatter().string(from: Date())])
    }
}

final class ResidentSetTests: XCTestCase {
    static let budgetT1: UInt64 = 9_500_000_000

    static func imageSet() throws -> ImageModelSet {
        let d = PrefixReuseTests.modelsDir
        let set = ImageModelSet(
            key: "img-klein-q4", diffusionModel: d.appendingPathComponent("img-klein/flux-2-klein-4b-Q4_0.gguf").path,
            llm: d.appendingPathComponent("img-te/Qwen3-4B-Q4_K_M.gguf").path,
            vae: d.appendingPathComponent("img-vae-flux2/split_files/vae/flux2-vae.safetensors").path, footprintBytes: 6_300_000_000)
        for p in [set.diffusionModel, set.llm, set.vae] where !FileManager.default.fileExists(atPath: p) {
            throw XCTSkip("image set missing \(p) (make models-dev MANIFEST=m0 TIER=T1)")
        }
        return set
    }

    func runImage(_ client: EngineClient, _ set: ImageModelSet, restore: ModelSlot?) async throws -> [String] {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("resident-set-\(UUID().uuidString).png")
        var notes: [String] = []
        for await b in client.image(ImageRequest(model: set, prompt: "a red cube on a table", width: 256, height: 256, steps: 2,
                                                 seed: 7, preview: "none", outputPath: out.path, restoreChat: restore)) {
            for item in b.items {
                if case .media(.scheduler(let n)) = item { notes.append("\(n.action) \(n.model)") }
                if case .engine(.error(let e)) = item { throw e }
            }
        }
        return notes
    }

    func testOnlyChatEmbedVoiceStayResidentAtT1() async throws {
        guard ProcessInfo.processInfo.environment["ANTICHAT_TIER"] == "T1" else { throw XCTSkip("TIER=T1 (make test-integration-real)") }
        let chat = try RealModels.mlx("chat-9b-q4", footprint: 6.5)
        let set = try Self.imageSet()
        let client = EngineClient(appBuild: "it-resident-set")
        defer { client.disconnect() }
        try await client.ensureConnected()
        for await _ in client.evict() {}
        try await client.setPolicy(SetPolicy(budgetB: Self.budgetT1, keepAliveSeconds: 1800, lowTier: true, testClockScale: 60))
        var text = ""
        for try await e in client.chat(ChatRequest(modelSlot: chat, messages: [ChatMessage(role: .user, content: "Say hi.")],
                                                  sampling: Sampling(maxTokens: 16))) {
            if case .textDelta(let t) = e { text += t }
        }
        XCTAssertFalse(text.isEmpty)
        let afterChat = try await client.probe().residentModels
        let notes = try await runImage(client, set, restore: chat)
        let afterJob = try await client.probe().residentModels
        // 10 min idle at testClockScale 60. The 30-min keep-alive setting keeps the chat model through the job and the
        // idle (the job itself also runs on the ×60 clock); the rule under test is the job model's.
        try await Task.sleep(for: .seconds(10))
        let idle = try await client.probe().residentModels
        let allowed: Set<String> = [chat.key, "embed", "stt", "tts"]
        XCTAssertTrue(Set(idle).isSubset(of: allowed), "resident after idle: \(idle)")
        XCTAssertFalse(idle.contains(set.key), "image set resident without a job")
        XCTAssertFalse(afterJob.contains(set.key), "image set still resident right after the job: \(afterJob)")
        for await _ in client.evict() {}
        try await client.setPolicy(SetPolicy(budgetB: 0))
        RealModels.write("AT-NFR-R4", "resident-set.json", [
            "cap": "T1", "budget_b": Int(Self.budgetT1), "after_chat": afterChat, "image_job_notes": notes, "after_job": afterJob,
            "after_10min_idle_scaled": idle, "allowed": Array(allowed).sorted(),
            "semantic_search": "pending (M2.T16: no embedding request path yet; embed is in the allowed set)",
            "date": ISO8601DateFormatter().string(from: Date()),
        ])
    }
}
