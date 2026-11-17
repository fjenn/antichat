// Context budget (M1.T18 steps 1, 3, 4; P-shell-08): token estimates, the usage the indicator shows and the
// compaction thresholds.
//
// Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Services/Chat/ContextBudgetManager.swift
// (`estimateTokens(forMessage:)` L276-296: content + per-message overhead through the vendored `TokenEstimator`;
// `ContextBreakdown.from(manifest:…)` L92-131: one entry per prompt section, then conversation / input) onto
// AntiChat's engine `ChatMessage` and `ComposedPrompt`. The trimmer and the watermark (`trimMessages*`,
// `CompactionWatermark`) are not ported: AntiChat never drops history silently; summary nodes replace it.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization
import OsaurusVendored

/// How full a chat's context is (the `ctx.usage` indicator, the 75 % / 85 % triggers).
public struct ContextUsage: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public var id: String
        public var label: String
        public var tokens: Int
    }

    /// Prompt sections (the stable layers and the tool block), then `conversation` and `input`.
    public var entries: [Entry]
    public var window: Int

    public init(entries: [Entry], window: Int) {
        self.entries = entries
        self.window = max(1, window)
    }

    public var tokens: Int { entries.reduce(0) { $0 + $1.tokens } }
    public var fraction: Double { Double(tokens) / Double(window) }
    /// What the indicator shows (`ctx.usage`): rounded, clamped to 0…100.
    public var percent: Int { min(100, max(0, Int((fraction * 100).rounded()))) }

    public static let empty = ContextUsage(entries: [], window: 1)
}

public enum ContextBudget {
    /// One message: content + the chat template's per-message overhead (`TokenEstimator.messageOverheadTokens`).
    public static func tokens(_ message: ChatMessage) -> Int {
        TokenEstimator.estimate(message.content) + TokenEstimator.messageOverheadTokens
    }

    public static func tokens(_ messages: [ChatMessage]) -> Int { messages.reduce(0) { $0 + tokens($1) } }

    /// Turns as the summariser counts them (Osaurus `estimateTokens(for: [ChatTurn])`: content only).
    public static func tokens(_ turns: [ContextTurn]) -> Int {
        turns.reduce(0) { $0 + TokenEstimator.estimate($1.content) }
    }

    /// The usage of one request: the system turn (per layer, the tool block included), the conversation before the
    /// newest message and the newest message with its ephemeral time line (`input`).
    public static func usage(prompt: ComposedPrompt, conversation: [ChatMessage], window: Int) -> ContextUsage {
        var entries: [ContextUsage.Entry] = []
        for section in prompt.manifest.sections {
            let t = section.estimatedTokens
            if t > 0 { entries.append(.init(id: section.id, label: section.label, tokens: t)) }
        }
        if !entries.isEmpty { entries[0].tokens += TokenEstimator.messageOverheadTokens }
        let history = conversation.dropLast()
        let historyTokens = tokens(Array(history))
        if historyTokens > 0 { entries.append(.init(id: "conversation", label: "Conversation", tokens: historyTokens)) }
        if let last = conversation.last {
            let input = tokens(last) + (last.role == .user ? TokenEstimator.estimate(prompt.timeLine) : 0)
            entries.append(.init(id: "input", label: "Input", tokens: input))
        }
        return ContextUsage(entries: entries, window: window)
    }
}

/// How many tokens one reply step may write (`Sampling.maxTokens`). The engines' default was a flat 1,024 for every
/// model, so a long answer stopped mid-sentence. The budget follows the model's context window — a quarter of it,
/// between `floor` and `ceiling`: 2,048 on the 8K starter models (T0), 4,096 from 16K up (T1–T4) — and never more
/// than what the prompt leaves of the window after `margin`. It is never below `floor` (the old flat value), so a
/// nearly full context behaves as before. Thinking tokens count against the same limit on both engines: Think harder's
/// reasoning budget is added on top (ThinkHarderPolicy) and taken out of the room first.
public enum OutputBudget {
    public static let floor = Sampling().maxTokens
    public static let ceiling = 4096
    /// Kept free for the chat template's own tokens and the estimator's error.
    public static let margin = 256

    /// The answer budget of a model with this context window, before the prompt is counted.
    public static func target(window: Int) -> Int { min(ceiling, max(floor, window / 4)) }

    /// `reasoning` = tokens the step may also spend thinking (0 = thinking off).
    public static func answerTokens(window: Int, promptTokens: Int, reasoning: Int = 0, floor: Int = OutputBudget.floor) -> Int {
        max(floor, min(target(window: window), window - promptTokens - margin - reasoning))
    }
}

/// When to compact and how much room a reply needs (M1.T18 steps 3–5).
public struct ContextPolicy: Sendable, Hashable {
    /// Idle compaction starts at this fill (R-233 AC2).
    public var idleThreshold: Double
    /// A send above this fill with no covering summary compacts synchronously first (R-009 AC2).
    public var syncThreshold: Double
    /// Engine idle time after `done` before an idle compaction runs.
    public var idleDelay: Duration
    /// Output reserved for the reply (`Sampling.maxTokens`): a single prompt above `window − reservedOutput` is
    /// refused (OversizeGuard).
    public var reservedOutput: Int
    /// Fixed override of the context window (`-FakeContextWindow`); nil = the model's.
    public var windowOverride: Int?

    public init(idleThreshold: Double = 0.75, syncThreshold: Double = 0.85, idleDelay: Duration = .seconds(2),
                reservedOutput: Int = Sampling().maxTokens, windowOverride: Int? = nil) {
        self.idleThreshold = idleThreshold
        self.syncThreshold = syncThreshold
        self.idleDelay = idleDelay
        self.reservedOutput = reservedOutput
        self.windowOverride = windowOverride
    }

    public static let standard = ContextPolicy()

    /// This launch's policy: `-FakeContextWindow <n>` (DEBUG) fixes the window.
    public static func current(options: LaunchOptions = .current) -> ContextPolicy {
        ContextPolicy(windowOverride: options.fakeContextWindow)
    }

    /// The context window of `slot`: the override, else the slot's (`contextTokens`), else the tier context of the
    /// model-matrix (§2: 8K for the T0-class starter models, 16K otherwise).
    public func window(for slot: ModelSlot) -> Int { window(for: slot, cap: Self.voiceSessionCap) }

    func window(for slot: ModelSlot, cap: Int?) -> Int {
        let base: Int
        if let w = windowOverride { base = w } else if let w = slot.contextTokens, w > 0 { base = w } else {
            base = Self.smallContextKeys.contains(slot.key) ? 8192 : 16_384
        }
        return min(base, cap ?? .max)
    }

    /// M3.T10 step 2 (model-matrix §2.3 T1 voice memory mitigation 1): while a voice conversation runs on T1 the chat
    /// context is capped at 8K (prompt assembly, compaction and the request's context length), so the chat KV cache
    /// stays bounded beside STT + TTS; restored when the session ends. Process-wide: one call at a time (`VoiceCalls`).
    public static var voiceSessionCap: Int? {
        get { voiceCap.withLock { $0 } }
        set { voiceCap.withLock { $0 = newValue } }
    }
    private static let voiceCap = Mutex<Int?>(nil)

    /// Models whose tier context is 8K (model-matrix §2, T0 row).
    public static let smallContextKeys: Set<String> = ["chat-0.8b", "chat-2b"]
}
