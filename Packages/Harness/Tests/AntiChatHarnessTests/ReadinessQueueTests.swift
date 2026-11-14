// M1.T19 AT-299 harness half: a send while the model loads or downloads is held with a rising NN%, released (all
// held sends, in order) the moment the model accepts requests, and a cancelled one is never released. Includes a
// simulated download progress source (M2's download manager re-runs this leg with AT-203) and the ScriptedEngine
// `slow-load` warmup feeding the queue its real lifecycle events.
//   make test-unit FILTER=ReadinessQueueTests
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

@Suite("ReadinessQueueTests") struct ReadinessQueueTests {
    @Test func transitionsAndPercent() {
        typealias Q = ReadinessQueue<Int>
        var r = ChatReadiness.unknown
        #expect(r.acceptsRequests)
        r = Q.next(r, .lifecycle(.loadState(.loading)))
        #expect(r == .loading(progress: nil) && !r.acceptsRequests && r.percent == nil)
        r = Q.next(r, .lifecycle(.loadProgress(0.425)))
        #expect(r.percent == 42)
        r = Q.next(r, .lifecycle(.prefillProgress(0.5)))
        #expect(r.percent == 42)
        r = Q.next(r, .lifecycle(.loadState(.ready)))
        #expect(r == .ready && r.acceptsRequests)
        #expect(Q.next(.ready, .lifecycle(.loadProgress(0.9))) == .ready)  // late progress
        #expect(Q.next(.ready, .lifecycle(.loadState(.evicted))) == .unknown)
        #expect(Q.next(.loading(progress: 0.3), .warmupFinished(failed: true)) == .failed)
        #expect(Q.next(.unknown, .warmupFinished(failed: false)) == .ready)
        #expect(Q.next(.unknown, .downloadProgress(0.1)) == .downloading(progress: 0.1))
        #expect(Q.next(.downloading(progress: 0.99), .lifecycle(.loadProgress(0.5))) == .downloading(progress: 0.99))
        #expect(Q.next(.downloading(progress: 0.99), .downloadFinished) == .loading(progress: nil))
    }

    @Test func holdReleaseCancel() {
        var q = ReadinessQueue<String>()
        let r1 = q.hold("a")
        #expect(!r1)  // ready (unknown): goes out now
        q.apply(.lifecycle(.loadState(.loading)))
        let r2 = q.hold("a")
        #expect(r2)
        let r3 = q.hold("b")
        #expect(r3)
        let r4 = q.hold("c")
        #expect(r4)
        let r5 = q.cancel("b")
        #expect(r5)
        let r6 = q.cancel("b")
        #expect(!r6)
        let r7 = q.apply(.lifecycle(.loadProgress(0.5)))
        #expect(r7.isEmpty)
        #expect(q.readiness.percent == 50)
        let r8 = q.apply(.lifecycle(.loadState(.ready)))
        #expect(r8 == ["a", "c"])  // in order; the cancelled one never
        #expect(q.held.isEmpty)
        let r9 = q.hold("d")
        #expect(!r9)
    }

    @Test func cancelledBeforeReadySendsNothing() {
        var q = ReadinessQueue<String>()
        q.apply(.lifecycle(.loadState(.loading)))
        let r10 = q.hold("only")
        #expect(r10)
        q.cancel("only")
        let r11 = q.apply(.lifecycle(.loadState(.ready)))
        #expect(r11.isEmpty)
    }

    /// Simulated download (M2): 0 → 100 % then the load; the percent rises monotonically and the held send is
    /// released only after the load is ready.
    @Test func simulatedDownloadSource() async {
        let (progress, feed) = AsyncStream<Double>.makeStream()
        var q = ReadinessQueue<String>()
        var percents: [Int] = []
        var released: [String] = []
        Task {
            for p in stride(from: 0.0, through: 0.95, by: 0.05) { feed.yield(p) }
            feed.finish()
        }
        var held = false
        for await e in ReadinessQueue<String>.downloadEvents(progress) {
            released += q.apply(e)
            if !held { held = q.hold("msg") }
            if let p = q.readiness.percent { percents.append(p) }
        }
        #expect(held)
        #expect(percents.count >= 10 && zip(percents, percents.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(released.isEmpty)  // download finished → loading, still held
        #expect(q.readiness == .loading(progress: nil))
        released += q.apply(.lifecycle(.loadState(.loading)))
        released += q.apply(.lifecycle(.loadProgress(0.6)))
        #expect(released.isEmpty)
        released += q.apply(.lifecycle(.loadState(.ready)))
        #expect(released == ["msg"])
    }

    /// The real warmup path: the ScriptedEngine's `load` step reports loading, rising progress and ready; a send
    /// held during it is released within 200 ms of ready (here: in the same event).
    @Test func scriptedWarmupDrivesTheQueue() async throws {
        let script = try EngineScript(text: """
            {"t":"load","ms":400,"steps":8}
            {"t":"textDelta","v":"Ready now."}
            """)
        let engine = InProcessScriptedEngine(script: script)
        let events = Mutex<[ReadinessEvent]>([])
        let error = await engine.warmup(.scripted("x")) { e in events.withLock { $0.append(.lifecycle(e)) } }
        #expect(error == nil)
        var q = ReadinessQueue<String>()
        var percents: [Int] = []
        var releasedAt: Int?
        var held = false
        for (i, e) in events.withLock({ $0 }).enumerated() {
            if !q.apply(e).isEmpty { releasedAt = i }
            if !held { held = q.hold("held") }  // sent while loading
            if let p = q.readiness.percent { percents.append(p) }
        }
        #expect(held)
        #expect(percents.first ?? 100 < percents.last ?? 0)
        #expect(percents.last == 100)
        #expect(releasedAt == events.withLock { $0.count } - 1)  // released by the `.ready` event itself
        #expect(engine.requestCount == 0)  // holding sends nothing
    }
}
