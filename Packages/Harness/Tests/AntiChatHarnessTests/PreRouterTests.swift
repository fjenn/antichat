// AT-235 part 1 (R-235 AC2) — M2.T22: the pre-router scores all seven intents (and chat) for every non-conversational
// message, short-circuits pure conversation without an embed call, uses one embed request per message, caches the
// prototype vectors on disk, applies the attachment rule only as a score, and never blocks a request (R-241).
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct PreRouterTests {
    let messages = [
        "draw me a fox in a snowy forest, watercolor", "what's the weather in Lisbon right now?",
        "export this table as an excel file", "remember that my sister is called Ana",
        "Mach ein kurzes Video von Wellen am Strand", "explique-moi la photosynthèse", "haz una foto de un gato con sombrero",
        "maak hier een pdf van", "anime esta foto, por favor", "how do I draw a cat?",
    ]

    @Test func scoresEverySevenIntents() async throws {
        let e = TrigramEmbedding()
        let router = try await RouterStubs.router(e)
        let before = e.calls.withLock { $0 }
        for m in messages {
            let d = await router.decide(userText: m, hasImage: false, chips: [], tools: RouterStubs.all.map(\.schema), tier: .t3)
            #expect(d.skipped == nil, "\(m)")
            #expect(Set(d.scores.keys) == Set(Route.allCases), "\(m): \(d.scores)")
            #expect(Route.intents.count == 7)
            #expect(d.toolsToExpose.count == 8)  // T3: unchanged
        }
        #expect(e.calls.withLock { $0 } - before == messages.count)  // ≤ 1 embed request per send
    }

    @Test func conversationalShortCircuits() async throws {
        let e = TrigramEmbedding()
        let router = try await RouterStubs.router(e)
        let before = e.calls.withLock { $0 }
        let d = await router.decide(userText: "thanks!", hasImage: false, chips: [], tools: RouterStubs.all.map(\.schema), tier: .t1)
        #expect(d.skipped == .conversational && d.scores.isEmpty)
        #expect(e.calls.withLock { $0 } == before)
    }

    @Test func prototypeVectorsAreCached() async throws {
        let p = try #require(RoutePrototypes.bundled)
        // ≥ 20 prototypes per route per language (step 1), six languages.
        for r in Route.allCases {
            let langs = try #require(p.file.routes[r.rawValue])
            #expect(Set(langs.keys) == ["en", "de", "fr", "es", "nl", "pt"])
            #expect(langs.values.allSatisfy { $0.count >= 20 }, "\(r)")
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "router-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = TrigramEmbedding()
        #expect(await RouteScorer(prototypes: p, embedding: first, cacheDirectory: dir).prepare())
        #expect(first.texts.withLock { $0 } == p.rows.count)
        let second = TrigramEmbedding()
        let s2 = RouteScorer(prototypes: p, embedding: second, cacheDirectory: dir)
        #expect(await s2.prepare())
        // Loaded from <cache>/<sha>.bin: no prototype is embedded again; at most the one-word warm-up of the embed
        // model (R66 F2, UnscoredMediaRouteTests) runs in the background.
        #expect(second.texts.withLock { $0 } <= 1)
        #expect(await s2.score("paint a red bicycle", hasImage: false)?.count == 8)
    }

    @Test func attachmentRuleOnlyScores() async throws {
        let router = try await RouterStubs.router()
        let tools = RouterStubs.all.map(\.schema)
        let with = await router.decide(userText: "make it look like a painting", hasImage: true, chips: [], tools: tools, tier: .t3)
        let without = await router.decide(userText: "make it look like a painting", hasImage: false, chips: [], tools: tools, tier: .t3)
        let p = try #require(RoutePrototypes.bundled).file
        let delta = (with.scores[.imageEdit] ?? 0) - (without.scores[.imageEdit] ?? 0)
        #expect(abs(delta - (p.attachmentBonus + p.noAttachmentPenalty)) < 1e-4)
        #expect(with.scores[.imageCreate] == without.scores[.imageCreate])
        #expect(with.toolsToExpose.count == tools.count && without.toolsToExpose.count == tools.count)  // never blocks
    }

    @Test func topKMeanAggregation() {
        let s = RouteScorer.aggregate(sims: [0.9, 0.1, 0.8, 0.7, 0.2], routes: [.chat, .chat, .webNeeded, .webNeeded, .webNeeded], k: 2)
        #expect(abs(s[.chat]! - 0.5) < 1e-6 && abs(s[.webNeeded]! - 0.75) < 1e-6)
        // Thresholds are on the margin over chat.
        let t = [Route.webNeeded: RouteThreshold(low: 0.2, high: 0.24), .fileOutput: RouteThreshold(low: 0.1, high: 0.3)]
        #expect(PreRouter.top([.webNeeded: 0.75, .chat: 0.5], thresholds: t) == (.webNeeded, true))
        #expect(PreRouter.top([.webNeeded: 0.75, .chat: 0.8], thresholds: t).0 == nil)  // chat wins
        #expect(PreRouter.top([.webNeeded: 0.55, .chat: 0.4], thresholds: t).0 == nil)  // margin under low
        #expect(PreRouter.top([.webNeeded: 0.62, .fileOutput: 0.6, .chat: 0.4], thresholds: t) == (.fileOutput, false))  // larger excess
        let near = [Route.imageCreate: RouteThreshold(low: 0.1, high: 0.1), .videoCreate: RouteThreshold(low: 0.1, high: 0.1)]
        #expect(PreRouter.top([.imageCreate: 0.705, .videoCreate: 0.70, .chat: 0.5], thresholds: near, decisiveGap: 0.01)
                == (.imageCreate, false))  // a near-tie between two tools is never confident
        #expect(PreRouter.top([.imageCreate: 0.75, .videoCreate: 0.70, .chat: 0.5], thresholds: near, decisiveGap: 0.01)
                == (.imageCreate, true))        // M4 (AT-030 video recall): when the words name the medium (MediumCue), an image/video near-tie no longer
        // makes a media turn unsure; a non-media rival still does.
        #expect(PreRouter.top([.imageCreate: 0.705, .videoCreate: 0.70, .chat: 0.5], thresholds: near, decisiveGap: 0.01,
                              mediumNamed: true) == (.imageCreate, true))
        let mixed = near.merging([.webNeeded: RouteThreshold(low: 0.1, high: 0.1)]) { a, _ in a }
        #expect(PreRouter.top([.imageCreate: 0.705, .webNeeded: 0.70, .chat: 0.5], thresholds: mixed, decisiveGap: 0.01,
                              mediumNamed: true) == (.imageCreate, false))
    }

    /// Soak dry run 2: the decision says whether the words back a media top (MediumCue.confirmsMedia); a non-media
    /// top is always "confirmed". The media tool stays exposed either way.
    @Test func mediaTopCarriesItsConfirmation() async throws {
        let router = try await FallbackIntentCheckTests.confidentRouter()
        let tools = RouterStubs.all.map(\.schema)
        let drawn = await router.decide(userText: FallbackIntentCheckTests.imagePrompt, hasImage: false, chips: [], tools: tools, tier: .t3)
        #expect(drawn.top == .imageCreate && drawn.confident && drawn.mediaConfirmed)
        let prompt = try #require(await FallbackIntentCheckTests.unconfirmedImagePrompt(router))
        let bare = await router.decide(userText: prompt, hasImage: false, chips: [], tools: tools, tier: .t3)
        #expect(bare.top == .imageCreate && bare.confident && !bare.mediaConfirmed)
        #expect(bare.toolsToExpose.contains { $0.name == "create_image" })
        let web = await router.decide(userText: "what's the weather in Lisbon right now?", hasImage: false, chips: [], tools: tools, tier: .t3)
        #expect(web.top?.isMedia == true || web.mediaConfirmed)
    }

    @Test func disabledExposesEverythingAndNoEmbedderNeverBlocks() async throws {
        let tools = RouterStubs.all.map(\.schema)
        let off = try await RouterStubs.router(enabled: false)
        let d = await off.decide(userText: "draw a cat", hasImage: false, chips: ["image"], tools: tools, tier: .t0)
        #expect(d.skipped == .disabled && d.toolsToExpose.count == tools.count && d.forcedTool == "create_image")
        let none = PreRouter(scorer: nil, thresholds: [:], enabled: { true })
        let n = await none.decide(userText: "draw a cat", hasImage: false, chips: [], tools: tools, tier: .t1)
        #expect(n.skipped == .noEmbedder && n.toolsToExpose.count == ToolPruner.limit)
    }

    /// The TurnController records the decision and the routerDecision signpost path runs per turn.
    @Test func turnCarriesDecision() async throws {
        let h = try ToolLoopHarness(script: #"{"t":"textDelta","v":"ok","delayMs":1}"#, tier: .t3, tools: RouterStubs.all,
                                    selection: .standard, router: try await RouterStubs.router())
        let (_, a) = await h.send("what's the latest news about the Mars mission?")
        _ = try await h.log.waitFinished(a)
        let d = try #require(await h.controller.lastRouteDecision)
        #expect(d.scores.count == 8)
        #expect(await h.controller.requests[0].tools.count == 8)
    }
}
