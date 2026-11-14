// M2.T20 step 4 (R-203 AC2–AC4; blueprint E §E.2.4 step 1): the fast first chat. While the tier chat model downloads, Normal
// chats run on the `chat_fast` starter; once the tier model is verified (its install view exists) the switch happens at the
// next turn boundary — `slot()` re-evaluates only while no reply streams, so a reply in flight finishes on the model it
// started with, and the next request carries the whole transcript to the tier model (it prefills from scratch). If the tier
// model cannot load (memory, NFR-R5) the chat stays on the starter and says `model.usingLighter`.
// Evil chats never come here (contract 7: ChatEnvironment gives them the Evil slot or nothing, never `chat_fast`).
// Harness never imports Platform: the catalog / store side arrives through `ModelReadinessProviding` (AntiChatUI conforms).
import AntiChatEngineProtocol
import Foundation
import Synchronization

/// What the hand-off needs to know about the installed chat models.
public protocol ModelReadinessProviding: Sendable {
    /// The `chat_fast` starter's slot when its install view exists.
    func starterSlot() -> ModelSlot?
    /// The tier chat model's slot once verified and materialised (nil while it downloads).
    func tierSlot() -> ModelSlot?
    /// 0…100 of the tier model's download (the `starter.quick` %).
    func tierPercent() -> Int?
}

public final class StarterHandoff: Sendable {
    public enum Phase: Sendable, Equatable {
        /// Neither model installed (dev / pre-M2 layouts): the fallback slot.
        case fallback
        /// On the starter; the tier model is downloading (`starter.quick` with its %).
        case starter(percent: Int?)
        /// On the tier model.
        case tier
        /// The tier model did not fit: on the starter (`model.usingLighter`).
        case lighter
    }

    private struct State {
        var phase: Phase = .fallback
        var current: ModelSlot?
        var refused: Set<String> = []
        var upgradeNoticePending = false
    }

    private let readiness: any ModelReadinessProviding
    private let isIdle: @Sendable () -> Bool
    private let fits: @Sendable (ModelSlot) -> Bool
    private let fallback: @Sendable () -> ModelSlot
    private let state = Mutex(State())
    private let enabled: Bool

    /// - Parameters:
    ///   - isIdle: no Normal chat reply is streaming (the turn boundary; PackActivityTracker in the app).
    ///   - fits: the tier model may load under the memory budget (MemoryFitGuard / HardwareProfile.fits in the app).
    ///   - enabled: `FeatureFlag.starterHandoff` (off → always the tier model or the fallback; the first chat waits).
    public init(readiness: any ModelReadinessProviding, enabled: Bool = true, isIdle: @escaping @Sendable () -> Bool,
                fits: @escaping @Sendable (ModelSlot) -> Bool = { _ in true }, fallback: @escaping @Sendable () -> ModelSlot) {
        self.readiness = readiness
        self.enabled = enabled
        self.isIdle = isIdle
        self.fits = fits
        self.fallback = fallback
    }

    /// The slot for the next request. Changes only at a turn boundary.
    public func slot() -> ModelSlot {
        let idle = isIdle()
        return state.withLock { s in
            if idle || s.current == nil { reevaluate(&s) }
            return s.current ?? fallback()
        }
    }

    public var phase: Phase {
        _ = slot()
        return state.withLock { s in
            if case .starter = s.phase { return .starter(percent: readiness.tierPercent()) }
            return s.phase
        }
    }

    /// `starter.upgraded`, once: true the first time it is read after the switch to the tier model.
    public func consumeUpgradeNotice() -> Bool {
        state.withLock { s in
            defer { s.upgradeNoticePending = false }
            return s.upgradeNoticePending
        }
    }

    /// A turn on the tier model failed with not-enough-memory: stay on the starter (`model.usingLighter`).
    public func tierLoadRefused(key: String) {
        state.withLock { s in
            s.refused.insert(key)
            if s.current?.key == key { s.current = nil }
            reevaluate(&s)
        }
    }

    private func reevaluate(_ s: inout State) {
        let wasStarter = s.phase.isStarter
        if let tier = readiness.tierSlot() {
            if !enabled || (!s.refused.contains(tier.key) && fits(tier)) {
                if s.current?.key != tier.key, wasStarter { s.upgradeNoticePending = true }
                s.current = tier
                s.phase = .tier
                return
            }
            if let starter = readiness.starterSlot() {
                s.current = starter
                s.phase = .lighter
                return
            }
        }
        if enabled, let starter = readiness.starterSlot() {
            s.current = starter
            s.phase = .starter(percent: nil)
            return
        }
        s.current = nil
        s.phase = .fallback
    }
}

extension StarterHandoff.Phase {
    var isStarter: Bool { if case .starter = self { true } else { false } }
}

/// M2.T20: the line above the composer (`StarterLabel`): `starter.quick` with the tier model's %, `starter.upgraded` once
/// after the switch, `model.usingLighter` when the tier model did not fit. The UI maps the case to its copy key.
public enum StarterLabelModel: Sendable, Equatable {
    case none
    case quick(percent: Int)
    case upgraded
    case lighter

    public static func label(phase: StarterHandoff.Phase, upgradeNotice: Bool) -> StarterLabelModel {
        if upgradeNotice { return .upgraded }
        switch phase {
        case .starter(let p): return .quick(percent: p ?? 0)
        case .lighter: return .lighter
        case .tier, .fallback: return .none
        }
    }

    public var copyKey: String? {
        switch self {
        case .none: nil
        case .quick: "starter.quick"
        case .upgraded: "starter.upgraded"
        case .lighter: "model.usingLighter"
        }
    }
}
