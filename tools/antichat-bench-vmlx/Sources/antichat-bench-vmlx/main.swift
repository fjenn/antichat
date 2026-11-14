// antichat-bench-vmlx chat --model K --tier-cap T --runs N --fixtures DIR --raw FILE
// S-4 (M0.T04 step 12): the MLXAdapter protocol of tools/antichat-bench-inproc on osaurus-ai/vmlx-swift
// @ 88e25dc673. Shim notes (names that differ from mlx-swift-lm @ f5b0677): load = top-level
// `loadModelContainer(from: URL, using:)` (factories iterate LLM→VLM themselves); tokenizer =
// a hand bridge over `VMLXTokenizers.AutoTokenizer` (same mapping as vmlx's `#adaptHuggingFaceTokenizer`, incl. its
// incremental byte-level decoder; the Gemma/DeepSeek template special cases are omitted, Qwen3.5 does not use them); `generate(input:parameters:context:)` has no `tools:`
// argument; `Generation` adds `.prefillProgress`.
import Foundation
import MLX
import MLXRandom
import MLXLLM
import MLXLMCommon
import MLXVLM
import VMLXTokenizers

struct VTokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any VMLXTokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var incrementalByteLevelDecoder: (@Sendable (Int) -> MLXLMCommon.ByteLevelDecodingPiece)? {
        guard let decoder = upstream.incrementalByteLevelDecoder else { return nil }
        return { id in
            switch decoder(id) {
            case .bytes(let b): return .bytes(b)
            case .literal(let t): return .literal(t)
            case .ignored: return .ignored
            }
        }
    }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}

struct VTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        VTokenizerBridge(upstream: try await VMLXTokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

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
let system = try String(contentsOf: fixtures.appendingPathComponent("bench-system.txt"), encoding: .utf8)
let user = try String(contentsOf: fixtures.appendingPathComponent("bench-300tok.txt"), encoding: .utf8)

let out: FileHandle? = opts["raw"].flatMap { p in
    FileManager.default.createFile(atPath: p, contents: nil)
    return FileHandle(forWritingAtPath: p)
}

if let b = tierB[tier] {
    Memory.memoryLimit = Int(b * 1e9)
    Memory.cacheLimit = Int(b * 1e9 / 4)
}
let t0 = ContinuousClock.now
let container = try await loadModelContainer(from: modelsDir.appendingPathComponent(key), using: VTokenizerLoader())
let loadS = secs(ContinuousClock.now - t0)
FileHandle.standardError.write(Data("vmlx loaded \(key) in \(loadS)s\n".utf8))

func runOnce(_ maxTokens: Int, seed: UInt64) async throws -> (ttft: Double, tokens: Int, decode: Double, engineTPS: Double, prompt: Int) {
    let input = UserInput(chat: [.system(system), .user(user)], additionalContext: ["enable_thinking": false])
    let params = GenerateParameters(maxTokens: maxTokens, temperature: 0.7, topP: 0.95)
    MLXRandom.seed(seed)  // vmlx GenerateParameters has no `seed`; seed the global RNG instead
    let p = params
    let sent = ContinuousClock.now
    let lm = try await container.prepare(input: input)
    let stream: AsyncStream<Generation> = try await container.perform(nonSendable: lm) { ctx, lm in
        try MLXLMCommon.generate(input: lm, parameters: p, context: ctx)
    }
    var first: ContinuousClock.Instant?
    var last: ContinuousClock.Instant?
    var n = 0
    var tps = -1.0
    var prompt = -1
    for await g in stream {
        switch g {
        case .chunk, .reasoning:
            let now = ContinuousClock.now
            if first == nil { first = now }
            last = now
            n += 1
        case .info(let info):
            tps = info.tokensPerSecond
            prompt = info.promptTokenCount
        default: break
        }
    }
    let span = (first != nil && last != nil) ? secs(last! - first!) : 0
    return (first.map { secs($0 - sent) } ?? -1, n, span > 0 ? Double(n - 1) / span : -1, tps, prompt)
}

_ = try await runOnce(32, seed: 1)
for r in 0..<runs {
    let res = try await runOnce(256, seed: UInt64(100 + r))
    let obj: [String: Any] = [
        "cmd": "chat", "ctx": "1k", "label": "vmlx", "model": key, "tier": tier, "run": r, "ttft_s": res.ttft,
        "tokens": res.tokens, "decode_tps": res.decode, "engine_decode_tps": res.engineTPS, "prompt_tokens": res.prompt,
        "peak_footprint_bytes": 0, "msgs_per_s": -1, "load_s": loadS,
    ]
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
        out?.write(d)
        out?.write(Data("\n".utf8))
    }
    FileHandle.standardError.write(Data(String(format: "vmlx run %d ttft=%.3f tokens=%d decode=%.1f\n", r, res.ttft, res.tokens, res.decode).utf8))
}
