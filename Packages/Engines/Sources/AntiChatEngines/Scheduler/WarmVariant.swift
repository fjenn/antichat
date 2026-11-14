// M2.T15 step 1 (R-206 AC5, NFR-C7; blueprint E §E.2.7 "warm if fits"; P-shell-11). Which chat models stay resident
// when a chat of the other mode opens:
//   • warm on (T3+, `FeatureFlag.warmSecondVariant`, SetPolicy.warmSecondVariant): the other mode's model stays
//     loaded when resident(other) + current ≤ B. It is then the "second chat variant" (EvictionPolicy.effectiveRole),
//     the first chat model to go under budget pressure or a memory-pressure warning. MLX holds two containers.
//   • warm off (T0–T2, or the flag off): the other chat model is unloaded before the new one loads (unload → load,
//     NFR-M1), even when both engines differ (the T1 swap crosses MLX → llama-server) and both would fit.
// A chat model under a lease (a reply streaming) is never a victim either way.
import AntiChatEngineProtocol
import Foundation

public enum WarmVariant {
    /// Engine capacity with the warm second variant: MLX keeps two containers (Normal + Evil on T3+ are both MLX).
    public static func capacity(base: [EngineKind: Int], warm: Bool) -> [EngineKind: Int] {
        guard warm else { return base }
        var c = base
        c[.mlx] = max(2, base[.mlx] ?? 1)
        return c
    }

    /// E.2.7: keep `other` warm beside `current` only if both fit the budget (0 = no cap).
    public static func keepsWarm(currentBytes: UInt64, otherBytes: UInt64, budget: UInt64) -> Bool {
        budget == 0 || currentBytes &+ otherBytes <= budget
    }

    /// Chat models to unload before `incoming` (a chat model) loads. Warm on: none here — the budget plan
    /// (EvictionPolicy) evicts the second variant only when both do not fit. Warm off: every idle chat model.
    public static func swapVictims(entries: [ResidentEntry], incoming: ModelSlot, role: ResidencyRole, warm: Bool) -> [String] {
        guard !warm, role == .chat || role == .secondChat else { return [] }
        return entries.filter { ($0.role == .chat || $0.role == .secondChat) && $0.key != incoming.key && $0.refCount == 0 }
            .sorted { $0.key < $1.key }.map(\.key)
    }
}
