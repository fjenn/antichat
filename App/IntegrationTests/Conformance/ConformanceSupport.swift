// M1.T13 conformance plumbing: engine × family rows, case files, one traced request through the real helper, and
// the per-row report writer (`build/at/AT-229/rows/<row>.json`, merged into `conformance.json` by
// tools/at/conformance-report.py). Rows by TIER (make test-integration-real TIER=…; `ANTICHAT_CONFORMANCE_ROWS`
// = comma list overrides): stub → tiny-mlx (plumbing), T1 → Qwen3.5 0.8B + 9B, T3 → Qwen3.6 35B-A3B + Gemma 4
// 26B-A4B, evil-T1 → Qwen3.5 9B GGUF on llama-server.
import AntiChatFoundation
import AntiChatHarness
import Foundation
import XCTest

struct ConformanceRow: Sendable {
    var id: String
    var engine: String
    var family: String
    var slot: ModelSlot
    /// Tier cap B in GB (SetPolicy; hardware-tiers §2.2).
    var capGB: Double
    var cap: String
    /// Plumbing-only row (the random-weight tiny fixture): its answers are meaningless, so only the contract parts
    /// (event ordering, nothing after the terminal, no engine error, cancel latency) are asserted.
    var plumbing = false
}

enum Conformance {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    /// The fixtures repo's `prompts/` ($ANTICHAT_FIXTURES, else the `fixtures/` submodule); the staged copy in
    /// `tools/fixtures/staged/prompts/` is the fallback when the submodule is not checked out (same rule as
    /// StreamPersisterTests for `scripts/`).
    static var casesDir: URL {
        let fixtures = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent("fixtures")
        let dir = fixtures.appendingPathComponent("prompts")
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("conformance/tools-50.jsonl").path) { return dir }
        return repoRoot.appendingPathComponent("tools/fixtures/staged/prompts")
    }
    static let outDir = repoRoot.appendingPathComponent("build/at/AT-229/rows")

    static var env: [String: String] { ProcessInfo.processInfo.environment }

    static var modelsDir: URL {
        if let c = env["ANTICHAT_DEV_CACHE"], !c.isEmpty { return URL(fileURLWithPath: c).appendingPathComponent("Models") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AntiChat-Dev/Models")
    }

    /// M2.T12 (A-M2-T10a (d)): the content-addressed install view `<Models>/installs/<key>` that `make models-dev`
    /// materialises, else the pre-M2 `<Models>/<key>` layout.
    static func view(_ key: String) -> URL {
        let v = modelsDir.appendingPathComponent("installs").appendingPathComponent(key)
        return FileManager.default.fileExists(atPath: v.appendingPathComponent("manifest.json").path) ? v : modelsDir.appendingPathComponent(key)
    }

    static func mlx(_ key: String, family: String, cap: String, gb: Double, ctx: Int) -> ConformanceRow? {
        let d = view(key)
        guard FileManager.default.fileExists(atPath: d.appendingPathComponent("config.json").path) else { return nil }
        return ConformanceRow(id: "mlx-\(key)", engine: "mlx", family: family,
                              slot: ModelSlot(engine: .mlx, key: key, path: d.path, contextTokens: ctx), capGB: gb, cap: cap)
    }

    static var allRows: [String: () -> ConformanceRow?] {
        [
            "tiny": {
                guard let f = env["ANTICHAT_FIXTURES"] else { return nil }
                let d = URL(fileURLWithPath: f).appendingPathComponent("stub-models/tiny-mlx-llm")
                guard FileManager.default.fileExists(atPath: d.appendingPathComponent("config.json").path) else { return nil }
                return ConformanceRow(id: "mlx-tiny", engine: "mlx", family: "tiny (Qwen3 Hermes JSON, plumbing)",
                                      slot: ModelSlot(engine: .mlx, key: "tiny-mlx-llm", path: d.path), capGB: 0, cap: "none",
                                      plumbing: true)
            },
            "chat-0.8b": { mlx("chat-0.8b", family: "Qwen3.5 0.8B", cap: "T1", gb: 9.5, ctx: 8192) },
            "chat-9b-q4": { mlx("chat-9b-q4", family: "Qwen3.5 9B", cap: "T1", gb: 9.5, ctx: 16384) },
            "chat-35b-q4": { mlx("chat-35b-q4", family: "Qwen3.6 35B-A3B", cap: "T3", gb: 36, ctx: 65536) },
            "chat-g26": { mlx("chat-g26", family: "Gemma 4 26B-A4B", cap: "T2-32", gb: 21, ctx: 32768) },
            // M2.T15 (AT-239 T3): the T3 Evil model, same family and template as chat-35b-q4 (T06 same-family rule).
            "evil-35b-q4": { mlx("evil-35b-q4", family: "Qwen3.6 35B-A3B Heretic (evil-35b-q4)", cap: "T3", gb: 36, ctx: 65536) },
            "evil-9b": {
                let f = view("evil-9b").appendingPathComponent("Qwen3.5-9B-Ultra-Uncensored-Heretic-Q4_K_M.gguf")
                guard FileManager.default.fileExists(atPath: f.path) else { return nil }
                return ConformanceRow(id: "llama-evil-9b", engine: "llama", family: "Qwen3.5 9B GGUF (evil-9b)",
                                      slot: ModelSlot(engine: .llama, key: "evil-9b", path: f.path, contextTokens: 16384),
                                      capGB: 9.5, cap: "T1")
            },
        ]
    }

    static var rows: [ConformanceRow] {
        let keys: [String]
        if let list = env["ANTICHAT_CONFORMANCE_ROWS"], !list.isEmpty {
            keys = list.split(separator: ",").map(String.init)
        } else {
            switch env["ANTICHAT_TIER"] ?? (env["ANTICHAT_ENGINES"] == "stub" ? "stub" : "") {
            case "T1": keys = ["chat-0.8b", "chat-9b-q4"]
            case "T3": keys = ["chat-35b-q4", "chat-g26"]
            case "evil-T1": keys = ["evil-9b"]
            case "evil-T3": keys = ["evil-35b-q4"]
            case "stub": keys = ["tiny"]
            default: keys = []
            }
        }
        return keys.compactMap { allRows[$0]?() }
    }

    static func loadJSONL(_ name: String) throws -> [[String: Any]] {
        let text = try String(contentsOf: casesDir.appendingPathComponent(name), encoding: .utf8)
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    static func messages(_ raw: Any?) -> [ChatMessage] {
        (raw as? [[String: Any]] ?? []).compactMap { m in
            guard let r = (m["role"] as? String).flatMap(ChatMessage.Role.init(rawValue:)) else { return nil }
            return ChatMessage(role: r, content: m["content"] as? String ?? "")
        }
    }

    static func tools(_ raw: Any?) -> [ToolSchema] {
        guard let arr = raw as? [Any], !arr.isEmpty, let d = try? JSONSerialization.data(withJSONObject: arr) else { return [] }
        return ToolSchema.fromOpenAI(String(decoding: d, as: UTF8.self))
    }

    static func connect(_ row: ConformanceRow, build: String) async throws -> EngineClient {
        let client = EngineClient(appBuild: build)
        _ = try await client.ensureConnected()
        try await client.setPolicy(SetPolicy(budgetB: UInt64(row.capGB * 1e9)))
        if let err = await client.warmup(row.slot) { throw err }
        return client
    }

    /// One request; events in arrival order with arrival times; `cancelWhen` may cancel mid-stream (returns the
    /// cancel instant). A safety timeout cancels a stuck stream.
    struct Run {
        var trace = ToolStreamTrace()
        var arrivals: [ContinuousClock.Instant] = []
        var lifecycle: [LifecycleEvent] = []
        var sentAt = ContinuousClock.now
        var cancelledAt: ContinuousClock.Instant?
        var terminalAt: ContinuousClock.Instant?
        /// Events that arrived after the terminal one (must stay empty).
        var trailing = 0
        var wallS: Double { terminalAt.map { EngineTestSupport.secs($0 - sentAt) } ?? -1 }
        var cancelLatencyMs: Double? {
            guard let c = cancelledAt, let t = terminalAt else { return nil }
            return EngineTestSupport.secs(t - c) * 1000
        }
    }

    static func run(
        _ client: EngineClient, _ req: ChatRequest, timeout: Duration = .seconds(240),
        cancelWhen: ((Run, EngineBatch) -> Bool)? = nil, cancelAfter: Duration? = nil,
        armTimer: ((Run, EngineBatch) -> Duration?)? = nil
    ) async -> Run {
        var r = Run()
        r.sentAt = .now
        let stream = client.chatBatches(req)
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { client.cancel(req.requestID) }
        }
        func arm(_ d: Duration) -> Task<Void, Never> {
            Task {
                try? await Task.sleep(for: d)
                if !Task.isCancelled { client.cancel(req.requestID) }
            }
        }
        var timer: Task<Void, Never>? = cancelAfter.map(arm)
        var timerCancelAt: ContinuousClock.Instant? = cancelAfter.map { r.sentAt + $0 }
        for await b in stream {
            if r.terminalAt != nil {
                r.trailing += b.events.count
                continue
            }
            r.lifecycle += b.lifecycle
            for e in b.events {
                r.trace.events.append(e)
                r.arrivals.append(b.receivedAt)
            }
            if r.trace.terminal != nil {
                r.terminalAt = b.receivedAt
                // Events after the terminal one inside the same batch.
                if let i = r.trace.events.firstIndex(where: \.isTerminal) { r.trailing += r.trace.events.count - 1 - i }
                if r.cancelledAt == nil, let t = timerCancelAt, t <= b.receivedAt { r.cancelledAt = t }
                continue
            }
            if timer == nil, let f = armTimer, let d = f(r, b) {
                timer = arm(d)
                timerCancelAt = .now + d
            }
            if r.cancelledAt == nil, let f = cancelWhen, f(r, b) {
                timer?.cancel()
                timerCancelAt = nil
                r.cancelledAt = .now
                client.cancel(req.requestID)
            }
        }
        watchdog.cancel()
        timer?.cancel()
        return r
    }

    static func write(_ name: String, _ obj: [String: Any]) {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let url = outDir.appendingPathComponent("\(name).json")
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            do { try d.write(to: url) } catch {
                let alt = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).json")
                try? d.write(to: alt)
                print("conformance: could not write \(url.path) (\(error)); wrote \(alt.path)")
            }
        }
        print("conformance report \(name) → \(url.path)")
    }

    static func eventSummary(_ e: EngineEvent) -> String {
        switch e {
        case .textDelta(let s): "text:\(s.prefix(40))"
        case .reasoningDelta(let s): "reasoning:\(s.prefix(40))"
        case .toolCallDelta(let id, let n, let a): "callDelta:\(id):\(n ?? "-"):\(a.prefix(60))"
        case .toolCallDone(let id, let n, let a): "callDone:\(id):\(n):\(a.prefix(200))"
        case .usage(let u): "usage:p\(u.promptTokens)c\(u.completionTokens)tps\(Int(u.tokPerSec))k\(u.toolCallsConstrained ?? -1)"
        case .done(let r): "done:\(r.rawValue)"
        case .error(let err): "error:\(err)"
        }
    }

    static var date: String { ISO8601DateFormatter().string(from: Date()) }
}
