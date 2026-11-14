// M4 lead decision (b): the first ChildSafetyCheck after the detectors left memory took 35.7 s (warm load). A job with
// live previews (T3+) now preloads the detectors at its start, overlapped with the generator; a job without previews
// (T0–T2) loads them only after the generator unloaded. This measures both first checks through the real helper with
// the dev detectors and ScriptedImageEngine (content-free gradients, no diffusion weights):
//   cold (`preview: none`, detectors released at job start): first check = load + check;
//   preloaded (`preview: proj`, 8 steps × 5 s of generation): the first preview check, timed from the check call.
// `make test-integration-real TIER=T1 FILTER=DetectorPreloadTests` under gpu-run.sh timing → build/at/AT-NFR-F7/preload.json.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import Foundation
import XCTest

final class DetectorPreloadTests: XCTestCase {
    func job(_ client: EngineClient, preview: String, steps: Int, delayMs: Int, safety: SafetyManifest) async throws -> [String: Double] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("preload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let req = ImageRequest(model: ScriptedImageScript(steps: steps, delayMs: delayMs).modelSet(), prompt: "a lighthouse",
                               width: 768, height: 768, steps: steps, seed: 3, preview: preview,
                               outputPath: dir.appendingPathComponent("result.png").path)
        let submit = MediaJobSubmit(job: "preload-\(UUID().uuidString)", image: req, previewDir: dir.appendingPathComponent("xfer").path,
                                    safety: safety)
        let t0 = ContinuousClock.now
        let items = try await EngineTestSupport.drain(client.submit(submit), timeout: .seconds(900)).flatMap(\.items)
        let d = ContinuousClock.now - t0
        let result = items.compactMap { if case .media(.imageResult(let r)) = $0 { r } else { nil } }.last
        let terminal = items.compactMap { if case .media(.job(let e)) = $0, e.isTerminal { e } else { nil } }.last
        guard case .jobResult? = terminal else { XCTFail("terminal \(String(describing: terminal))"); return [:] }
        var m = result?.metrics ?? [:]
        m["job_s"] = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return m
    }

    func testFirstCheckColdVersusPreloaded() async throws {
        guard ProcessInfo.processInfo.environment["ANTICHAT_TIER"] != nil else { throw XCTSkip("make test-integration-real") }
        let safety = try XCTUnwrap(SafetyManifestResolver.resolveUnpinned(modelsRoot: SafetyManifestResolver.devModelsRoot), "dev detectors")
        let client = EngineClient(appBuild: "it-detector-preload")
        defer { client.disconnect() }
        try await client.ensureConnected()
        try await client.setPolicy(SetPolicy(budgetB: 0, lowTier: false))
        let cold = try await job(client, preview: "none", steps: 4, delayMs: 50, safety: safety)
        // A `none` job releases the detectors at its start, so the preloaded leg starts cold too.
        _ = try await job(client, preview: "none", steps: 1, delayMs: 10, safety: safety)
        let warmup = try await job(client, preview: "none", steps: 1, delayMs: 10, safety: safety)
        let pre = try await job(client, preview: "proj", steps: 8, delayMs: 5000, safety: safety)
        let coldFirst = cold["first_check_s"] ?? -1, preFirst = pre["first_check_s"] ?? -1
        XCTAssertGreaterThan(coldFirst, 0)
        XCTAssertGreaterThan(preFirst, 0)
        RealModels.write("AT-NFR-F7", "preload.json", [
            "cold_first_check_s": coldFirst, "cold_detector_load_s": cold["detector_load_s"] ?? -1,
            "cold_after_release_first_check_s": warmup["first_check_s"] ?? -1,
            "preloaded_first_check_s": preFirst, "preloaded_detector_load_s": pre["detector_load_s"] ?? -1,
            "preloaded_job_s": pre["job_s"] ?? -1, "generation_s": 8 * 5.0,
            "load_avg": ProcessInfo.processInfo.environment["ANTICHAT_LOAD_AVG"] ?? "",
            "date": ISO8601DateFormatter().string(from: Date()),
        ])
    }
}
