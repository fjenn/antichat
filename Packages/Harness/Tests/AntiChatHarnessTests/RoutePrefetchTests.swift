// M2.T23b (R-235 AC2: pre-router ≤ 30 ms on S1) — the send-time cost of the router. The embed (the GPU/XPC part) runs
// while the user types (RoutePrefetch → RouteScorer.prefetch); at send a cached vector is scored on the CPU with NO
// embed call. A send that beats the embed waits at most PreRouter.sendBudget and goes out unscored (skipped
// `.timedOut`, the default tool set); the late vector still lands in the cache for the next decision. The embedder
// here blocks each message embed until the test opens its gate (slower than any send budget however loaded the host
// is), so every assertion is about counts and order, not elapsed time.
import AntiChatEngineProtocol
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

/// Opens once; every waiter (and every later `wait`) then proceeds.
actor EmbedGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
}

/// Trigram vectors; single-message embeds take `delay`, or block until `gate` opens (prototype batches are instant).
final class SlowEmbedding: RouteEmbedding {
    let base = TrigramEmbedding()
    let delay: Duration
    let gate: EmbedGate?
    let messageEmbeds = Mutex(0)
    let finishedEmbeds = Mutex(0)
    init(delay: Duration) { self.delay = delay; gate = nil }
    init(gate: EmbedGate) { delay = .zero; self.gate = gate }
    var modelID: String? { base.modelID }
    func embed(_ batch: [String]) async throws -> [[Float]] {
        if batch.count == 1 {
            messageEmbeds.withLock { $0 += 1 }
            if let gate { await gate.wait() } else { try? await Task.sleep(for: delay) }
            finishedEmbeds.withLock { $0 += 1 }
        }
        return try await base.embed(batch)
    }
}

@Suite struct RoutePrefetchTests {
    static let text = "draw me a fox in a snowy forest, watercolor"

    func router(_ e: SlowEmbedding) async throws -> PreRouter {
        let p = try #require(RoutePrototypes.bundled)
        let scorer = RouteScorer(prototypes: p, embedding: e, cacheDirectory: FileManager.default.temporaryDirectory
            .appending(path: "prefetch-\(UUID().uuidString)"))
        #expect(await scorer.prepare())
        return PreRouter(scorer: scorer, enabled: { true })
    }

    func waitPrefetched(_ s: RouteScorer, _ text: String) async {
        for _ in 0..<1000 where !(await s.isPrefetched(text)) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func prefetchedSendDoesNoEmbed() async throws {
        let e = SlowEmbedding(delay: .milliseconds(200))
        let r = try await router(e)
        let prefetch = RoutePrefetch(scorer: r.scorer!, debounce: .milliseconds(1))
        prefetch.textChanged("draw me")  // superseded by the next keystroke: never embedded
        prefetch.textChanged(Self.text)
        await waitPrefetched(r.scorer!, Self.text)
        let before = e.messageEmbeds.withLock { $0 }
        let d = await r.decide(userText: Self.text + "  ", hasImage: false, chips: [], tools: RouterStubs.all.map(\.schema), tier: .t1)
        // The send made no embed request (CPU scoring only), so there was no embed to wait for.
        #expect(e.messageEmbeds.withLock { $0 } == before)
        #expect(d.skipped == nil && Set(d.scores.keys) == Set(Route.allCases))
    }

    @Test func coldSendWaitsAtMostTheBudgetThenGoesOutUnscored() async throws {
        let gate = EmbedGate()
        let e = SlowEmbedding(gate: gate)
        let r = try await router(e)
        #expect(r.sendBudget == .milliseconds(10))
        let d = await r.decide(userText: Self.text, hasImage: false, chips: [], tools: RouterStubs.all.map(\.schema), tier: .t1)
        #expect(d.skipped == .timedOut && d.scores.isEmpty && d.forcedTool == nil)
        #expect(d.toolsToExpose.count == ToolPruner.limit)  // the default tool set: the request still goes out (R-241)
        #expect(e.finishedEmbeds.withLock { $0 } == 0)  // decided while the embed was still running: not waited for
        await gate.open()
        // The late vector is not lost: it lands in the cache and the next decision scores without a new embed.
        await waitPrefetched(r.scorer!, Self.text)
        let n = e.messageEmbeds.withLock { $0 }
        let again = await r.decide(userText: Self.text, hasImage: false, chips: [], tools: RouterStubs.all.map(\.schema), tier: .t1)
        #expect(again.skipped == nil && !again.scores.isEmpty && e.messageEmbeds.withLock { $0 } == n)
    }

    @Test func chipStillForcesWhenUnscored() async throws {
        let gate = EmbedGate()
        let r = try await router(SlowEmbedding(gate: gate))
        let d = await r.decide(userText: Self.text, hasImage: false, chips: ["image"], tools: RouterStubs.all.map(\.schema), tier: .t1)
        #expect(d.skipped == .timedOut && d.forcedTool == "create_image")
        await gate.open()
    }
}

/// M2 review #15: after the embed model changes (here 256-d → 128-d), a draft vector cached under the old model must
/// not be scored against the new matrix.
@Suite struct RouteScorerModelChangeTests {
    final class SwitchingEmbedding: RouteEmbedding, @unchecked Sendable {
        let small = Mutex(false)
        var modelID: String? { small.withLock { $0 } ? "trigram-128" : "trigram-256" }
        func embed(_ batch: [String]) async throws -> [[Float]] {
            let half = small.withLock { $0 }
            return batch.map { t in
                let v = TrigramEmbedding.vector(t)
                return half ? Array(v[0..<128]).map { $0 + 0.01 } : v
            }
        }
    }

    static func dir() -> URL { FileManager.default.temporaryDirectory.appending(path: "switch-\(UUID().uuidString)") }

    @Test func draftVectorOfTheOldModelIsNotReused() async throws {
        let p = try #require(RoutePrototypes.bundled)
        let text = "draw me a fox in a snowy forest, watercolor"
        let e = SwitchingEmbedding()
        let scorer = RouteScorer(prototypes: p, embedding: e, cacheDirectory: Self.dir())
        #expect(await scorer.prepare())
        await scorer.prefetch(text)
        for _ in 0..<200 where !(await scorer.isPrefetched(text)) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await scorer.isPrefetched(text))
        e.small.withLock { $0 = true }  // the embed slot updated to a model of another dimension
        #expect(await scorer.prepare())
        #expect(!(await scorer.isPrefetched(text)), "the old model's draft vector is dropped")
        let after = await scorer.score(text, hasImage: false)
        // The same text through a scorer that only ever knew the new model.
        let fresh = RouteScorer(prototypes: p, embedding: e, cacheDirectory: Self.dir())
        #expect(await fresh.prepare())
        let expected = await fresh.score(text, hasImage: false)
        #expect(after != nil && after == expected)
        // A vector of the wrong size never reaches vDSP.
        #expect(await scorer.scores(for: [Float](repeating: 0.1, count: 256), hasImage: false).isEmpty)
    }
}
