// `antichat-bench files-warm` (M6.T03 step 4; AT-279, R-279 AC1): TTFT of a chat's first turn with a ≈ 10k-token
// document inline vs. its follow-ups, the prompt built as the app builds it (document block before the text,
// DocumentWarmth prefix pin on every request, one session per chat). Each run is a new chat; p50 over all runs of
// ttft_followup / ttft_first must be ≤ 0.30 at the tier cap.
// Same JSON (AT-279 pass conditions 2–3): `peak_footprint_bytes` = the helper's lifetime max phys_footprint
// (proc_pid_rusage) vs the tier's budget B (NFR-R1), and after each run's follow-ups a memory-pressure WARNING
// releases the pinned prefix (`probe.pinnedPrefixes` → 0) in ≤ 2 s (NFR-M4). `memory_pressure -S -l warn` needs root
// on this Mac (sysctl kern.memorypressure_manual_trigger: Operation not permitted), so the WARNING goes in through the
// helper's own seam `SetPolicy.testPressure` (the Debug `-FakePressure` path into the same PressureMonitor.handle).
//
//   antichat-bench files-warm --doc fixtures/docs/warm-10k.pdf --followups fixtures/docs/warm-10k-followups.jsonl
//                             --tier T2 --runs 20 --out <json> [--model chat-9b-q4] [--no-pressure]
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatKnowledge
import Foundation

enum FilesWarm {
    struct Q: Decodable { var question: String }

    static func run(_ a: BenchArgs) async throws {
        guard let docPath = a["doc"], let fu = a["followups"] else { throw BenchError("--doc and --followups required") }
        let tier = a["tier"] ?? "T2"
        let cap = tier == "T2" ? "T2-24" : tier
        let key = a["model"] ?? "chat-9b-q4"
        let runs = a.int("runs", 20)
        let slot = DevSlots.slot(key)
        let questions = try String(contentsOfFile: fu, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Q.self, from: Data($0.utf8)).question }
        let doc = try await ExtractionService().extract(url: URL(fileURLWithPath: docPath), kind: .pdf)
        let block = doc.promptBlock(name: URL(fileURLWithPath: docPath).lastPathComponent)
        let client = EngineClient(appBuild: "antichat-bench")
        defer { client.disconnect() }
        let ack = try await client.ensureConnected()
        let budget = UInt64((DevSlots.tierB[cap] ?? 0) * 1e9)
        if budget > 0 { try await client.setPolicy(SetPolicy(budgetB: budget)) }
        let pressure = a["no-pressure"] == nil
        if let err = await client.warmup(slot) { throw BenchError("warmup: \(err)") }
        let docTokens = await client.countTokens([block], slot: slot).first ?? 0
        let composer = PromptComposer()
        func req(_ s: UUID, _ conv: [ChatMessage]) -> ChatRequest {
            var r = composer.compose(PromptInputs(), context: VolatileContext()).request(
                sessionID: s, modelSlot: slot, conversation: conv, sampling: Sampling(temperature: 0.2, maxTokens: 48, seed: 7))
            r.prefixPin = DocumentWarmth.pin(for: r, chatID: s.uuidString)
            return r
        }
        func user(_ t: String) -> ChatMessage { ChatMessage(role: .user, content: t) }
        // Stable system prefix warm (the app has it from earlier chats).
        _ = try await PrefixBench.turn(client, req(UUID(), [user("Hello")]))
        var ratios: [Double] = []
        var firsts: [Double] = []
        var rows: [[String: Any]] = []
        var releases: [Double] = []
        for i in 0..<runs {
            let s = UUID()
            let first = DocumentContextAssembler.userContent(questions[0],
                                                             documents: [block, DocumentContextAssembler.citeInstruction])
            var conv = [user(first)]
            let t1 = try await PrefixBench.turn(client, req(s, conv))
            conv.append(ChatMessage(role: .assistant, content: t1.text))
            var follow: [Double] = []
            for q in questions.dropFirst() {
                conv.append(user(q))
                let t = try await PrefixBench.turn(client, req(s, conv))
                conv.append(ChatMessage(role: .assistant, content: t.text))
                follow.append(t.ttftAppMs)
                ratios.append(t.ttftAppMs / t1.ttftAppMs)
            }
            firsts.append(t1.ttftAppMs)
            var row: [String: Any] = ["run": i, "ttft_first_ms": t1.ttftAppMs, "ttft_followups_ms": follow,
                                      "cached_tokens_first": t1.usage?.cachedTokens ?? -1,
                                      "mtl_bytes": t1.usage?.mtlAllocatedBytes ?? -1]
            if pressure {
                // NFR-M4: WARNING → the pin is gone within 2 s; then back to normal (the model reloads next run).
                let pinned = try await client.probe().pinnedPrefixes ?? -1
                let t0 = ContinuousClock.now
                try await client.setPolicy(SetPolicy(budgetB: budget, testPressure: "warn"))
                var released = -1.0
                while Stats.secs(ContinuousClock.now - t0) < 10 {
                    if try await client.probe().pinnedPrefixes == 0 { released = Stats.secs(ContinuousClock.now - t0); break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try await client.setPolicy(SetPolicy(budgetB: budget, testPressure: "normal"))
                row["pinned_before_warn"] = pinned
                row["pin_release_s"] = released
                if released >= 0 { releases.append(released) }
                if let e = await client.warmup(slot) { throw BenchError("re-warm: \(e)") }
                _ = try await PrefixBench.turn(client, req(UUID(), [user("Hello")]))
            }
            rows.append(row)
            say(String(format: "run %d first %.0f ms, follow-ups %@", i, t1.ttftAppMs, follow.map { String(format: "%.0f", $0) }.joined(separator: " ")))
        }
        let p50 = Stats.quantile(ratios, 0.5)
        let peak = Self.lifetimePeakFootprint(pid: ack.helperPID)
        let out: [String: Any] = [
            "cmd": "files-warm", "model": key, "tier": tier, "cap": cap, "runs": runs, "doc_tokens": docTokens,
            "ratio_p50": p50, "ratio_p95": Stats.quantile(ratios, 0.95), "pass": p50 <= 0.30,
            "ttft_first_ms": Stats.summary(firsts), "budget_gb": DevSlots.tierB[cap] ?? 0,
            "budget_b_bytes": budget, "helper_pid": Int(ack.helperPID), "peak_footprint_bytes": peak,
            "peak_within_b": budget == 0 || (peak > 0 && UInt64(peak) <= budget),
            "pressure_seam": pressure ? "SetPolicy.testPressure warn (memory_pressure -S needs root)" : "off",
            "pin_release_s": Stats.summary(releases), "pin_release_max_s": releases.max() ?? -1,
            "pin_release_pass": pressure && releases.count == runs && (releases.max() ?? 99) <= 2.0,
            "date": ISO8601DateFormatter().string(from: Date()), "rows": rows,
        ]
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        let u = URL(fileURLWithPath: a["out"] ?? "files-warm.json")
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        say("ratio p50 \(p50), peak \(peak / 1_000_000) MB of B \(budget / 1_000_000) MB, pin release max \(releases.max() ?? -1) s → \(u.path)")
    }

    /// The helper's lifetime max phys_footprint (bytes; -1 when unreadable).
    static func lifetimePeakFootprint(pid: Int32) -> Int64 {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? Int64(info.ri_lifetime_max_phys_footprint) : -1
    }
}
