// M2.T23b (R-235 AC2: pre-router ≤ 30 ms on S1): takes the embed off the send path. The composer reports its text; after
// a short pause in typing (debounce) the draft is embedded and cached in the RouteScorer, so the send only runs the CPU
// scoring (≈ 2 ms). If the user sends before the vector is back, PreRouter waits at most `sendBudget` and otherwise
// sends the turn unscored — the first token is never held back by the router for more than the budget.
import AntiChatFoundation
import Foundation
import OsaurusVendored
import Synchronization

public final class RoutePrefetch: Sendable {
    public let scorer: RouteScorer
    public let debounce: Duration
    private let pending = Mutex<Task<Void, Never>?>(nil)

    public init(scorer: RouteScorer, debounce: Duration = .milliseconds(250)) {
        self.scorer = scorer
        self.debounce = debounce
    }

    /// The router of `router` (nil when it has no scorer or is switched off).
    public convenience init?(_ router: PreRouter?) {
        guard let router, let s = router.scorer else { return nil }
        self.init(scorer: s)
    }

    /// The composer's text changed: embed it once typing pauses (cancels the previous draft's wait).
    public func textChanged(_ text: String) {
        let scorer = scorer, debounce = debounce
        let t = Task(priority: .utility) {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, FeatureFlag.preRouter.isEnabled(), !CapabilityQueryIntent.isConversationalAbstain(text) else { return }
            await scorer.prefetch(text)
        }
        pending.withLock { $0?.cancel(); $0 = t }
    }
}
