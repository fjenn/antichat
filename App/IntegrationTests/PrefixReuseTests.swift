// M1.T14 AT-230 (2) + AT-269 (+ the A-M0-11 re-measure): prefix reuse through the real XPC helper at the T1 cap.
//   make test-integration-real TIER=T1 FILTER=PrefixReuseTests/testSecondTurnTTFT   (chat-9b-q4, MLX, 20 runs)
//   make test-integration-real TIER=T1 FILTER=PrefixReuseTests/testToolBlockReuse   (chat-9b-q4, 7 tools, 20 pairs)
//   make test-integration-real TIER=evil-T1 FILTER=PrefixReuseTests/testToolBlockReuse   (evil-9b, llama-server)
// Requests are composed by the Harness `PromptComposer` (base persona, date line, canonical tools) with one
// session id per chat, as TurnController sends them. TTFT is app-side (send → first content batch, XPC included);
// the engine-side value is recorded next to it. Artefacts: build/at/AT-230/ttft.json, build/at/AT-269/reuse.json
// (repo-relative, next to this source). Skipped unless ANTICHAT_TIER is T1 / evil-T1.
import AntiChatFoundation
import AntiChatHarness
import Foundation
import XCTest

final class PrefixReuseTests: XCTestCase {
    static let tierB: [String: Double] = ["T1": 9.5, "evil-T1": 9.5]
    /// NFR-C1 TTFT p50 at T1 (nfr.md §2).
    static let c1T1 = 1.5
    #if DEBUG
    static let buildConfig = "Debug"
    #else
    static let buildConfig = "Release"
    #endif

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static var modelsDir: URL {
        if let c = ProcessInfo.processInfo.environment["ANTICHAT_DEV_CACHE"], !c.isEmpty {
            return URL(fileURLWithPath: c).appendingPathComponent("Models")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AntiChat-Dev/Models")
    }

    /// M2.T12 (A-M2-T10a (d)): the content-addressed install view `<Models>/installs/<key>` that `make models-dev`
    /// materialises, else the pre-M2 `<Models>/<key>` layout.
    static func view(_ key: String) -> URL {
        let v = modelsDir.appendingPathComponent("installs").appendingPathComponent(key)
        return FileManager.default.fileExists(atPath: v.appendingPathComponent("manifest.json").path) ? v : modelsDir.appendingPathComponent(key)
    }

    /// The tier's model: chat-9b-q4 (MLX) at T1, evil-9b (GGUF via llama-server) at evil-T1.
    func tierSlot() throws -> (tier: String, slot: ModelSlot) {
        guard let tier = ProcessInfo.processInfo.environment["ANTICHAT_TIER"], Self.tierB[tier] != nil else {
            throw XCTSkip("ANTICHAT_TIER must be T1 or evil-T1 (make test-integration-real)")
        }
        let key = tier == "evil-T1" ? "evil-9b" : "chat-9b-q4"
        let dir = Self.view(key)
        guard FileManager.default.fileExists(atPath: dir.path) else { throw XCTSkip("\(key) not fetched (make models-dev TIER=\(tier))") }
        if tier == "evil-T1" {
            return (tier, ModelSlot(engine: .llama, key: key, path: dir.path, contextTokens: 8192))
        }
        return (tier, ModelSlot(engine: .mlx, key: key, path: dir.path))
    }

    func connect(_ tier: String, _ slot: ModelSlot) async throws -> EngineClient {
        let client = EngineClient(appBuild: "it-prefix-reuse")
        try await client.ensureConnected()
        try await client.setPolicy(SetPolicy(budgetB: UInt64(Self.tierB[tier]! * 1e9)))
        if let err = await client.warmup(slot) { throw err }
        return client
    }

    struct Turn {
        var ttftAppMs = -1.0
        var usage: Usage?
        var text = ""
        var error: String?
        var json: [String: Any] {
            var o: [String: Any] = ["ttft_app_ms": ttftAppMs]
            if let u = usage {
                o["ttft_engine_ms"] = u.ttftMs
                o["prompt_tokens"] = u.promptTokens
                o["cached_tokens"] = u.cachedTokens
                o["prompt_time_s"] = u.promptTime
            }
            if let e = error { o["error"] = e }
            return o
        }
    }

    static func run(_ client: EngineClient, _ req: ChatRequest) async -> Turn {
        var t = Turn()
        let sent = ContinuousClock.now
        for await b in client.chatBatches(req) {
            if b.tokens > 0, t.ttftAppMs < 0 { t.ttftAppMs = EngineTestSupport.secs(b.receivedAt - sent) * 1000 }
            for e in b.events {
                switch e {
                case .textDelta(let s): t.text += s
                case .usage(let u): t.usage = u
                case .error(let err): t.error = err.description
                default: break
                }
            }
        }
        return t
    }

    static func p50(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return -1 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func write(_ rel: String, _ obj: [String: Any]) {
        let u = repoRoot.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: u) }
        EngineTestSupport.evidence(URL(fileURLWithPath: rel).deletingPathExtension().lastPathComponent, ["written": rel])
    }

