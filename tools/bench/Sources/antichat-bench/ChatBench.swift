// `antichat-bench chat` (M1.T05): TTFT and decode/prefill tok/s over XPC, from the engine's `usage` and from
// arrival times in this process. `--cap <tier>` sets the helper's MLX memory/wired limit to B (test-strategy §6).
// Warm model: one warmup + one discarded run before the measured runs.
import AntiChatHarness
import Foundation

enum ChatBench {
    static let defaultPrompt =
        "Explain in three short paragraphs how a lighthouse keeps ships safe at night, and why lighthouses flash in patterns."

    static func run(_ a: BenchArgs) async throws {
        guard (a["via"] ?? "xpc") == "xpc" else { throw BenchError("--via: only xpc (the in-process baseline is tools/antichat-bench-inproc)") }
        let key = a["model"] ?? "chat-0.8b"
        let cap = a["cap"] ?? "none"
        guard let gb = DevSlots.tierB[cap] else { throw BenchError("--cap \(cap): unknown tier (\(DevSlots.tierB.keys.sorted().joined(separator: ", ")))") }
        let slot = DevSlots.slot(key)
        let runs = a.int("runs", 20)
        let maxTokens = a.int("max-tokens", 256)
        let batch: BatchPolicy = {
            let p = (a["batch"] ?? "16:8").split(separator: ":").compactMap { Int($0) }
            return p.count == 2 ? BatchPolicy(windowMS: p[0], maxTokens: p[1]) : .standard
        }()
        let client = EngineClient(appBuild: "antichat-bench")
        defer { client.disconnect() }
        let ack = try await client.ensureConnected()
        let budget = UInt64(gb * 1e9)
        try await client.setPolicy(SetPolicy(budgetB: budget, batch: batch))
        say("helper pid=\(ack.helperPID) protocol=\(ack.protocolVersion) model=\(slot.key) cap=\(cap) B=\(budget)")
        let t0 = ContinuousClock.now
        if let err = await client.warmup(slot) { throw BenchError("warmup: \(err)") }
        let warmupS = Stats.secs(ContinuousClock.now - t0)
        let prompt = a["prompt"] ?? defaultPrompt
        func request(_ seed: UInt64, _ n: Int) -> ChatRequest {
            ChatRequest(
                modelSlot: slot, messages: [ChatMessage(role: .user, content: prompt)],
                sampling: Sampling(temperature: 0.7, topP: 0.95, maxTokens: n, seed: seed))
        }
        _ = try await one(client, request(1, 32))  // discarded warm run
        var rows: [[String: Any]] = []
        var ttftApp: [Double] = [], ttftEngine: [Double] = [], decode: [Double] = [], prefill: [Double] = [], arrival: [Double] = [], mps: [Double] = []
        for i in 0..<runs {
            let r = try await one(client, request(UInt64(100 + i), maxTokens))
            rows.append(r.row(i))
            if let v = r.ttftAppMs { ttftApp.append(v) }
            if let u = r.usage {
                ttftEngine.append(u.ttftMs)
                decode.append(u.tokPerSec)
                prefill.append(u.prefillTokPerSec)
            }
            if let v = r.arrivalTokPerSec { arrival.append(v) }
            if let v = r.msgsPerSec { mps.append(v) }
            say(String(format: "run %d ttft_app=%.1f ms decode=%.1f tok/s (arrival %.1f) msgs/s=%.1f %@", i, r.ttftAppMs ?? -1,
                       r.usage?.tokPerSec ?? -1, r.arrivalTokPerSec ?? -1, r.msgsPerSec ?? -1, r.finish ?? r.error ?? "?"))
        }
        let out: [String: Any] = [
            "cmd": "chat", "via": "xpc", "model": slot.key, "cap": cap, "budget_b": budget, "runs": runs, "max_tokens": maxTokens,
            "batch": "\(batch.windowMS):\(batch.maxTokens)", "helper_pid": Int(ack.helperPID), "warmup_s": warmupS,
            "date": ISO8601DateFormatter().string(from: Date()), "host": ProcessInfo.processInfo.hostName,
            "summary": [
                "ttft_app_ms": Stats.summary(ttftApp), "ttft_engine_ms": Stats.summary(ttftEngine),
                "decode_tok_s": Stats.summary(decode), "prefill_tok_s": Stats.summary(prefill),
                "arrival_decode_tok_s": Stats.summary(arrival), "xpc_msgs_per_s": Stats.summary(mps),
            ],
            "rows": rows,
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

    struct Run {
        var ttftAppMs: Double?
        var usage: Usage?
        var tokens = 0
        var messages = 0
        var deltaMessages = 0
        var first: ContinuousClock.Instant?
        var last: ContinuousClock.Instant?
        var finish: String?
        var error: String?

        var arrivalTokPerSec: Double? {
            guard let f = first, let l = last, tokens > 1 else { return nil }
            let s = Stats.secs(l - f)
            return s > 0 ? Double(tokens - 1) / s : nil
        }

        var msgsPerSec: Double? {
            guard let f = first, let l = last, deltaMessages > 1 else { return nil }
            let s = Stats.secs(l - f)
            return s > 0 ? Double(deltaMessages - 1) / s : nil
        }

        func row(_ i: Int) -> [String: Any] {
            var o: [String: Any] = ["run": i, "tokens": tokens, "messages": messages]
            if let v = ttftAppMs { o["ttft_app_ms"] = v }
            if let v = arrivalTokPerSec { o["arrival_decode_tok_s"] = v }
            if let v = msgsPerSec { o["xpc_msgs_per_s"] = v }
            if let u = usage {
                o["ttft_engine_ms"] = u.ttftMs
                o["decode_tok_s"] = u.tokPerSec
                o["prefill_tok_s"] = u.prefillTokPerSec
                o["prompt_tokens"] = u.promptTokens
                o["cached_tokens"] = u.cachedTokens
                o["completion_tokens"] = u.completionTokens
                o["gpu_peak_bytes"] = u.gpuPeakBytes
                // M9.T05 C1 prefill A/B: MLX cache / active bytes at request start and end, and the cache limit.
                if let v = u.mlxCacheBytesStart { o["mlx_cache_start"] = v }
                if let v = u.mlxActiveBytesStart { o["mlx_active_start"] = v }
                if let v = u.mlxCacheBytesEnd { o["mlx_cache_end"] = v }
                if let v = u.mlxActiveBytesEnd { o["mlx_active_end"] = v }
                if let v = u.mlxCacheLimitBytes { o["mlx_cache_limit"] = v }
            }
            if let f = finish { o["finish"] = f }
            if let e = error { o["error"] = e }
            return o
        }
    }

    static func one(_ client: EngineClient, _ req: ChatRequest) async throws -> Run {
        var r = Run()
        let sent = ContinuousClock.now
        for await b in client.chatBatches(req) {
            r.messages += 1
            if b.tokens > 0 {
                if r.first == nil {
                    r.first = b.receivedAt
                    r.ttftAppMs = Stats.secs(b.receivedAt - sent) * 1000
                }
                r.last = b.receivedAt
                r.tokens += b.tokens
                r.deltaMessages += 1
            }
            for e in b.events {
                switch e {
                case .usage(let u): r.usage = u
                case .done(let f): r.finish = f.rawValue
                case .error(let err): r.error = err.description
                default: break
                }
            }
        }
        if let e = r.error { throw BenchError("run failed: \(e)") }
        return r
    }
}

struct BenchError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}
