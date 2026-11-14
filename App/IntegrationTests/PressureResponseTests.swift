// AT-206 part 3 (R-206 AC3/AC8, NFR-M4; M2.T14) through the real XPC helper, pressure injected the way
// `-FakePressure warn|critical` does it (`SetPolicy.testPressure`, Debug):
//   WARNING with an idle resident model → released, ≤ 2 s (p95 over 20 → build/at/AT-206/pressure.csv);
//   CRITICAL while a ScriptedImageEngine job runs → the job stops (`cancelled`) with `pausedLowMemory`
//   (`sched.pausedLowMemory` [Resume]); the helper process is the same before and after (never killed).
//   make test-integration-stub FILTER=PressureResponseTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import Foundation
import XCTest

final class PressureResponseTests: XCTestCase {
    func testWarningReleasesIdleWithinTwoSeconds() async throws {
        let chat = try EngineTestSupport.script([#"{"t":"textDelta","v":"x"}"#], name: "pressure-chat")
        let client = EngineClient(appBuild: "it-pressure")
        defer { client.disconnect() }
        try await client.ensureConnected()
        let pid = try await client.probe().pid
        var rows = ["run,release_s"]
        var xs: [Double] = []
        for i in 0..<20 {
            try await client.setPolicy(SetPolicy(budgetB: 0, keepAliveSeconds: 0))  // Never: only pressure unloads
            if let e = await client.warmup(chat) { throw e }
            let t0 = ContinuousClock.now
            try await client.setPolicy(SetPolicy(budgetB: 0, keepAliveSeconds: 0, testPressure: "warn"))
            let waited = try await RealModels.waitUnloaded(client, chat.key, timeout: 5)
            let s = try XCTUnwrap(waited, "not released on WARNING")
            _ = t0
            xs.append(s)
            rows.append("\(i),\(String(format: "%.4f", s))")
        }
        let p95 = xs.sorted()[Int(Double(xs.count - 1) * 0.95)]
        XCTAssertLessThanOrEqual(p95, 2.0, "NFR-M4 p95")
        let after = try await client.probe().pid
        XCTAssertEqual(pid, after, "helper never killed")
        let dir = RealModels.repoRoot.appendingPathComponent("build/at/AT-206")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (rows.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("pressure.csv"), atomically: true, encoding: .utf8)
        try await client.setPolicy(SetPolicy(budgetB: 0, testPressure: "normal"))
    }

    func testCriticalPausesTheRunningJob() async throws {
        let client = EngineClient(appBuild: "it-pressure-critical")
        defer { client.disconnect() }
        try await client.ensureConnected()
        let pid = try await client.probe().pid
        try await client.setPolicy(SetPolicy(budgetB: 0))
        let set = ImageModelSet(key: "scripted-image", diffusionModel: "scripted:60:100", llm: "", vae: "", footprintBytes: 64 << 20)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("pressure-\(UUID().uuidString).png")
        var notes: [String] = []
        var status = ""
        var sent = false
        for await b in client.image(ImageRequest(model: set, prompt: "x", width: 1, height: 1, steps: 60, seed: 1, preview: "none", outputPath: out.path)) {
            for item in b.items {
                switch item {
                case .media(.imageProgress(let p)) where p.step >= 2 && !sent:
                    sent = true
                    try await client.setPolicy(SetPolicy(budgetB: 0, testPressure: "critical"))
                case .media(.scheduler(let n)): notes.append(n.action)
                case .media(.imageResult(let r)): status = r.status
                default: break
                }
            }
        }
        XCTAssertTrue(sent)
        XCTAssertEqual(status, "cancelled")
        XCTAssertTrue(notes.contains("pausedLowMemory"), "\(notes)")
        let after = try await client.probe().pid
        XCTAssertEqual(pid, after, "helper never killed")
        try await client.setPolicy(SetPolicy(budgetB: 0, testPressure: "normal"))
    }
}
