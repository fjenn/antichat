// antichat-bench-inproc chat --model K --tier-cap T --runs N [--ctx 1k|4k] --fixtures DIR --raw FILE
// S-3 baseline: the same protocol as `AntiChat -Bench chat` (App/AntiChat/BenchMode.swift) but calling
// MLXAdapter directly in this process, with no XPC and no TokenBatcher. Timing is per token arrival.
import AntiChatEngineProtocol
import AntiChatEngines
import Foundation

func secs(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

var opts: [String: String] = [:]
let argv = Array(CommandLine.arguments.dropFirst())
var i = 1
while i < argv.count {
    if argv[i].hasPrefix("--"), i + 1 < argv.count { opts[String(argv[i].dropFirst(2))] = argv[i + 1]; i += 2 } else { i += 1 }
}
let tierB: [String: Double] = ["T0": 4.0, "T1": 9.5, "T2-24": 16, "T2-32": 21, "T2-36": 24, "T3-48": 36, "T3-64": 48]
let key = opts["model"] ?? "chat-9b-q4"
let tier = opts["tier-cap"] ?? "T1"
let runs = Int(opts["runs"] ?? "20") ?? 20
let modelsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AntiChat-Dev/Models")
let fixtures = URL(fileURLWithPath: opts["fixtures"] ?? "fixtures").appendingPathComponent("prompts")
let slot = ModelSlot(engine: .mlx, key: key, path: modelsDir.appendingPathComponent(key).path)

let system = try String(contentsOf: fixtures.appendingPathComponent("bench-system.txt"), encoding: .utf8)
let user = try String(contentsOf: fixtures.appendingPathComponent("bench-300tok.txt"), encoding: .utf8)
let msgs = [ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: user)]

let out: FileHandle? = opts["raw"].flatMap { p in
    FileManager.default.createFile(atPath: p, contents: nil)
    return FileHandle(forWritingAtPath: p)
}

let adapter = MLXAdapter()
await adapter.setBudget(UInt64((tierB[tier] ?? 0) * 1e9))
_ = try await adapter.load(slot)

func runOnce(_ maxTokens: Int, seed: UInt64) async throws -> (ttft: Double, tokens: Int, decode: Double, usage: Usage?) {
    let req = ChatRequest(modelSlot: slot, messages: msgs, sampling: Sampling(temperature: 0.7, topP: 0.95, maxTokens: maxTokens, seed: seed))
    let sent = ContinuousClock.now
    var first: ContinuousClock.Instant?
    var last: ContinuousClock.Instant?
    var n = 0
    var usage: Usage?
    for await o in try await adapter.generate(req, context: GenerationContext()) {
        switch o {
        case .event(.textDelta), .event(.reasoningDelta):
            let now = ContinuousClock.now
            if first == nil { first = now }
            last = now
            n += 1
        case .event(.usage(let u)): usage = u
        default: break
        }
    }
    let ttft = first.map { secs($0 - sent) } ?? -1
    let span = (first != nil && last != nil) ? secs(last! - first!) : 0
    return (ttft, n, span > 0 ? Double(n - 1) / span : -1, usage)
}

_ = try await runOnce(32, seed: 1)  // warm
for r in 0..<runs {
    let res = try await runOnce(256, seed: UInt64(100 + r))
    let obj: [String: Any] = [
        "cmd": "chat", "ctx": "1k", "label": "inproc", "model": key, "tier": tier, "run": r, "ttft_s": res.ttft,
        "tokens": res.tokens, "decode_tps": res.decode, "peak_footprint_bytes": 0, "msgs_per_s": -1,
        "engine_decode_tps": res.usage.map { $0.generateTime > 0 ? Double($0.completionTokens) / $0.generateTime : -1 } ?? -1,
        "prompt_tokens": res.usage?.promptTokens ?? -1,
    ]
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
        out?.write(d)
        out?.write(Data("\n".utf8))
    }
    FileHandle.standardError.write(Data(String(format: "inproc run %d ttft=%.3f tokens=%d decode=%.1f\n", r, res.ttft, res.tokens, res.decode).utf8))
}
