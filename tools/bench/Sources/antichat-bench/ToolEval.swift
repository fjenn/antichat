// `antichat-bench tools` (M1.T13 step 5, AT-231): the tool-calling eval over XPC.
//   antichat-bench tools --model chat-9b-q4 --cap T1 --set fixtures/prompts/antichat-tools-200.jsonl \
//                        --json build/at/AT-231/tools.json [--limit N] [--max-tokens 512]
// Scoring lives in AntiChatHarness/Engine/ToolEvalRunner.swift (shared with the ToolEval integration test).
import AntiChatHarness
import Foundation

enum ToolEvalBench {
    static func run(_ a: BenchArgs) async throws {
        let key = a["model"] ?? "chat-9b-q4"
        let cap = a["cap"] ?? "T1"
        guard let gb = DevSlots.tierB[cap] else { throw BenchError("--cap \(cap): unknown tier") }
        guard let set = a["set"] else { throw BenchError("--set <rows.jsonl> is required") }
        let slot = DevSlots.slot(key)
        let rows = try ToolEvalRunner.loadRows(URL(fileURLWithPath: set))
        let client = EngineClient(appBuild: "antichat-bench-tools")
        defer { client.disconnect() }
        let ack = try await client.ensureConnected()
        try await client.setPolicy(SetPolicy(budgetB: UInt64(gb * 1e9)))
        if let err = await client.warmup(slot) { throw BenchError("warmup: \(err)") }
        say("helper pid=\(ack.helperPID) model=\(slot.key) cap=\(cap) rows=\(rows.count)")
        var report = await ToolEvalRunner.run(
            client: client, slot: slot, rows: rows,
            options: .init(maxTokens: a.int("max-tokens", 1536), limit: a["limit"].flatMap(Int.init), overheadRows: a.int("overhead", 0))) { say($0) }
        report["cmd"] = "tools"
        report["cap"] = cap
        report["set"] = set
        report["date"] = ISO8601DateFormatter().string(from: Date())
        report["host"] = ProcessInfo.processInfo.hostName
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let out = a["json"] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: out).deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: out))
            say("wrote \(out)")
        }
        if let m = report["metrics"] { say("metrics: \(m)") }
    }
}
