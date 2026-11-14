// AT-235 part 2 (R-235 AC3) — M2.T23: a confident image/video turn whose reply has no tool call is re-asked exactly once
// with `tool_choice` = the media tool; if that still brings none, the reply gets the MediaOfferChip (`router.offerImage`
// / `router.offerVideo`); never a second re-ask; flag off → no re-ask, chip only; a non-media or unconfident turn is
// left alone. The engine here is a ScriptedEngine that ignores tool_choice (worst case) or honours it.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

/// Answers in text, whatever `tool_choice` says (a model the forcing did not reach).
final class TextOnlyEngine: EngineService {
    let requests = Mutex<[ChatRequest]>([])
    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? { nil }
    func capabilities() async -> EngineCapabilities? { nil }
    func cancel(_ requestID: UUID) {}
    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        requests.withLock { $0.append(request) }
        return AsyncThrowingStream { c in
            c.yield(.textDelta("Here is a description of a cat."))
            c.yield(.done(.stop))
            c.finish()
        }
    }
}

@Suite struct FallbackIntentCheckTests {
    /// Thresholds every trigram score clears: the top intent is always confident.
    static func confidentRouter() async throws -> PreRouter {
        let base = try await RouterStubs.router()
        let t = Dictionary(uniqueKeysWithValues: Route.intents.map { ($0, RouteThreshold(low: -1, high: -1)) })
        return PreRouter(scorer: base.scorer, thresholds: t, enabled: { true })
    }

    func controller(_ engine: any EngineService, router: PreRouter) throws -> (TurnController, UpdateLog, ToolRegistry) {
        let db = try AppDatabase.inMemory()
        let reg = ToolRegistry(RouterStubs.all)
        let rt = ToolRuntime(registry: reg, permissions: ToolPermissionStore(db), policy: .forTier(.t3), selection: .standard,
                             router: router, tier: { .t3 })
        let c = TurnController(chatID: StorageID.make(), database: db, engine: engine, tools: rt) { .scripted("inline") }
        return (c, UpdateLog(c), reg)
    }

    /// A bundled image_create prototype, verbatim: its own row scores 1.0, so image_create is the top intent.
    static var imagePrompt: String { RoutePrototypes.bundled!.file.routes["image_create"]!["en"]![0] }

    func send(_ c: TurnController, _ log: UpdateLog, _ text: String) async throws -> String {
        let a = StorageID.make()
        await c.start(.send(userID: StorageID.make(), text: text, parentID: nil), assistantID: a)
        _ = try await log.waitFinished(a)
        return a
    }

    @Test func reasksOnceThenOffersChip() async throws {
        let engine = TextOnlyEngine()
        let (c, log, _) = try controller(engine, router: try await Self.confidentRouter())
        let a = try await send(c, log, Self.imagePrompt)
        let d = try #require(await c.lastRouteDecision)
        let top = try #require(d.top)
        #expect(top == .imageCreate && d.confident)
        let reqs = engine.requests.withLock { $0 }
        #expect(reqs.count == 2)  // the answer + exactly one re-ask
        #expect(reqs[0].toolChoice == .auto)
        #expect(reqs[1].toolChoice == .function(top.tools[0]))
        #expect(await c.lastFallbackReasks == 1)
        let chip = try #require(await c.lastMediaOffer)
        #expect(log.all.contains { $0.assistantID == a && $0.kind == .mediaOffer(chip) })
        #expect(chip.copyKey == "router.offerImage")  // "Create this as an image?" (copy deck; copy-sync)
    }

