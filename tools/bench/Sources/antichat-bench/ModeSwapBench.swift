// `antichat-bench modeswap` (M2.T15, AT-NFR-C7): Normal ↔ Evil switch → first token. Each run: one short turn on
// the Normal chat model (it is the current model), then t0 = "open a new Evil chat" → the Evil turn's first content
// delta. With `--warm` the helper gets SetPolicy.warmSecondVariant = true (T3+: the other mode's model stays loaded
// when both fit B, so after run 0 every switch is warm); without it, false (unload 9B MLX → load evil-9b GGUF via
// the llama-server router → first token). Run 0 is discarded (Metal pipeline compile, first GGUF mmap).
//
//   antichat-bench modeswap --normal chat-9b-q4 --evil llama:evil-9b --cap T1 --runs 20 --json <out>
//   antichat-bench modeswap --normal chat-35b-q4 --evil evil-35b-q4 --cap T3-64 --warm --runs 20 --json <out>
import AntiChatHarness
import Foundation

enum ModeSwapBench {
    static func run(_ a: BenchArgs) async throws {
        let cap = a["cap"] ?? "none"
        guard let gb = DevSlots.tierB[cap] else { throw BenchError("--cap \(cap): unknown tier") }
        let normal = DevSlots.slot(a["normal"] ?? "chat-9b-q4")
        let evil = DevSlots.slot(a["evil"] ?? "llama:evil-9b")
        let warm = a["warm"] != nil
        let runs = a.int("runs", 20)
        let client = EngineClient(appBuild: "antichat-bench")
        defer { client.disconnect() }
        let ack = try await client.ensureConnected()
        let budget = UInt64(gb * 1e9)
        try await client.setPolicy(SetPolicy(budgetB: budget, warmSecondVariant: warm))
        say("helper pid=\(ack.helperPID) normal=\(normal.key) evil=\(evil.key) cap=\(cap) B=\(budget) warm=\(warm)")
        for await _ in client.evict() {}
        func req(_ slot: ModelSlot, _ text: String, _ seed: UInt64) -> ChatRequest {
            ChatRequest(modelSlot: slot, messages: [ChatMessage(role: .user, content: text)],
                        sampling: Sampling(temperature: 0.7, topP: 0.95, maxTokens: 16, seed: seed))
        }
        var rows: [[String: Any]] = []
        var vals: [Double] = []
        var loads: [Double] = []
        for i in 0...runs {
            let n = try await ChatBench.one(client, req(normal, "Say hello in five words.", UInt64(10 + i)))
            if let e = n.error { throw BenchError("normal \(i): \(e)") }
            let t0 = ContinuousClock.now
            let r = try await ChatBench.one(client, req(evil, "Say hi in five words.", UInt64(500 + i)))
            if let e = r.error { throw BenchError("evil \(i): \(e)") }
            let total = Stats.secs(ContinuousClock.now - t0)
            let ttft = (r.ttftAppMs ?? -1) / 1000
            let load = r.usage?.loadTime ?? 0
            rows.append(["run": i, "discarded": i == 0, "switch_to_first_token_s": ttft, "engine_load_s": load, "turn_s": total,
                         "cold": load > 0])
            if i > 0, ttft > 0 { vals.append(ttft); loads.append(load) }
            say(String(format: "run %d switch→first token %.3f s (engine load %.3f s)%@", i, ttft, load, i == 0 ? " (discarded)" : ""))
        }
        for await _ in client.evict() {}
        let out: [String: Any] = [
            "cmd": "modeswap", "normal": normal.key, "evil": evil.key, "cap": cap, "budget_b": budget, "warm": warm, "runs": runs,
            "normal_bytes": normal.footprintBytes, "evil_bytes": evil.footprintBytes, "helper_pid": Int(ack.helperPID),
            "date": ISO8601DateFormatter().string(from: Date()),
            "summary": ["switch_to_first_token_s": Stats.summary(vals), "engine_load_s": Stats.summary(loads)], "rows": rows,
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
}
