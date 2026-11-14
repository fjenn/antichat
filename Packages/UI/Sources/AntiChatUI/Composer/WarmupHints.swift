// M2.T15 steps 2–3 (R-206 AC5, NFR-C7, NFR-V10 hook). Hover hints that start a load before the click:
//   • hover on the ModeSwitch (or ⇧⌘E key-down) → Warmup{pack: chat, mode: <other mode>, predictive} with the other
//     mode's chat slot, so a new chat of that mode finds its model loading or loaded;
//   • hover on the mic / voice button → Warmup{pack: voice, predictive} (the helper warms the registered voice roles;
//     none until M3, NFR-V10 is measured there).
// The helper accepts the hint at once (`.utility`, cancellable, never evicting a leased model). One hint per pack ×
// mode per `minInterval` (hover jitter would otherwise resend it every frame).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import Foundation

@MainActor
public final class WarmupHints {
    let engine: any EngineService
    let normalSlot: @Sendable () -> ModelSlot
    let evilSlot: @Sendable () -> ModelSlot?
    let minInterval: TimeInterval
    private var lastSent: [String: Date] = [:]
    /// Hints sent (tests).
    public private(set) var sent: [Warmup] = []

    public init(engine: any EngineService, normalSlot: @escaping @Sendable () -> ModelSlot,
                evilSlot: @escaping @Sendable () -> ModelSlot?, minInterval: TimeInterval = 5) {
        self.engine = engine
        self.normalSlot = normalSlot
        self.evilSlot = evilSlot
        self.minInterval = minInterval
    }

    /// Hover on the ModeSwitch while `current` is shown: warm the other mode's chat model.
    public func modeSwitchHover(current: ComposerChatMode) {
        let other: ComposerChatMode = current == .evil ? .normal : .evil
        guard let slot = other == .evil ? evilSlot() : normalSlot() else { return }
        send(Warmup(modelSlot: slot, pack: "chat", mode: other.rawValue, predictive: true), key: "chat.\(other.rawValue)")
    }

    /// ⇧⌘E key-down: the Evil chat model.
    public func newEvilChatKeyDown() { modeSwitchHover(current: .normal) }

    /// Hover on the mic / voice button: the registered voice roles (M3).
    public func voiceHover() {
        send(Warmup(modelSlot: normalSlot(), pack: "voice", predictive: true), key: "voice")
    }

    private func send(_ w: Warmup, key: String, now: Date = Date()) {
        if let last = lastSent[key], now.timeIntervalSince(last) < minInterval { return }
        lastSent[key] = now
        sent.append(w)
        let engine = engine
        Task.detached(priority: .utility) { await engine.hint(w) }
    }
}
