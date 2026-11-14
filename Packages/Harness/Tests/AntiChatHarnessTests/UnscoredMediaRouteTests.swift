// R66 F2 (vq-05-image main, round 65: `router ready=true` then `skipped=timedOut`, create_image never offered, no picture):
// a turn the embedding cannot score within PreRouter.sendBudget (a cold embed model, a paste-and-send before the
// composer prefetch, a busy helper) went out with the default tool set, so a plain picture request was answered in
// text. The words now route such a turn (exposure only: never forced, never carded), and a prepare that loads the
// prototypes from the disk cache warms the embed model so the first send is not cold.
import AntiChatEngineProtocol
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

@Suite struct UnscoredMediaRouteTests {
    func router(_ e: SlowEmbedding) async throws -> PreRouter {
        let p = try #require(RoutePrototypes.bundled)
        let scorer = RouteScorer(prototypes: p, embedding: e, cacheDirectory: FileManager.default.temporaryDirectory
            .appending(path: "unscored-\(UUID().uuidString)"))
        #expect(await scorer.prepare())
        return PreRouter(scorer: scorer, enabled: { true })
    }

    @Test func coldPictureRequestStillOffersCreateImage() async throws {
        let gate = EmbedGate()
        let r = try await router(SlowEmbedding(gate: gate))
        let d = await r.decide(userText: "Draw me a lighthouse at dusk", hasImage: false, chips: [],
                               tools: RouterStubs.all.map(\.schema), tier: .t1)
        #expect(d.skipped == .timedOut && d.scores.isEmpty)
        #expect(d.top == .imageCreate && !d.confident)
        // TurnController's ToolSelector takes the intent leg from `routedTools`: create_image (and edit_image) lead.
        #expect(d.routedTools.first == "create_image")
        #expect(d.toolsToExpose.first?.name == "create_image")
        // Exposure only: no forced call, no re-ask, no install card from an unscored turn.
        #expect(d.forcedTool == nil && FallbackIntentCheck.expectedTool(d) == nil)
        await gate.open()
    }

    @Test func coldVideoRequestOffersCreateVideo() async throws {
        let gate = EmbedGate()
        let r = try await router(SlowEmbedding(gate: gate))
        let d = await r.decide(userText: "Make a short video of waves at sunset", hasImage: false, chips: [],
                               tools: RouterStubs.all.map(\.schema), tier: .t1)
        #expect(d.skipped == .timedOut && d.top == .videoCreate && d.routedTools.first == "create_video")
        await gate.open()
    }

    @Test func coldPlainQuestionKeepsTheDefaultSet() async throws {
        let gate = EmbedGate()
        let r = try await router(SlowEmbedding(gate: gate))
        let d = await r.decide(userText: "Explain how a lighthouse lens works", hasImage: false, chips: [],
                               tools: RouterStubs.all.map(\.schema), tier: .t1)
        #expect(d.skipped == .timedOut && d.top == nil && d.routedTools.isEmpty)
        await gate.open()
    }

    @Test func notReadyAndNoEmbedderRouteOnWordsToo() async throws {
        let p = try #require(RoutePrototypes.bundled)
        let gate = EmbedGate()
        let cold = RouteScorer(prototypes: p, embedding: SlowEmbedding(gate: gate), cacheDirectory: nil)
        let notReady = await PreRouter(scorer: cold, enabled: { true })
            .decide(userText: "a watercolor of a fox", hasImage: false, chips: [], tools: RouterStubs.all.map(\.schema), tier: .t1)
        #expect(notReady.skipped == .notReady && notReady.top == .imageCreate)
        let none = await PreRouter(scorer: nil, enabled: { true })
            .decide(userText: "Draw me a lighthouse", hasImage: false, chips: [], tools: RouterStubs.all.map(\.schema), tier: .t1)
        #expect(none.skipped == .noEmbedder && none.top == .imageCreate)
        // Router switched off: every tool is exposed as before, nothing routed.
        let off = await PreRouter(scorer: nil, enabled: { false })
            .decide(userText: "Draw me a lighthouse", hasImage: false, chips: [], tools: RouterStubs.all.map(\.schema), tier: .t1)
        #expect(off.skipped == .disabled && off.top == nil)
        await gate.open()
    }

    @Test func wordsAloneRoute() {
        #expect(MediumCue.unscoredRoute("Draw me a lighthouse at dusk", hasImage: false) == .imageCreate)
        #expect(MediumCue.unscoredRoute("pixel art of a cat", hasImage: false) == .imageCreate)
        #expect(MediumCue.unscoredRoute("Genera un clip de una playa", hasImage: false) == .videoCreate)
        #expect(MediumCue.unscoredRoute("make this photo move", hasImage: true) == .videoFromImage)
        // With an attached image a picture word may be a question about it: the scores decide.
        #expect(MediumCue.unscoredRoute("what is in this photo?", hasImage: true) == nil)
        #expect(MediumCue.unscoredRoute("what time is it in Lisbon?", hasImage: false) == nil)
        #expect(MediumCue.unscoredRoute(nil, hasImage: false) == nil)
    }

    /// Counts single-text embeds (message / warm-up), prototype batches pass through.
    final class CountingEmbedding: RouteEmbedding {
        let base = TrigramEmbedding()
        let singles = Mutex<[String]>([])
        var modelID: String? { base.modelID }
        func embed(_ batch: [String]) async throws -> [[Float]] {
            if batch.count == 1 { singles.withLock { $0.append(batch[0]) } }
            return try await base.embed(batch)
        }
    }

    @Test func cachedPrototypesWarmTheEmbedModel() async throws {
        let p = try #require(RoutePrototypes.bundled)
        let dir = FileManager.default.temporaryDirectory.appending(path: "warm-\(UUID().uuidString)")
        let first = CountingEmbedding()
        #expect(await RouteScorer(prototypes: p, embedding: first, cacheDirectory: dir).prepare())
        // The first prepare embedded every prototype (the model is loaded): no extra warm-up.
        try await Task.sleep(for: .milliseconds(50))
        #expect(first.singles.withLock { $0 }.isEmpty)
        let second = CountingEmbedding()
        #expect(await RouteScorer(prototypes: p, embedding: second, cacheDirectory: dir).prepare())
        for _ in 0..<500 where second.singles.withLock({ $0 }).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(second.singles.withLock { $0 } == [RouteScorer.warmText])
    }
}
