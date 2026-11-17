// Per-turn memory capture, step 3 (owner 2026-11-17): the capture's side call never competes with an answer.
// Every TurnController reports its turns here (`turnBegan` / `turnEnded`, from its one phase transition), incognito
// chats too. A capture starts only while no turn runs and no other capture is open, and a turn that begins cancels
// every open capture: the task is cancelled, which cancels its engine request (EngineMemoryDecisionModel) and stops
// MemoryCapture before its next write. A cancelled or refused capture is dropped, not queued: the same message is
// read again by the idle review, and the next message gets its own capture.
import Foundation
import Synchronization

public final class MemoryCaptureCoordinator: Sendable {
    /// The app's: shared by every chat of the process.
    public static let shared = MemoryCaptureCoordinator()

    private struct State {
        var turns: Set<UUID> = []
        var captures: [UUID: Task<Void, Never>] = [:]
        var started = 0
        var cancelled = 0
    }
    private let state = Mutex(State())

    public init() {}

    /// A turn of controller `id` is running from now on: open captures are cancelled.
    public func turnBegan(_ id: UUID) {
        let open = state.withLock { s -> [Task<Void, Never>] in
            guard s.turns.insert(id).inserted else { return [] }
            let tasks = Array(s.captures.values)
            s.cancelled += tasks.count
            s.captures = [:]
            return tasks
        }
        open.forEach { $0.cancel() }
    }

    public func turnEnded(_ id: UUID) { state.withLock { _ = $0.turns.remove(id) } }

    /// A capture may start: no turn is running and no capture is open.
    public var isFree: Bool { state.withLock { $0.turns.isEmpty && $0.captures.isEmpty } }

    /// Registers the capture `make` creates, unless a turn or another capture runs (then nil, nothing was started).
    /// The task removes itself with `finished`.
    @discardableResult
    public func begin(_ make: (UUID) -> Task<Void, Never>?) -> Task<Void, Never>? {
        state.withLock { s in
            guard s.turns.isEmpty, s.captures.isEmpty else { return nil }
            let id = UUID()
            guard let task = make(id) else { return nil }
            s.captures[id] = task
            s.started += 1
            return task
        }
    }

    public func finished(_ id: UUID) { state.withLock { _ = $0.captures.removeValue(forKey: id) } }

    /// Tests: captures started, and captures cancelled by a turn.
    public var counts: (started: Int, cancelled: Int) { state.withLock { ($0.started, $0.cancelled) } }
}
