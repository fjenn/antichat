// M9.T05 (NFR-U1 warm launch ≤ 0.5 s): launch work the first window does not need runs after the window is usable,
// not in `AntiChatApp.init` ahead of it. Work registered with `run(_:_:)` before the flush waits; after it, it runs at
// once. The flush comes from the first composer focus in a visible window (the `launchToUsable` mark, on the next
// run-loop turn so that frame commits first), or from the fallback the app delegate arms for launches that never
// focus a composer (onboarding, a blocked launch: 1 s; background test/probe runs: the next run-loop turn).
// Only order-independent services belong here: nothing the first window reads (catalog, model slots, database,
// the notifications delegate) may wait.
import Foundation

/// Work held until `flush()`, then run in registration order; later work runs at once.
@MainActor
public final class DeferredWorkQueue {
    private var pending: [(label: String, work: @MainActor () -> Void)] = []
    /// True once flushed (later `run` calls execute immediately).
    public private(set) var flushed = false
    /// Labels in the order they ran.
    public private(set) var ran: [String] = []

    public init() {}

    public func run(_ label: String, _ work: @escaping @MainActor () -> Void) {
        if flushed {
            ran.append(label)
            work()
        } else {
            pending.append((label, work))
        }
    }

    /// Labels still waiting.
    public var pendingLabels: [String] { pending.map(\.label) }

    /// Runs every waiting item once, in registration order. Idempotent.
    public func flush() {
        guard !flushed else { return }
        flushed = true
        let items = pending
        pending = []
        for item in items {
            ran.append(item.label)
            item.work()
        }
    }
}

/// The process's launch queue.
@MainActor
public enum AfterFirstFrame {
    public static let queue = DeferredWorkQueue()

    /// Runs `work` after the first usable frame (at once when that already happened).
    public static func run(_ label: String, _ work: @escaping @MainActor () -> Void) { queue.run(label, work) }

    /// The first usable frame was reached (composer focused in a visible window): flush on the next run-loop turn.
    public static func usableFrameReached() {
        guard !queue.flushed else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { queue.flush() } }
    }

    /// Flushes after `seconds` whatever happens (a launch that never focuses a composer); 0 = next run-loop turn.
    public static func armFallback(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds)) { MainActor.assumeIsolated { queue.flush() } }
    }
}
