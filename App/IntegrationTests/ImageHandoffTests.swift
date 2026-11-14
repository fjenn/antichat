// AT-286 AC2 + AT-236 AC1 + AT-NFR-M3 unload leg (M4.T06; R-286, R-236, NFR-M3, NFR-R1) through the real XPC helper:
// chat-9b-q4 resident at the T1 cap (B 9.5 GB), then a real `create_image` job (img-klein Q4 + Qwen3-4B Q4_K_M + flux2
// VAE, 768² 4 steps, content-free prompt, the dev detector files through the gate) submitted as a media job:
//   * the chat model steps aside BEFORE sd-server starts (the `evicted` note precedes `sdStarted`), unload ≤ 1 s;
//   * the job ends with a gated `jobResult`; peak helper + sd-server footprint ≤ B (NFR-R1 at the T1 cap). T1 has no
//     live previews (lead decision): `preview: none`, sd-server unloads (`imageUnloaded` reason `beforeCheck`) before
//     the detectors load for the one final check; the first-check latency (`result_check_s`) is recorded;
//   * no `chatReloaded` around the job (the templated caption needs no LLM): the chat reloads only at the next turn,
//     which reports `loading` first (`status.loadingModel`).
// `make test-integration-real TIER=T1 FILTER=ImageHandoffTests` (real models: run under gpu-run.sh; check memory first).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import Foundation
import XCTest

final class ImageHandoffTests: XCTestCase {
    func testUnloadBeforeLoadT1() async throws {
        guard ProcessInfo.processInfo.environment["ANTICHAT_TIER"] == "T1" else { throw XCTSkip("TIER=T1 (make test-integration-real)") }
        let chat = try RealModels.mlx("chat-9b-q4", footprint: 6.5)
        let set = try ResidentSetTests.imageSet()
        let safety = try XCTUnwrap(SafetyManifestResolver.resolveUnpinned(modelsRoot: SafetyManifestResolver.devModelsRoot), "dev detectors")
        let b: UInt64 = 9_500_000_000
        let client = EngineClient(appBuild: "it-image-handoff")
        defer { client.disconnect() }
        try await client.ensureConnected()
        for await _ in client.evict() {}
        try await client.setPolicy(SetPolicy(budgetB: b, lowTier: true))
        _ = try await StepAsideRun.turn(client, chat)
        // M9.T05 dry run: a thermal / power change in the test host re-sends the host Mac's policy (PowerLaunch →
        // EngineClient.pushPolicy; this Mac is T4: lowTier false, its B). It must not replace the T1 cap set above,
        // or the generator stays beside the detectors for the final check (no `imageUnloaded`, peak 6.1 → 8.1 GB).
        EngineClient.pushPolicy(SetPolicy(budgetB: 0, lowTier: false))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var req = ImageRequest(model: set, prompt: "a red cube on a wooden table, studio light", width: 768, height: 768, steps: 4,
                               seed: 7, preview: "none", outputPath: dir.appendingPathComponent("result.png").path)
        req.cfgScale = 1
        let job = MediaJobSubmit(job: "handoff-\(UUID().uuidString)", image: req, previewDir: dir.appendingPathComponent("xfer").path, safety: safety)
        let items = try await EngineTestSupport.drain(client.submit(job), timeout: .seconds(900)).flatMap(\.items)
        let notes = items.compactMap { if case .media(.scheduler(let n)) = $0 { n } else { nil } }
        let result = items.compactMap { if case .media(.imageResult(let r)) = $0 { r } else { nil } }.last
        let terminal = items.compactMap { if case .media(.job(let e)) = $0, e.isTerminal { e } else { nil } }.last
        let evicted = try XCTUnwrap(notes.firstIndex { $0.action == "evicted" && $0.model.contains(chat.key) }, "\(notes.map(\.action))")
        let started = try XCTUnwrap(notes.firstIndex { $0.action == "sdStarted" }, "\(notes.map(\.action))")
        XCTAssertLessThan(evicted, started, "the chat model unloads before the image model loads")
        let unload = notes[evicted].seconds
        XCTAssertLessThanOrEqual(unload, 1.0, "NFR-M3 unload ≤ 1 s")
        guard case .jobResult? = terminal else { return XCTFail("terminal \(String(describing: terminal))") }
        let peak = UInt64(result?.metrics["peak_helper_sd_bytes"] ?? 0)
        let unloadedBeforeCheck = notes.contains { $0.action == "imageUnloaded" && $0.detail["reason"] == "beforeCheck" }
        XCTAssertTrue(unloadedBeforeCheck, "the generator unloads before the final check: \(notes.map(\.action))")
        XCTAssertGreaterThan(peak, 0)
        XCTAssertLessThanOrEqual(peak, b, "NFR-R1: peak ≤ B at the T1 cap")
        XCTAssertFalse(notes.contains { $0.action == "chatReloaded" }, "no chat reload before the next user message (R-236)")
        let (text, loading, reload) = try await StepAsideRun.turn(client, chat)
        XCTAssertTrue(loading, "the next message reports the reload (status.loadingModel)")
        XCTAssertFalse(text.isEmpty)
        for await _ in client.evict() {}
        try await client.setPolicy(SetPolicy(budgetB: 0))
        RealModels.write("AT-286", "handoff-T1.json", [
            "cap": "T1", "budget_b": b, "chat": chat.key, "image": set.key, "unload_s": unload, "peak_bytes": peak,
            "image_load_s": result?.metrics["image_load_s"] ?? -1, "submit_to_final_s": result?.metrics["submit_to_final_s"] ?? -1,
            "next_turn_reload_s": reload, "live_previews": false,
            "result_check_s": result?.metrics["result_check_s"] ?? -1, "detector_load_s": result?.metrics["detector_load_s"] ?? -1, "notes": notes.map { "\($0.action) \($0.model) \($0.seconds)" },
            "load_avg": ProcessInfo.processInfo.environment["ANTICHAT_LOAD_AVG"] ?? "", "date": ISO8601DateFormatter().string(from: Date()),
        ])
    }
}
