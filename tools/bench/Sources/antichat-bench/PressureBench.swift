// `antichat-bench pressure` (M2.T14, AT-NFR-M4): WARNING → idle release time through the real helper. Each run loads
// the model (Warmup; keep-alive Never so only pressure unloads it), injects WARNING (`SetPolicy.testPressure`, the
// Debug path of `-FakePressure warn`) and times until the helper probe no longer lists the model.
// `--real` instead runs `/usr/bin/memory_pressure -S -l warn` (simulated system level, no allocation) once.
//
//   antichat-bench pressure --model <key> --cap <tier> --runs N --json <out> [--real]
import AntiChatHarness
import Foundation

enum PressureBench {
    static func run(_ a: BenchArgs) async throws {
        let slot = DevSlots.slot(a["model"] ?? "chat-9b-q4")
        let cap = a["cap"] ?? "T1"
        guard let gb = DevSlots.tierB[cap] else { throw BenchError("--cap \(cap): unknown tier") }
        let runs = a.int("runs", 20)
        let client = EngineClient(appBuild: "antichat-bench-pressure")
        defer { client.disconnect() }
        let ack = try await client.ensureConnected()
        let budget = UInt64(gb * 1e9)
        var rows: [[String: Any]] = []
        var xs: [Double] = []
        let real = a["real"] != nil
        for i in 0..<(real ? 1 : runs) {
            try await client.setPolicy(SetPolicy(budgetB: budget, keepAliveSeconds: 0, testPressure: "normal"))
            if let e = await client.warmup(slot) { throw BenchError("warmup: \(e)") }
            let t0 = ContinuousClock.now
            var tool: Int32 = 0
            if real {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/memory_pressure")
                p.arguments = ["-S", "-l", "warn"]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try p.run()
                p.waitUntilExit()
                tool = p.terminationStatus
            } else {
                try await client.setPolicy(SetPolicy(budgetB: budget, keepAliveSeconds: 0, testPressure: "warn"))
            }
            var released = -1.0
            while Stats.secs(ContinuousClock.now - t0) < 10 {
                if try await !client.probe().residentModels.contains(slot.key) { released = Stats.secs(ContinuousClock.now - t0); break }
                try await Task.sleep(for: .milliseconds(10))
            }
            rows.append(["run": i, "release_s": released, "memory_pressure_exit": Int(tool)])
            if released >= 0 { xs.append(released) }
            say(String(format: "run %d release=%.3f s%@", i, released, real ? " (memory_pressure -S -l warn exit \(tool))" : ""))
        }
        for await _ in client.evict() {}
        try await client.setPolicy(SetPolicy(budgetB: 0, testPressure: "normal"))
        let out: [String: Any] = ["cmd": "pressure", "model": slot.key, "cap": cap, "budget_b": budget, "real": real,
                                  "helper_pid": Int(ack.helperPID), "rows": rows, "summary": ["release_s": Stats.summary(xs)],
                                  "date": ISO8601DateFormatter().string(from: Date())]
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        if let path = a["json"] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path))
        } else { FileHandle.standardOutput.write(data) }
    }
}
