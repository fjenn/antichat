// Think harder (M1.T15, R-007; P-shell-07 template flags via mlx-swift-lm f5b0677 chat conventions). The composer's
// toggle maps to one of two request shapes, per model family:
//   - reasoning families (Qwen3.5, Qwen3.6, Gemma 4): `reasoning.on` — the adapters pass it as the chat template's
//     thinking flag (`enable_thinking` in `additionalContext` for MLX, `chat_template_kwargs.enable_thinking` for
//     llama-server; M1.T13 ConformanceSuite/ThinkingCases proves every family honours it) — and `maxTokens` grows by
//     the reasoning budget so the answer is not cut by the thinking tokens;
//   - any other model (no thinking mode): the sampling-only preset — `temperature` −0.2 (floor 0) and the larger token
//     budget. No behaviour clause is added to the prompt ("think step by step" is deliberately not used), so the
//     prompt bytes and the cached prefix are the same with the toggle on or off.
// Off: the request is unchanged (`reasoning.off`, base sampling). Whether a model can reason comes from the engine's
// capabilities (`HelloAck` / the script's `caps` line) and, for real models, the family table below.
import AntiChatEngineProtocol
import Foundation

public enum ThinkHarderPolicy {
    public enum Family: String, Sendable, Equatable {
        case qwen35 = "qwen3.5", qwen36 = "qwen3.6", gemma4 = "gemma-4", other
        public var hasThinkingMode: Bool { self != .other }
    }

    /// What the toggle does for a turn.
    public enum Mode: String, Sendable, Equatable {
        /// Toggle off: request unchanged.
        case off
        /// The model's thinking mode (template flag).
        case reasoning
        /// No thinking mode: the sampling preset (tooltip `think.tip.preset`).
        case preset
    }

    /// Extra generation budget for the thinking tokens / the careful preset.
    public static let reasoningBudget = 4096
    /// Temperature step of the preset (floor 0).
    public static let presetTemperatureDrop: Float = 0.2

    /// Catalog keys → family (catalog/dev.yaml; M2's signed catalog carries the family per entry).
    public static let familyByKey: [String: Family] = [
        "chat-0.8b": .qwen35, "chat-2b": .qwen35, "chat-9b-q4": .qwen35, "evil-9b": .qwen35,
        "chat-35b-q4": .qwen36, "chat-g26": .gemma4,
    ]

    public static func family(of slot: ModelSlot) -> Family {
        if let f = familyByKey[slot.key] { return f }
        let p = (slot.key + " " + slot.path).lowercased()
        if p.contains("qwen3.6") || p.contains("qwen3_6") { return .qwen36 }
        if p.contains("qwen3.5") || p.contains("qwen3_5") { return .qwen35 }
        if p.contains("gemma-4") || p.contains("gemma4") { return .gemma4 }
        return .other
    }

    /// Whether `slot` has a thinking mode. Scripted slots: the script's `caps.reasoning`. Real slots: the family
    /// table, unless the engine reported `reasoning: false`.
    public static func supportsReasoning(_ slot: ModelSlot, capabilities: EngineCapabilities?) -> Bool {
        if capabilities?.reasoning == false { return false }
        if slot.engine == .scripted { return capabilities?.reasoning ?? true }
        return family(of: slot).hasThinkingMode
    }

    public static func mode(_ on: Bool, slot: ModelSlot, capabilities: EngineCapabilities?) -> Mode {
        guard on else { return .off }
        return supportsReasoning(slot, capabilities: capabilities) ? .reasoning : .preset
    }

    /// The request's reasoning options and sampling for a turn.
    public static func apply(
        _ on: Bool, slot: ModelSlot, capabilities: EngineCapabilities?, sampling base: Sampling
    ) -> (mode: Mode, reasoning: ReasoningOptions, sampling: Sampling) {
        let m = mode(on, slot: slot, capabilities: capabilities)
        var s = base
        switch m {
        case .off:
            return (m, .off, base)
        case .reasoning:
            s.maxTokens = base.maxTokens + reasoningBudget
            return (m, ReasoningOptions(on: true), s)
        case .preset:
            s.maxTokens = base.maxTokens + reasoningBudget
            s.temperature = max(0, base.temperature - presetTemperatureDrop)
            return (m, .off, s)
        }
    }

    /// The toggle's tooltip key: `think.tip.preset` when the model has no thinking mode, else `tip.think`.
    public static func tooltipKey(slot: ModelSlot, capabilities: EngineCapabilities?) -> String {
        supportsReasoning(slot, capabilities: capabilities) ? "tip.think" : "think.tip.preset"
    }
}