    // MARK: - Fixed prompts

    /// ≈ 55 words: with the base persona, the date line and the template ≈ 100 prompt tokens.
    static let short100 = """
        I am planning a small vegetable garden on a sunny balcony this spring. Which three vegetables are the \
        easiest to grow in containers for a complete beginner, how large should each pot be, and how often should \
        I water them during a warm week? Please keep the answer short.
        """

    /// ≈ 230 words ≈ 300 tokens (the nfr.md §2 C1 "≤ 300 new tokens" case).
    static let new300: String = {
        let s = "Here are my notes from the community garden meeting. We agreed to rotate watering duty every week, to buy two new hoses, "
            + "to label every bed with the owner's name and the planting date, and to keep the compost bins closed against rats. "
            + "Several members asked for a shared tool shed, a rain barrel near the north fence and a small budget for seeds. "
        return (0..<3).map { "Part \($0 + 1). " + s }.joined(separator: "\n") + "\nSummarise the decisions in two sentences."
    }()

    /// ≈ 2,000 tokens of history (a pasted document + a question).
    static let doc2K: String = {
        let para = "The lighthouse at the end of the harbour wall was built from granite blocks quarried on the island, and "
            + "its keeper climbed one hundred and twelve steps each evening to light the lamp, wind the clockwork that turned "
            + "the lens and write the weather, the passing ships and the state of the sea into a leather logbook. "
        return (1...27).map { "Section \($0). " + para }.joined(separator: "\n\n") + "\n\nWhat does the keeper record each evening?"
    }()

    // MARK: - AT-230 (2)

