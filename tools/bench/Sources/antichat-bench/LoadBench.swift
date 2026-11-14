// `antichat-bench load` (M2.T12, AT-NFR-M1): cold model load = `Evict` → `Warmup` → `loadState(.ready)` ("first
// token possible": the scheduler's ensureLoaded returned, weights resident, Metal pipelines built). Each run first
// evicts everything, so every load goes through ModelScheduler.ensureLoaded from nothing resident. Run 0 is
// discarded (NFR-M1: Metal pipeline compile cached after the first run). The file cache is NOT dropped unless
// `--purge` and `sudo -n purge` works (P-SUDO); the result is then [WARM-CACHE] like M0's m0.M1.* values.
//
//   antichat-bench load --model <key> --cap <tier> --runs N --json <out> [--purge]
import AntiChatHarness
import Foundation

enum LoadBench {
    static func run(_ a: BenchArgs) async throws {
        let key = a["model"] ?? "chat-0.8b"
        let cap = a["cap"] ?? "none"
        guard let gb = DevSlots.tierB[cap] else { throw BenchError("--cap \(cap): unknown tier") }
        let slot = DevSlots.slot(key)
        let runs = a.int("runs", 20)
        let client = EngineClient(appBuild: "antichat-bench")
        defer { client.disconnect() }
        let ack = try await client.ensureConnected()
        let budget = UInt64(gb * 1e9)
        try await client.setPolicy(SetPolicy(budgetB: budget))
        let purge = a["purge"] != nil && Self.sh(["/usr/bin/sudo", "-n", "/usr/sbin/purge"]) == 0
        say("helper pid=\(ack.helperPID) model=\(slot.key) weights=\(slot.footprintBytes) cap=\(cap) purge=\(purge)")
        var rows: [[String: Any]] = []
        var wall: [Double] = []
        for i in 0...runs {
            for await _ in client.evict() {}
            if purge { _ = Self.sh(["/usr/bin/sudo", "-n", "/usr/sbin/purge"]) }
            let t0 = ContinuousClock.now
            var ready: Double?
            var engineLoad: Double?
            var err: String?
            for await b in client.warmupBatches(slot) {
                if b.lifecycle.contains(.loadState(.ready)) { ready = Stats.secs(b.receivedAt - t0) }
                for e in b.events {
                    if case .usage(let u) = e { engineLoad = u.loadTime }
                    if case .error(let x) = e { err = x.description }
                }
            }
            if let err { throw BenchError("load \(i): \(err)") }
            let r: [String: Any] = ["run": i, "discarded": i == 0, "ready_s": ready ?? -1, "engine_load_s": engineLoad ?? -1]
            rows.append(r)
            if i > 0, let ready { wall.append(ready) }
            say(String(format: "run %d ready=%.3f s engine=%.3f s%@", i, ready ?? -1, engineLoad ?? -1, i == 0 ? " (discarded)" : ""))
        }
        for await _ in client.evict() {}
        let out: [String: Any] = [
            "cmd": "load", "model": slot.key, "cap": cap, "budget_b": budget, "weights_bytes": slot.footprintBytes, "runs": runs,
            "purge": purge, "helper_pid": Int(ack.helperPID), "date": ISO8601DateFormatter().string(from: Date()),
            "summary": ["ready_s": Stats.summary(wall)], "rows": rows,
        ]
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        if let path = a["json"] {
            let u = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: u)
            say("wrote \(path)")
        } else {
            FileHandle.standardOutput.write(data)
        }
    }

    static func sh(_ argv: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
