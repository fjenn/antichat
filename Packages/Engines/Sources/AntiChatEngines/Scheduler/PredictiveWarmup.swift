// M2.T15 steps 2–3 (R-206 AC5, NFR-V10 hook; P-shell-11). Hover hints become scheduler loads:
//   • ModeSwitch hover / ⇧⌘E key-down → Warmup(pack: chat, mode: other) → the other mode's chat slot;
//   • mic / voice-button hover → Warmup(pack: voice) → every registered voice role (STT, TTS; none until M3 — tests
//     register a stub footprint).
// A hint is predictive: `.utility`, cancellable (a newer hint for the same pack cancels the older one before its
// load starts), and it never evicts a leased model (the scheduler's rule). Each accepted hint is timestamped
// (signpost `warmupHint`) so AT-206 part 4 can check "reaches the scheduler ≤ 50 ms after hover".
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation

public actor PredictiveWarmup {
    public struct Accepted: Sendable, Equatable {
        public var pack: String
        public var mode: String?
        public var keys: [String]
        /// Seconds from the hint's send time to its acceptance here (0 when the sender gave no time).
        public var latency: Double
    }

    public let scheduler: ModelScheduler
    private var registered: [String: [(ResidencyRole, ModelSlot)]] = [:]
    private var pending: [String: Task<Void, Never>] = [:]
    public private(set) var accepted: [Accepted] = []
    /// Keys whose load a hint started and finished (tests, AT log).
    public private(set) var loaded: [String] = []

    public init(scheduler: ModelScheduler) { self.scheduler = scheduler }

    /// Registers the models a pack warms on a hint (voice: M3 registers STT / TTS here).
    public func register(pack: String, role: ResidencyRole, slot: ModelSlot) {
        registered[pack, default: []].removeAll { $0.1.key == slot.key }
        registered[pack, default: []].append((role, slot))
    }

    public func registeredKeys(pack: String) -> [String] { registered[pack]?.map(\.1.key) ?? [] }

    /// Accepts one hint: chat → `slot` (the other mode's), any other pack → its registered roles.
    @discardableResult
    public func hint(pack: String, mode: String?, slot: ModelSlot?, sentAt: Date? = nil) -> Accepted {
        var targets: [(ResidencyRole, ModelSlot)] = []
        if pack == "chat" { if let slot { targets = [(.chat, slot)] } } else { targets = registered[pack] ?? [] }
        let a = Accepted(pack: pack, mode: mode, keys: targets.map(\.1.key),
                         latency: sentAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0)
        accepted.append(a)
        Signposts.mark(.warmupHint, durationNs: UInt64(a.latency * 1e9), meta: ["pack": pack])
        pending[pack]?.cancel()
        let scheduler = self.scheduler
        pending[pack] = Task(priority: .utility) { [weak self] in
            for (role, s) in targets {
                if Task.isCancelled { return }
                guard await scheduler.needsLoad(s) else { continue }
                // The cancel check runs again when the load's turn comes in the decision queue.
                let box = CancelBox()
                let loaded = await withTaskCancellationHandler {
                    await scheduler.warm(role: role, model: s, isCancelled: { box.isSet })
                } onCancel: { box.set() }
                if loaded, !Task.isCancelled { await self?.didLoad(s.key) }
            }
        }
        return a
    }

    /// Waits for the pack's pending warm-up (tests; the host does not wait).
    public func settle(pack: String) async { await pending[pack]?.value }

    public func cancel(pack: String) {
        pending[pack]?.cancel()
        pending[pack] = nil
    }

    private func didLoad(_ key: String) { loaded.append(key) }
}

/// Set from a cancellation handler, read in the scheduler's decision queue (another task).
final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
