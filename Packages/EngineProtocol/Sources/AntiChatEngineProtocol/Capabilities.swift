// What an engine (or the helper as a whole) can do (architecture.md §2 "engine capability descriptors").
// Sent in `HelloAck`; a ScriptedEngine script may override it with a `{"t":"caps",…}` header line.
import Foundation

/// Which runtime a request runs on.
public enum EngineKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// mlx-swift-lm in the helper (`MLXAdapter`).
    case mlx
    /// GGUF through a supervised single-model llama-server on a unix socket (`LlamaServerAdapter`, M1.T12).
    case llama
    /// JSONL replay (`ScriptedEngine`); `ModelSlot.path` is the script. Test/UI-dev only.
    case scripted
    /// M3.T01: Core ML models on the ANE (FluidAudio voice set, smart-turn); loaded by the helper's voice service.
    /// Never serves chat; the scheduler only accounts their footprint and lifetime.
    case coreml
}

/// DeltaBatcher window (architecture §4.3: 16 ms / 8 tokens; AT-M0-04 fallback 33 ms / 16 tokens).
public struct BatchPolicy: Codable, Sendable, Hashable {
    public var windowMS: Int
    public var maxTokens: Int

    public init(windowMS: Int = 16, maxTokens: Int = 8) {
        self.windowMS = windowMS
        self.maxTokens = maxTokens
    }

    public static let standard = BatchPolicy()
    public static let fallback = BatchPolicy(windowMS: 33, maxTokens: 16)
}

public struct EngineCapabilities: Codable, Sendable, Hashable {
    public var engines: [EngineKind]
    /// The model can think before answering (Think harder, M1.T15).
    public var reasoning: Bool
    /// Native tool calls (`toolCallDelta` / `toolCallDone`).
    public var toolCalls: Bool
    public var vision: Bool
    /// Context window of the model, when known.
    public var contextTokens: Int?
    /// Grammar-constrained decoding (`ChatRequest.grammar`; llama-server only).
    public var grammar: Bool
    public var batch: BatchPolicy
    /// M0 spike lanes still served by the helper (`voice.spike`, `image.sdserver`, `video.spike`).
    public var lanes: [String]

    public init(
        engines: [EngineKind] = [], reasoning: Bool = true, toolCalls: Bool = true, vision: Bool = false,
        contextTokens: Int? = nil, grammar: Bool = false, batch: BatchPolicy = .standard, lanes: [String] = []
    ) {
        self.engines = engines
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.vision = vision
        self.contextTokens = contextTokens
        self.grammar = grammar
        self.batch = batch
        self.lanes = lanes
    }
}
