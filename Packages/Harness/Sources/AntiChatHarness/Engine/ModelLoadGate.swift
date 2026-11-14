// M2.T12 leftover (R-294 AC3 data-safety path; M2.T11 step 5): the app-side load gate. Before a slot reaches the
// helper (warmup or a chat turn), `prepare` runs the store's load check (`Repair.loadCheck` through
// ModelUpdateService); a slot in its post-update trial whose view is damaged reverts at once and the turn uses the
// previous model. After the helper answers, the verdict of a load (`loadState(.loading)` → `.ready`, or an error
// before `.ready`) goes to `report`, so a failed first load after an update flips back automatically.
// Harness cannot import Platform (import edges): the conformance lives in AntiChatUI and is installed at the
// composition root (`ModelLoadGate.shared`). No gate installed = pass-through.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization

public protocol ModelLoadGating: Sendable {
    /// The slot to load (possibly the previous model after a revert), or the refusal (`model.corrupt`).
    func prepare(_ slot: ModelSlot) async -> Result<ModelSlot, AntiChatError>
    /// The engine's verdict on a load of `slot` that this process asked for.
    func report(_ slot: ModelSlot, ok: Bool) async
}

public enum ModelLoadGate {
    public static let shared = Mutex<(any ModelLoadGating)?>(nil)
    static var current: (any ModelLoadGating)? { shared.withLock { $0 } }
}

/// Watches one request's lifecycle + events and reports a load verdict at most once.
final class LoadVerdict: Sendable {
    private struct S { var loading = false; var reported = false; var task: Task<Void, Never>? }
    private let state = Mutex(S())
    let gate: any ModelLoadGating
    let slot: ModelSlot

    init(gate: any ModelLoadGating, slot: ModelSlot) {
        self.gate = gate
        self.slot = slot
    }

    func observe(_ l: LifecycleEvent) {
        switch l {
        case .loadState(.loading): state.withLock { $0.loading = true }
        case .loadState(.ready): finish(ok: true)
        default: break
        }
    }

    /// An `.error` event: a failed load when it arrives after `.loading` and before `.ready`.
    func failed() { finish(ok: false) }

    private func finish(ok: Bool) {
        let go = state.withLock { s -> Bool in
            guard s.loading, !s.reported else { return false }
            s.reported = true
            return true
        }
        guard go else { return }
        let gate = gate, slot = slot
        let t = Task { await gate.report(slot, ok: ok) }
        state.withLock { $0.task = t }
    }

    /// Waits for the report (the stream ends only after the verdict landed, so a Retry sees the reverted slot).
    func settle() async { await state.withLock { $0.task }?.value }
}
