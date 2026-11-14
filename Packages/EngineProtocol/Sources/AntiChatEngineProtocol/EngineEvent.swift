// The adapter contract (R-229 AC1; M1.T05 step 1): exactly seven events. Non-content signals (load state,
// load/prefill progress) travel as `LifecycleEvent`s on a separate stream; M0 spike media results as
// `MediaEvent`s. Every request stream ends with exactly one terminal event: `done(_)` or `error(_)`.
import AntiChatFoundation
import Foundation

public enum FinishReason: String, Codable, Sendable, Hashable {
    /// End of turn (EOS / stop sequence).
    case stop
    /// `sampling.maxTokens` reached.
    case length
    /// The turn ended with tool calls for the harness to run.
    case toolCalls
    /// `Cancel{requestID}` or the consumer went away.
    case cancelled
}

public struct Usage: Codable, Sendable, Hashable {
    public var promptTokens: Int
    public var completionTokens: Int
    /// Prompt tokens served from the prefix cache.
    public var cachedTokens: Int
    /// Decode rate (completion tokens / decode seconds).
    public var tokPerSec: Double
    /// Request receipt in the engine → first content token, in ms (engine side, excludes XPC).
    public var ttftMs: Double
    // Diagnostics for the bench / NFR reports (not part of the R-229 contract).
    /// Engine-side prefill and decode wall times (seconds).
    public var promptTime: Double
    public var generateTime: Double
    /// Model load time when this request triggered the load (seconds), else nil.
    public var loadTime: Double?
    /// MLX peak bytes since the request started and `MTLDevice.currentAllocatedSize` at the end.
    public var gpuPeakBytes: UInt64
    public var mtlAllocatedBytes: UInt64
    // M1.T13 tool-call trace (AT-231; optional so older payloads still decode, nil = not reported).
    /// Tool calls whose span was generated under the grammar constraint (MLX: GrammarBuilder's lazy
    /// constraint; llama-server: its native lazy tool grammar).
    public var toolCallsConstrained: Int?
    /// Tool calls the native parser recognised but rejected (undeclared name, unparseable arguments).
    public var toolCallsRejected: Int?
    /// Raw tool-call syntax spans RawToolSyntaxScrubber removed from `textDelta` (`tool.parseLeak`).
    public var rawToolSyntaxScrubbed: Int?
    /// M6.T21: the last rejected call's tool name and reason (`incomplete_output` = cut off at the output limit), so the
    /// harness can tell the model its call was not run instead of ending the step in silence. nil = none / not reported.
    public var rejectedToolName: String?
    public var rejectedToolReason: String?
    /// M9.T05 (C1 prefill A/B): MLX freed-buffer cache and active bytes when the request started and when it ended, and
    /// the cache limit in force (bytes; -1 = MLX default). Diagnostics only; nil = not reported (llama-server, older).
    public var mlxCacheBytesStart: Int?
    public var mlxActiveBytesStart: Int?
    public var mlxCacheBytesEnd: Int?
    public var mlxActiveBytesEnd: Int?
    public var mlxCacheLimitBytes: Int?
    /// AT-273 round 65: the engine ended the generation because it repeated itself (MLX RepetitionGuard: an exact loop or
    /// a runaway near-loop), so a `done(length)` is a runaway, not a long answer. nil = no.
    public var stoppedRepeating: Bool?

    public init(
        promptTokens: Int, completionTokens: Int, cachedTokens: Int = 0, tokPerSec: Double? = nil, ttftMs: Double = 0,
        promptTime: Double = 0, generateTime: Double = 0, loadTime: Double? = nil, gpuPeakBytes: UInt64 = 0,
        mtlAllocatedBytes: UInt64 = 0, toolCallsConstrained: Int? = nil, toolCallsRejected: Int? = nil,
        rawToolSyntaxScrubbed: Int? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedTokens = cachedTokens
        self.tokPerSec = tokPerSec ?? (generateTime > 0 ? Double(completionTokens) / generateTime : 0)
        self.ttftMs = ttftMs
        self.promptTime = promptTime
        self.generateTime = generateTime
        self.loadTime = loadTime
        self.gpuPeakBytes = gpuPeakBytes
        self.mtlAllocatedBytes = mtlAllocatedBytes
        self.toolCallsConstrained = toolCallsConstrained
        self.toolCallsRejected = toolCallsRejected
        self.rawToolSyntaxScrubbed = rawToolSyntaxScrubbed
    }

    /// Prefill rate of the uncached prompt part (tokens / s), 0 when unknown.
    public var prefillTokPerSec: Double {
        promptTime > 0 ? Double(promptTokens - cachedTokens) / promptTime : 0
    }
}

public enum EngineEvent: Codable, Sendable, Hashable {
    case reasoningDelta(String)
    case textDelta(String)
    /// A fragment of a tool call's JSON arguments; `name` arrives with the first fragment of a call.
    case toolCallDelta(id: String, name: String?, argsFragment: String)
    case toolCallDone(id: String, name: String, argsJSON: String)
    case usage(Usage)
    case done(FinishReason)
    case error(AntiChatError)

    public var isTerminal: Bool {
        switch self {
        case .done, .error: true
        default: false
        }
    }

    public var isDelta: Bool {
        switch self {
        case .textDelta, .reasoningDelta: true
        default: false
        }
    }
}
