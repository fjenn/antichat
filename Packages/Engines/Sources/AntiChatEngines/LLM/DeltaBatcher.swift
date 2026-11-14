// DeltaBatcher (M1.T05 step 3; architecture §4.3, K-NEW-C005-2), promoted from the M0.T04 TokenBatcher.
// Coalesces textDelta/reasoningDelta and flushes when `maxTokens` deltas are pending or `windowMS` after the
// FIRST pending delta, whichever comes first; any other item flushes the pending deltas first and goes in the
// same message, so order is preserved. Default 16 ms / 8 tokens; 33 ms / 16 tokens via SetPolicy.
//
// Why not swift-async-algorithms `chunks(ofCount:or: .repeating(every:))` (P-shell-02 named `chunked(by:)`):
// its timer is free-running, so at 200 tok/s (one delta per 5 ms) it flushes on every 16 ms tick = 62.5
// msgs/s, above the ≤ 60 msgs/s bar; anchoring the window at the first pending delta gives one flush per
// ~20 ms = 50 msgs/s (DeltaBatcherTests). A-M1-T05a.
import AntiChatEngineProtocol
import Foundation

public actor DeltaBatcher {
    /// Called once per flush with the items and the number of delta tokens they cover.
    public typealias Sink = @Sendable (_ items: [StreamItem], _ tokens: Int) -> Void
    /// Runs `fire` once `after` has elapsed unless the returned cancel is called first. The app uses `realTime`;
    /// tests pass a virtual schedule so the flush-rate bar does not depend on how loaded the host is.
    public typealias Schedule = @Sendable (_ after: Duration, _ fire: @escaping @Sendable () async -> Void) -> @Sendable () -> Void

    public static let realTime: Schedule = { after, fire in
        let t = Task {
            try? await Task.sleep(for: after)
            guard !Task.isCancelled else { return }
            await fire()
        }
        return { t.cancel() }
    }

    private var policy: BatchPolicy
    private let sink: Sink
    private var pending: [StreamItem] = []
    private var pendingTokens = 0
    private let schedule: Schedule
    private var timer: (@Sendable () -> Void)?
    public private(set) var messagesSent = 0

    public init(policy: BatchPolicy = .standard, schedule: @escaping Schedule = DeltaBatcher.realTime, sink: @escaping Sink) {
        self.policy = policy
        self.schedule = schedule
        self.sink = sink
    }

    public func setPolicy(_ p: BatchPolicy) { policy = p }

    /// A text or reasoning delta (one generated token). Other events go through `item`.
    public func delta(_ e: EngineEvent) {
        switch e {
        case .textDelta(let s):
            if case .engine(.textDelta(let prev))? = pending.last {
                pending[pending.count - 1] = .engine(.textDelta(prev + s))
            } else {
                pending.append(.engine(e))
            }
        case .reasoningDelta(let s):
            if case .engine(.reasoningDelta(let prev))? = pending.last {
                pending[pending.count - 1] = .engine(.reasoningDelta(prev + s))
            } else {
                pending.append(.engine(e))
            }
        default:
            item(.engine(e))
            return
        }
        pendingTokens += 1
        if pendingTokens >= policy.maxTokens {
            flush()
        } else if timer == nil {
            timer = schedule(.milliseconds(policy.windowMS)) { [weak self] in await self?.timerFired() }
        }
    }

    /// Any non-delta item: flushed immediately together with the pending deltas (after them).
    public func item(_ i: StreamItem) {
        if case .engine(let e) = i, e.isDelta {
            delta(e)
            return
        }
        pending.append(i)
        flush()
    }

    private func timerFired() {
        timer = nil
        flush()
    }

    public func flush() {
        timer?()
        timer = nil
        guard !pending.isEmpty else { return }
        let items = pending
        let tokens = pendingTokens
        pending = []
        pendingTokens = 0
        messagesSent += 1
        sink(items, tokens)
    }
}
