// `antichat-bench prefix` (M1.T14; A-M0-11 re-measure): the PrefixReuseTests TTFT scenarios against any app build
// (the hosted integration tests only run Debug, whose -Onone MLX glue inflates TTFT). Requests are composed by the
// Harness PromptComposer with one session id per chat, as TurnController sends them.
//
//   antichat-bench prefix --model chat-9b-q4 --cap T1 --runs 20 --json <out> [--app build/AntiChat.app]
//
// Scenarios (TTFT app-side = send → first content batch; engine-side from `usage`):
//   turn1_100tok      new chat, ≈ 100-token prompt (stable prefix cached from an earlier chat)
//   turn2_2k_history  second turn of a chat whose first turn was a ≈ 2K-token document (history cached)
//   new_chat_300tok   new chat, ≈ 300 new tokens, stable prefix cached (nfr.md §2 C1 condition)
//   followup_300tok   ≈ 300 new tokens after the 2K history (history cached), composed one minute later (D-022:
//                     a new minute must keep the system turn + history; only the time line is new)
//   cold_2k           the chat's first, uncached ≈ 2K-token turn (reference)
import AntiChatHarness
import Foundation

enum PrefixBench {
    static let short100 = """
        I am planning a small vegetable garden on a sunny balcony this spring. Which three vegetables are the \
        easiest to grow in containers for a complete beginner, how large should each pot be, and how often should \
        I water them during a warm week? Please keep the answer short.
        """
    static let new300: String = {
        let s = "Here are my notes from the community garden meeting. We agreed to rotate watering duty every week, to buy two new hoses, "
            + "to label every bed with the owner's name and the planting date, and to keep the compost bins closed against rats. "
            + "Several members asked for a shared tool shed, a rain barrel near the north fence and a small budget for seeds. "
        return (0..<3).map { "Part \($0 + 1). " + s }.joined(separator: "\n") + "\nSummarise the decisions in two sentences."
    }()
    static let doc2K: String = {
        let para = "The lighthouse at the end of the harbour wall was built from granite blocks quarried on the island, and "
            + "its keeper climbed one hundred and twelve steps each evening to light the lamp, wind the clockwork that turned "
            + "the lens and write the weather, the passing ships and the state of the sea into a leather logbook. "
        return (1...27).map { "Section \($0). " + para }.joined(separator: "\n\n") + "\n\nWhat does the keeper record each evening?"
    }()

    struct Turn {
        var ttftAppMs = -1.0
        var usage: Usage?
        var text = ""
        var row: [String: Any] {
            var o: [String: Any] = ["ttft_app_ms": ttftAppMs]
            if let u = usage {
                o["ttft_engine_ms"] = u.ttftMs
                o["prompt_tokens"] = u.promptTokens
                o["cached_tokens"] = u.cachedTokens
            }
            return o
        }
    }

    static func turn(_ client: EngineClient, _ req: ChatRequest) async throws -> Turn {
        var t = Turn()
        let sent = ContinuousClock.now
        for await b in client.chatBatches(req) {
            if b.tokens > 0, t.ttftAppMs < 0 { t.ttftAppMs = Stats.secs(b.receivedAt - sent) * 1000 }
            for e in b.events {
                switch e {
                case .textDelta(let s): t.text += s
                case .usage(let u): t.usage = u
                case .error(let err): throw BenchError("turn failed: \(err)")
                default: break
                }
            }
        }
        return t
    }

    static func run(_ a: BenchArgs) async throws {
        let key = a["model"] ?? "chat-9b-q4"
        let cap = a["cap"] ?? "T1"
        guard let gb = DevSlots.tierB[cap] else { throw BenchError("--cap \(cap): unknown tier") }
        let slot = DevSlots.slot(key)
        let runs = a.int("runs", 20)
        let client = EngineClient(appBuild: "antichat-bench")
        defer { client.disconnect() }
        _ = try await client.ensureConnected()
        try await client.setPolicy(SetPolicy(budgetB: UInt64(gb * 1e9)))
        if let err = await client.warmup(slot) { throw BenchError("warmup: \(err)") }
        let composer = PromptComposer()
        func req(_ s: UUID, _ conv: [ChatMessage], _ n: Int, later: Double = 0) -> ChatRequest {
            composer.compose(PromptInputs(), context: VolatileContext(now: Date().addingTimeInterval(later))).request(
                sessionID: s, modelSlot: slot, conversation: conv,
                sampling: Sampling(temperature: 0.6, topP: 0.95, maxTokens: n, seed: 7))
        }
        func user(_ t: String) -> ChatMessage { ChatMessage(role: .user, content: t) }
        _ = try await turn(client, req(UUID(), [user(short100)], 8))  // warm model + stable-prefix snapshot
        var series: [String: [Double]] = [:], engine: [String: [Double]] = [:]
        var rows: [[String: Any]] = []
        for i in 0..<runs {
            let t1 = try await turn(client, req(UUID(), [user(short100)], 16))
            let s = UUID()
            let a1 = try await turn(client, req(s, [user(doc2K)], 24))
            let hist = [user(doc2K), ChatMessage(role: .assistant, content: a1.text)]
            let q = "Thanks. How many steps did he climb?"
            let t2 = try await turn(client, req(s, hist + [user(q)], 16))
            let n3 = try await turn(client, req(UUID(), [user(new300)], 16))
            let f3 = try await turn(client, req(s, hist + [user(q), ChatMessage(role: .assistant, content: t2.text), user(new300)], 16, later: 60))
            let named = [("turn1_100tok", t1), ("cold_2k", a1), ("turn2_2k_history", t2), ("new_chat_300tok", n3), ("followup_300tok", f3)]
            var row: [String: Any] = ["run": i]
            for (n, t) in named {
                series[n, default: []].append(t.ttftAppMs)
                engine[n, default: []].append(t.usage?.ttftMs ?? -1)
                row[n] = t.row
            }
            rows.append(row)
            say(String(format: "run %d turn1 %.0f ms, turn2 %.0f ms, new300 %.0f ms, follow300 %.0f ms", i, t1.ttftAppMs, t2.ttftAppMs,
                       n3.ttftAppMs, f3.ttftAppMs))
        }
        let p1 = Stats.quantile(series["turn1_100tok"]!, 0.5), p2 = Stats.quantile(series["turn2_2k_history"]!, 0.5)
        let out: [String: Any] = [
            "cmd": "prefix", "model": slot.key, "cap": cap, "runs": runs, "date": ISO8601DateFormatter().string(from: Date()),
            "host": ProcessInfo.processInfo.hostName,
            "ttft_app_ms": series.mapValues { Stats.summary($0) }, "ttft_engine_ms": engine.mapValues { Stats.summary($0) },
            "ratio_turn2_over_turn1": p2 / p1, "rows": rows,
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