    @Test func honouredReaskNeedsNoChip() async throws {
        let script = try EngineScript(text: #"{"t":"textDelta","v":"A fox, described.","delayMs":0}"#)
        // The scripted engine honours a forced tool_choice (constrained decoding): the re-ask brings the call.
        let (c, log, reg) = try controller(InProcessScriptedEngine(script: script), router: try await Self.confidentRouter())
        _ = try await send(c, log, Self.imagePrompt)
        let top = try #require(await c.lastRouteDecision?.top)
        #expect(top == .imageCreate)
        #expect(await c.lastFallbackReasks == 1)
        #expect(reg.invocations(of: top.tools[0]) == 1)
        #expect(await c.lastMediaOffer == nil)
    }

    @Test func pureDecisionTable() {
        let tools = RouterStubs.all.map(\.schema)
        func d(_ r: Route?, confident: Bool, forced: String? = nil) -> RouteDecision {
            RouteDecision(scores: [:], top: r, confident: confident, forcedTool: forced, toolsToExpose: tools)
        }
        #expect(FallbackIntentCheck.action(decision: d(.imageCreate, confident: true), calledTools: [], reasked: false, enabled: true)
                == .reask(tool: "create_image"))
        #expect(FallbackIntentCheck.action(decision: d(.videoFromImage, confident: true), calledTools: [], reasked: true, enabled: true)
                == .offer(MediaOfferChip(kind: .video)))
        #expect(FallbackIntentCheck.action(decision: d(.imageEdit, confident: true), calledTools: [], reasked: false, enabled: false)
                == .offer(MediaOfferChip(kind: .image)))  // flag off: no re-ask
        #expect(FallbackIntentCheck.action(decision: d(.imageCreate, confident: true), calledTools: ["create_image"], reasked: false, enabled: true) == nil)
        #expect(FallbackIntentCheck.action(decision: d(.imageCreate, confident: false), calledTools: [], reasked: false, enabled: true) == nil)
        #expect(FallbackIntentCheck.action(decision: d(.webNeeded, confident: true), calledTools: [], reasked: false, enabled: true) == nil)
        #expect(FallbackIntentCheck.action(decision: d(.imageCreate, confident: true, forced: "create_image"), calledTools: [],
                                           reasked: false, enabled: true) == nil)  // a chip already forced it
        #expect(FallbackIntentCheck.action(decision: d(.imageCreate, confident: true), calledTools: ["create_video"], reasked: false,
                                           enabled: true) == nil)  // the reply has media already (the other tool)
        #expect(MediaOfferChip(kind: .video).chipID == "video" && ChipOverride.toolName(forChip: "video") == "create_video")
        // Soak dry run 2: a confident route the words do not back is never forced; the text answer keeps the chip.
        var unconfirmed = d(.imageCreate, confident: true)
        unconfirmed.mediaConfirmed = false
        #expect(FallbackIntentCheck.action(decision: unconfirmed, calledTools: [], reasked: false, enabled: true)
                == .offer(MediaOfferChip(kind: .image)))
    }

    /// Soak dry run 2: a verbatim image_create prototype that names no picture word scores image_create confidently, but
    /// the words do not back it: the model's text answer stands (one request, no forced re-ask), with the offer chip.
    @Test func unconfirmedMediaRouteIsNotReasked() async throws {
        let engine = TextOnlyEngine()
        let router = try await Self.confidentRouter()
        let prompt = try #require(await Self.unconfirmedImagePrompt(router))
        let (c, log, _) = try controller(engine, router: router)
        _ = try await send(c, log, prompt)
        let d = try #require(await c.lastRouteDecision)
        #expect(d.top == .imageCreate && d.confident && !d.mediaConfirmed)
        #expect(engine.requests.withLock { $0.count } == 1)
        #expect(engine.requests.withLock { $0[0].tools.contains { $0.name == "create_image" } })  // still offered
        #expect(await c.lastFallbackReasks == 0)
        #expect(await c.lastMediaOffer == MediaOfferChip(kind: .image))
    }

    /// A bundled English image_create prototype with no medium / style word that the confident router puts on
    /// image_create (e.g. "Show me what a futuristic city on Mars might look like").
    static func unconfirmedImagePrompt(_ router: PreRouter) async -> String? {
        let rows = RoutePrototypes.bundled?.file.routes["image_create"]?["en"] ?? []
        for p in rows where !MediumCue.confirmsMedia(p, hasImage: false, top: .imageCreate) {
            let d = await router.decide(userText: p, hasImage: false, chips: [], tools: RouterStubs.all.map(\.schema), tier: .t3)
            if d.top == .imageCreate, d.confident { return p }
        }
        return nil
    }
}
