// M1.T05 step 3 gate: `make test-unit FILTER=DeltaBatcherTests` (≤ 60 msgs/s at 200 tok/s input).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import os
import Testing
@testable import AntiChatEngines

final class BatchSink: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [([StreamItem], Int, ContinuousClock.Instant)]())
    func add(_ items: [StreamItem], _ tokens: Int) { lock.withLock { $0.append((items, tokens, .now)) } }
    var batches: [[StreamItem]] { lock.withLock { $0.map(\.0) } }
    var tokens: [Int] { lock.withLock { $0.map(\.1) } }
    var count: Int { lock.withLock { $0.count } }
    var times: [ContinuousClock.Instant] { lock.withLock { $0.map(\.2) } }
}

/// Virtual time for `DeltaBatcher.Schedule`: timers fire only from `advance(to:)`, in deadline order, each awaited, so the
/// flush pattern is a pure function of the input schedule (no wall clock, no host load).
final class VirtualSchedule: @unchecked Sendable {
    private struct Item { let id: Int; let at: Duration; let fire: @Sendable () async -> Void }
    private let lock = NSLock()
    private var items: [Item] = []
    private var nextID = 0
    private(set) var now: Duration = .zero

    var schedule: DeltaBatcher.Schedule {
        { [self] after, fire in
            let id = lock.withLock { () -> Int in
                let id = nextID; nextID += 1
                items.append(Item(id: id, at: now + after, fire: fire))
                return id
            }
            return { [self] in lock.withLock { items.removeAll { $0.id == id } } }
        }
    }

    func advance(to t: Duration) async {
        while let due = takeDue(t) { await due.fire() }
        lock.withLock { now = t }
    }

    private func takeDue(_ t: Duration) -> Item? {
        lock.withLock {
            let due = items.filter { $0.at <= t }.min { $0.at < $1.at }
            if let due { items.removeAll { $0.id == due.id }; now = due.at }
            return due
        }
    }
}

@Suite struct DeltaBatcherTests {
    @Test func flushesAtMaxTokens() async {
        let sink = BatchSink()
        let b = DeltaBatcher(policy: BatchPolicy(windowMS: 10_000, maxTokens: 8)) { sink.add($0, $1) }
        for _ in 0..<8 { await b.delta(.textDelta("a")) }
        #expect(sink.batches == [[.engine(.textDelta("aaaaaaaa"))]])
        #expect(sink.tokens == [8])
    }

    @Test func flushesAfterTheWindowFromTheFirstDelta() async throws {
        let sink = BatchSink()
        let clock = VirtualSchedule()
        let b = DeltaBatcher(policy: BatchPolicy(windowMS: 16, maxTokens: 8), schedule: clock.schedule) { sink.add($0, $1) }
        await b.delta(.textDelta("x"))
        await clock.advance(to: .milliseconds(15))
        #expect(sink.count == 0)
        await clock.advance(to: .milliseconds(16))
        #expect(sink.batches == [[.engine(.textDelta("x"))]])
    }

    @Test func otherItemsFlushPendingDeltasFirstAndKeepOrder() async {
        let sink = BatchSink()
        let b = DeltaBatcher(policy: BatchPolicy(windowMS: 10_000, maxTokens: 100)) { sink.add($0, $1) }
        await b.delta(.reasoningDelta("r1"))
        await b.delta(.reasoningDelta("r2"))
        await b.delta(.textDelta("t1"))
        await b.delta(.reasoningDelta("r3"))  // interleaving is kept, never re-sorted
        await b.item(.lifecycle(.prefillProgress(1)))
        await b.item(.engine(.done(.stop)))
        #expect(sink.batches == [
            [.engine(.reasoningDelta("r1r2")), .engine(.textDelta("t1")), .engine(.reasoningDelta("r3")), .lifecycle(.prefillProgress(1))],
            [.engine(.done(.stop))],
        ])
        #expect(sink.tokens == [4, 0])
    }

    @Test func setPolicySwitchesToTheFallbackWindow() async {
        let sink = BatchSink()
        let b = DeltaBatcher(policy: .standard) { sink.add($0, $1) }
        await b.setPolicy(.fallback)
        for _ in 0..<15 { await b.delta(.textDelta("a")) }
        #expect(sink.count == 0)
        await b.delta(.textDelta("a"))
        #expect(sink.tokens == [16])
    }

    /// Feeds one delta every 5 ms (200 tok/s) for `seconds` of virtual time and returns flushes per second over the run.
    /// Virtual (VirtualSchedule): on the wall clock a loaded host lowered the input rate and the bar measured the host.
    static func rate(_ policy: BatchPolicy, seconds: Double) async throws -> (msgsPerSec: Double, tokPerSec: Double, sink: BatchSink) {
        let sink = BatchSink()
        let clock = VirtualSchedule()
        let b = DeltaBatcher(policy: policy, schedule: clock.schedule) { sink.add($0, $1) }
        let n = Int(seconds * 200)
        for i in 0..<n {
            await clock.advance(to: .milliseconds(5 * i))
            await b.delta(.textDelta("w"))
        }
        let end = Duration.milliseconds(5 * n)
        await clock.advance(to: end)
        await b.flush()
        let secs = Double(end.components.seconds) + Double(end.components.attoseconds) / 1e18
        return (Double(sink.count) / secs, Double(n) / secs, sink)
    }

    @Test func atMostSixtyMessagesPerSecondAt200TokPerSec() async throws {
        let r = try await Self.rate(.standard, seconds: 3)
        print("DeltaBatcher 16ms/8tok: input \(String(format: "%.1f", r.tokPerSec)) tok/s → \(String(format: "%.1f", r.msgsPerSec)) msgs/s")
        #expect(r.tokPerSec > 150, "input rate fell to \(r.tokPerSec) tok/s; the measurement is not at 200 tok/s")
        #expect(r.msgsPerSec <= 60)
        #expect(r.sink.tokens.reduce(0, +) == 600)
        // Nothing is lost or reordered.
        let text = r.sink.batches.flatMap { $0 }.compactMap { i -> String? in
            if case .engine(.textDelta(let s)) = i { return s } else { return nil }
        }.joined()
        #expect(text == String(repeating: "w", count: 600))
    }

    @Test func fallbackPolicyHalvesTheRate() async throws {
        let r = try await Self.rate(.fallback, seconds: 2)
        print("DeltaBatcher 33ms/16tok: input \(String(format: "%.1f", r.tokPerSec)) tok/s → \(String(format: "%.1f", r.msgsPerSec)) msgs/s")
        #expect(r.msgsPerSec <= 30)
    }
}
