// Shared helpers for the XPC integration suites (M1.T05): real AntiChatEngine.xpc, ScriptedEngine in the helper
// (`ModelSlot.engine == .scripted`, scripts written to a temp file so the suites need no fixture checkout).
import AntiChatFoundation
import AntiChatHarness
import Foundation
import Synchronization
import XCTest

enum EngineTestSupport {
    static func script(_ lines: [String], name: String = "it") throws -> ModelSlot {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: u, atomically: true, encoding: .utf8)
        return .scripted(u.path, key: "scripted-\(name)")
    }

    static func longStream(tokens: Int = 3000, delayMs: Int = 5) throws -> ModelSlot {
        try script([#"{"t":"textDelta","v":" word","delayMs":\#(delayMs),"repeat":\#(tokens)}"#], name: "long")
    }

    static func ask(_ slot: ModelSlot, _ text: String = "hello") -> ChatRequest {
        ChatRequest(modelSlot: slot, messages: [ChatMessage(role: .user, content: text)])
    }

    /// Collects every batch of one request, with a hang guard: the drain fails when no batch arrived for `timeout`
    /// (a stalled stream), or after `10 × timeout` in total. The guard is on progress, not on total time, so a
    /// stream that is merely slow on a loaded host (the shared CI box runs at load 5–30) is not reported as a hang
    /// (flake 2026-11-04: the tiny-MLX 300-token leg crossed a 30 s total bar right after the helper respawns).
    static func drain(_ stream: AsyncStream<EngineBatch>, timeout: Duration = .seconds(30)) async throws -> [EngineBatch] {
        struct Progress { var last = ContinuousClock.now, batches = 0, tokens = 0 }
        let progress = Mutex(Progress())
        let start = ContinuousClock.now
        return try await withThrowingTaskGroup(of: [EngineBatch].self) { g in
            g.addTask {
                var out: [EngineBatch] = []
                for await b in stream {
                    out.append(b)
                    progress.withLock { p in
                        p.last = .now
                        p.batches += 1
                        p.tokens += b.tokens
                    }
                }
                return out
            }
            g.addTask {
                while true {
                    try await Task.sleep(for: .milliseconds(250))
                    let idle = ContinuousClock.now - progress.withLock(\.last)
                    if idle > timeout || ContinuousClock.now - start > timeout * 10 { throw CancellationError() }
                }
            }
            do {
                let r = try await g.next()!
                g.cancelAll()
                return r
            } catch {
                g.cancelAll()
                let p = progress.withLock { $0 }
                XCTFail("stream stalled: no batch for \(ContinuousClock.now - p.last) (guard \(timeout)); \(p.batches) batches, \(p.tokens) tokens in \(ContinuousClock.now - start)")
                return []
            }
        }
    }

    static func secs(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

    static func processAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    static var tinyMLX: ModelSlot? {
        guard let f = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"] else { return nil }
        let d = URL(fileURLWithPath: f).appendingPathComponent("stub-models/tiny-mlx-llm")
        guard FileManager.default.fileExists(atPath: d.appendingPathComponent("config.json").path) else { return nil }
        return ModelSlot(engine: .mlx, key: "tiny-mlx-llm", path: d.path)
    }

    /// The tiny model with no reachable end-of-sequence token (M1.T13 fix for the XPCCancelTests flake: the random
    /// tiny weights sample `<|im_end|>` after a few tokens now and then, so a run could finish before Stop arrived).
    /// A temp copy whose config/generation_config point `eos_token_id` past the 512-token vocabulary and whose
    /// tokenizer has no `eos_token` generates exactly `maxTokens` tokens, deterministically, so every cancel lands
    /// mid-stream. Weights are symlinked; the model itself is unchanged.
    static var tinyMLXNoEOS: ModelSlot? {
        guard let tiny = tinyMLX else { return nil }
        let src = URL(fileURLWithPath: tiny.path)
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("tiny-mlx-llm-noeos")
        let fm = FileManager.default
        try? fm.removeItem(at: dst)
        do {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            for f in try fm.contentsOfDirectory(atPath: src.path) {
                let from = src.appendingPathComponent(f), to = dst.appendingPathComponent(f)
                guard ["config.json", "generation_config.json", "tokenizer_config.json"].contains(f) else {
                    try fm.createSymbolicLink(at: to, withDestinationURL: from)
                    continue
                }
                var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: from)) as? [String: Any] ?? [:]
                if f == "tokenizer_config.json" { obj["eos_token"] = NSNull() } else { obj["eos_token_id"] = 100_000 }
                try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]).write(to: to)
            }
        } catch {
            return nil
        }
        return ModelSlot(engine: .mlx, key: "tiny-mlx-llm-noeos", path: dst.path)
    }

    /// Writes a small JSON evidence file next to the test logs (`build/at/M1-T05/<name>.json` under the repo when
    /// `ANTICHAT_EVIDENCE_DIR` is set by the make target, else the temp dir).
    static func evidence(_ name: String, _ obj: [String: Any]) {
        let dir = ProcessInfo.processInfo.environment["ANTICHAT_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("\(name).json"))
        }
        print("evidence \(name): \(obj)")
    }
}