    func testSecondTurnTTFT() async throws {
        let (tier, slot) = try tierSlot()
        let client = try await connect(tier, slot)
        defer { client.disconnect() }
        let composer = PromptComposer()
        func req(_ session: UUID, _ conv: [ChatMessage], maxTokens: Int) -> ChatRequest {
            composer.compose(PromptInputs()).request(
                sessionID: session, modelSlot: slot, conversation: conv,
                sampling: Sampling(temperature: 0.6, topP: 0.95, maxTokens: maxTokens, seed: 7))
        }
        // Warm the model and the stable-prefix snapshot (one discarded chat).
        _ = await Self.run(client, req(UUID(), [ChatMessage(role: .user, content: Self.short100)], maxTokens: 8))
        var rows: [[String: Any]] = []
        var t1: [Double] = [], t2: [Double] = [], t1e: [Double] = [], t2e: [Double] = []
        var n300: [Double] = [], f300: [Double] = [], n300e: [Double] = [], f300e: [Double] = []
        let runs = 20
        for i in 0..<runs {
            // Turn 1 of a new chat with a ≈ 100-token prompt.
            let first = await Self.run(client, req(UUID(), [ChatMessage(role: .user, content: Self.short100)], maxTokens: 16))
            // A chat with a ≈ 2K-token first turn (not measured), then its second turn (measured).
            let s = UUID()
            let u1 = ChatMessage(role: .user, content: Self.doc2K)
            let a = await Self.run(client, req(s, [u1], maxTokens: 24))
            let hist = [u1, ChatMessage(role: .assistant, content: a.text)]
            let second = await Self.run(client, req(s, hist + [ChatMessage(role: .user, content: "Thanks. How many steps did he climb?")], maxTokens: 16))
            // A-M0-11: ≤ 300 new tokens with the prefix cached — new chat (system prefix cached) and follow-up (history cached).
            let new300 = await Self.run(client, req(UUID(), [ChatMessage(role: .user, content: Self.new300)], maxTokens: 16))
            let hist2 = hist + [ChatMessage(role: .user, content: "Thanks. How many steps did he climb?"),
                                ChatMessage(role: .assistant, content: second.text)]
            let follow300 = await Self.run(client, req(s, hist2 + [ChatMessage(role: .user, content: Self.new300)], maxTokens: 16))
            for (name, t) in [("turn1", first), ("turnA", a), ("turn2", second), ("new300", new300), ("followup300", follow300)] {
                XCTAssertNil(t.error, "run \(i) \(name): \(t.error ?? "")")
            }
            t1.append(first.ttftAppMs); t2.append(second.ttftAppMs)
            t1e.append(first.usage?.ttftMs ?? -1); t2e.append(second.usage?.ttftMs ?? -1)
            n300.append(new300.ttftAppMs); f300.append(follow300.ttftAppMs)
            n300e.append(new300.usage?.ttftMs ?? -1); f300e.append(follow300.usage?.ttftMs ?? -1)
            rows.append(["run": i, "turn1": first.json, "turnA_2k": a.json, "turn2": second.json, "new300": new300.json,
                         "followup300": follow300.json])
        }
        let p1 = Self.p50(t1), p2 = Self.p50(t2)
        let ratio = p2 / p1
        let out: [String: Any] = [
            "at": "AT-230", "build_config": Self.buildConfig, "leg": "(2) second-turn TTFT", "tier": tier, "model": slot.key, "engine": slot.engine.rawValue,
            "budget_b": UInt64(Self.tierB[tier]! * 1e9), "runs": runs, "date": ISO8601DateFormatter().string(from: Date()),
            "host": ProcessInfo.processInfo.hostName, "measured_on": "S4 (dev Mac); scaled values in build/perf/report.json (m1.*@<chip>)",
            "p50_ttft_app_ms": ["turn1_100tok": p1, "turn2_2k_history": p2, "new_chat_300tok_prefix_cached": Self.p50(n300),
                                "followup_300tok_history_cached": Self.p50(f300)],
            "p50_ttft_engine_ms": ["turn1_100tok": Self.p50(t1e), "turn2_2k_history": Self.p50(t2e),
                                   "new_chat_300tok_prefix_cached": Self.p50(n300e), "followup_300tok_history_cached": Self.p50(f300e)],
            "ratio_turn2_over_turn1": ratio, "limit": 1.5, "pass": ratio <= 1.5, "rows": rows,
        ]
        Self.write("build/at/AT-230/ttft\(Self.buildConfig == "Debug" ? "-debug" : "").json", out)
        XCTAssertLessThanOrEqual(ratio, 1.5, "p50 TTFT turn 2 (2K history) \(p2) ms vs turn 1 (100 tok) \(p1) ms")
    }

    // MARK: - AT-269

    func testToolBlockReuse() async throws {
        let (tier, slot) = try tierSlot()
        let client = try await connect(tier, slot)
        defer { client.disconnect() }
        let json = try String(contentsOf: Self.repoRoot.appendingPathComponent("tools/fixtures/prompt/antichat-tools-7.json"), encoding: .utf8)
        let tools = ToolSchema.fromOpenAI(json)
        XCTAssertEqual(tools.count, 7)
        let composer = PromptComposer()
        let estimate = composer.compose(PromptInputs(tools: tools)).manifest.staticPrefixTokens
        func req(_ session: UUID, _ conv: [ChatMessage]) -> ChatRequest {
            // Registration order shuffled per request: the canonical block must not change.
            composer.compose(PromptInputs(tools: tools.shuffled())).request(
                sessionID: session, modelSlot: slot, conversation: conv, sampling: Sampling(temperature: 0.6, maxTokens: 16, seed: 3),
                toolChoice: .auto)
        }
        let q1 = "Write a two-line poem about autumn leaves.", q2 = "Now write one about winter."
        // Warm with a different first message: pair 0's turn 1 must be a new chat that shares only the stable prefix
        // with what the engine already holds, like every later pair. A byte-identical repeat of the warm-up (same
        // question, same minute's time line) also reuses the start of the user turn (llama-server: its end-of-prompt
        // checkpoint at n - 4), which is not the stable prefix and which turn 2 cannot reuse (the D-022 time line
        // moves off that turn). Evidence: build/at/AT-269/root-cause-2026-11-10.json.
        _ = await Self.run(client, req(UUID(), [ChatMessage(role: .user, content: "Write a two-line poem about spring rain.")]))
        var rows: [[String: Any]] = []
        var ttft2: [Double] = []
        var failures: [String] = []
        var stable0 = 0
        let pairs = 20
        for i in 0..<pairs {
            let s = UUID()
            let r1 = req(s, [ChatMessage(role: .user, content: q1)])
            let a = await Self.run(client, r1)
            let r2 = req(s, [ChatMessage(role: .user, content: q1), ChatMessage(role: .assistant, content: a.text),
                             ChatMessage(role: .user, content: q2)])
            let b = await Self.run(client, r2)
            XCTAssertNil(a.error ?? b.error, "pair \(i)")
            let sameTools = r1.tools == r2.tools && r1.tools.map(\.name) == r1.tools.map(\.name).sorted()
            // The stable prefix (template tool slot + layers) in tokens: what a new chat's turn 1 reuses from the
            // previous chat (every pair, the warm-up for pair 0), never less than half the manifest's estimate and
            // the same for every pair (same tool set → same prefix).
            let stable = a.usage?.cachedTokens ?? 0
            let cached2 = b.usage?.cachedTokens ?? 0
            if i == 0 { stable0 = stable }
            let ok = sameTools && cached2 >= stable && stable * 2 >= estimate && stable == stable0 && cached2 > 0
            if !ok {
                failures.append("pair \(i): tools identical \(sameTools), stable \(stable) (pair 0: \(stable0)), turn-2 cached \(cached2)")
            }
            ttft2.append(b.ttftAppMs)
            rows.append(["pair": i, "turn1": a.json, "turn2": b.json, "tool_block_identical": sameTools,
                         "stable_prefix_tokens_measured": stable])
        }
        let p = Self.p50(ttft2)
        let out: [String: Any] = [
            "at": "AT-269", "build_config": Self.buildConfig, "tier": tier, "model": slot.key, "engine": slot.engine.rawValue, "tools": tools.count, "pairs": pairs,
            "stable_prefix_tokens_estimate": estimate, "p50_turn2_ttft_app_ms": p, "nfr_c1_t1_ms": Self.c1T1 * 1000,
            "pass": failures.isEmpty && p <= Self.c1T1 * 1000, "failures": failures, "rows": rows,
            "date": ISO8601DateFormatter().string(from: Date()), "host": ProcessInfo.processInfo.hostName,
        ]
        Self.write("build/at/AT-269/reuse-\(tier)\(Self.buildConfig == "Debug" ? "-debug" : "").json", out)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
        XCTAssertLessThanOrEqual(p, Self.c1T1 * 1000, "turn-2 TTFT p50 \(p) ms > NFR-C1 T1")
    }
}
