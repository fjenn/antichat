// AT-238 (R-238) — M2.T24, Harness half: a picture / video turn whose pack is missing shows the InstallCard INSTEAD
// of sending the request (0 engine requests, so no text claim can exist; AC1), stores the request to re-run
// (PendingRequestStore; AC2's input), an ineligible Mac gets the reason variant with nothing to re-run (AC3), an
// installed pack sends as usual, and a pack-missing media tool call from the model becomes the card with no further
// (text) step (step 4).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

/// A pack store with fixed answers; `install` counts calls.
final class FakePacks: PackInstalling {
    let state: Mutex<[MediaPack: PackAvailability]>
    let installs = Mutex(0)
    init(_ s: [MediaPack: PackAvailability]) { state = Mutex(s) }
    func availability(_ pack: MediaPack) async -> PackAvailability { state.withLock { $0[pack] ?? .installed } }
    func install(_ pack: MediaPack) async -> PackInstallStart {
        installs.withLock { $0 += 1 }
        state.withLock { $0[pack] = .installing(percent: 0) }
        return .started
    }
    func set(_ pack: MediaPack, _ a: PackAvailability) { state.withLock { $0[pack] = a } }
}

/// Answers "Answer n" for its n-th request (records the order). The FIRST request's stream stays open, with no
/// event, until the test calls `open()` (no clock involved); later requests answer at once.
final class GatedTextEngine: EngineService {
    let texts = Mutex<[String]>([])
    private let gate: AsyncStream<Void>
    private let release: AsyncStream<Void>.Continuation
    init() {
        let s = AsyncStream<Void>.makeStream()
        gate = s.stream
        release = s.continuation
    }
    /// Lets the first request finish (buffered: also works before that request reads the gate).
    func open() {
        release.yield()
        release.finish()
    }
    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? { nil }
    func capabilities() async -> EngineCapabilities? { nil }
    func cancel(_ requestID: UUID) {}
    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        let n = texts.withLock { t -> Int in
            t.append("Answer \(t.count + 1)")
            return t.count
        }
        let gate = n == 1 ? gate : nil
        return AsyncThrowingStream { c in
            let task = Task {
                if let gate { for await _ in gate { break } }
                c.yield(.textDelta("Answer \(n)"))
                c.yield(.done(.stop))
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite struct InstallCardPolicyTests {
    static let notInstalled: [MediaPack: PackAvailability] = [
        .photo: .installable(bytes: 6_400_000_000, minutes: 17), .video: .installable(bytes: 18_000_000_000, minutes: 48),
    ]

    func controller(_ engine: any EngineService, packs: FakePacks, router: PreRouter? = nil) async throws
        -> (TurnController, UpdateLog, AppDatabase, ToolRegistry)
    {
        let db = try AppDatabase.inMemory()
        let reg = ToolRegistry(RouterStubs.all)
        let r: PreRouter
        if let router { r = router } else { r = try await FallbackIntentCheckTests.confidentRouter() }
        let rt = ToolRuntime(registry: reg, permissions: ToolPermissionStore(db), policy: .forTier(.t1), selection: .standard,
                             router: r, tier: { .t1 })
        let c = TurnController(chatID: StorageID.make(), database: db, engine: engine, tools: rt, packs: packs) { .scripted("inline") }
        return (c, UpdateLog(c), db, reg)
    }

    func send(_ c: TurnController, _ log: UpdateLog, _ text: String, user: String = StorageID.make()) async throws -> (String, TurnResult) {
        let a = StorageID.make()
        await c.start(.send(userID: user, text: text, parentID: nil), assistantID: a)
        return (a, try await log.waitFinished(a))
    }

    @Test func cardInsteadOfTheRequest() async throws {
        let engine = TextOnlyEngine()
        let (c, log, db, _) = try await controller(engine, packs: FakePacks(Self.notInstalled))
        let user = StorageID.make()
        let (a, res) = try await send(c, log, FallbackIntentCheckTests.imagePrompt, user: user)
        #expect(engine.requests.withLock { $0.count } == 0)  // nothing reached the chat model: no text claim possible
        #expect(res.status == .done && res.text.isEmpty)
        let card = try #require(await c.lastInstallCard)
        #expect(card.pack == .photo && card.state == .offered(bytes: 6_400_000_000, minutes: 17) && card.hasButtons)
        #expect(card.copyKey == "install.card" && card.userMessageID == user)
        #expect(log.all.contains { $0.assistantID == a && $0.kind == .installCard(card) })
        let pending = PendingRequestStore(db).pending(chatID: c.chatID)
        #expect(pending.map(\.assistantID) == [a] && pending.first?.userMessageID == user && pending.first?.pack == .photo)
    }

    @Test(arguments: [("image", MediaPack.photo), ("video", .video)])
    func chipForcesTheCardEvenForChat(chip: String, pack: MediaPack) async throws {
        let engine = TextOnlyEngine()
        let (c, log, _, _) = try await controller(engine, packs: FakePacks(Self.notInstalled))
        await c.setChips([chip])
        _ = try await send(c, log, "hello there, how are you today?")
        #expect(engine.requests.withLock { $0.count } == 0)
        #expect(await c.lastInstallCard?.pack == pack)
    }

    @Test func ineligibleMacGetsTheReasonAndNoButton() async throws {
        let engine = TextOnlyEngine()
        let packs = FakePacks([.video: .unavailable(reason: "needs 24 GB memory")])
        let (c, log, db, _) = try await controller(engine, packs: packs)
        await c.setChips(["video"])
        let user = StorageID.make()
        let (a, _) = try await send(c, log, "make a short video of waves on a beach", user: user)
        let card = try #require(await c.lastInstallCard)
        #expect(card.state == .unavailable(reason: "needs 24 GB memory") && !card.hasButtons && card.copyKey == "install.unavailable")
        #expect(card.userMessageID == nil)
        // The card is the reply's only content: it is remembered so a reopened chat shows it again (not an empty row).
        let pending = PendingRequestStore(db).pending(chatID: c.chatID)
        #expect(pending.map(\.assistantID) == [a] && pending.first?.userMessageID == user && pending.first?.pack == .video)
        #expect(engine.requests.withLock { $0.count } == 0)
    }

    /// Lead decision B's button-less "coming soon" card is remembered the same way.
    @Test func comingSoonCardIsRemembered() async throws {
        let engine = TextOnlyEngine()
        let (c, log, db, _) = try await controller(engine, packs: FakePacks([.photo: .comingSoon]))
        await c.setChips(["image"])
        let (a, res) = try await send(c, log, "a fox in the snow")
        #expect(await c.lastInstallCard?.state == .comingSoon)
        #expect(res.status == .done)  // the card is the reply, not an `engine.emptyReply`
        #expect(PendingRequestStore(db).pending(chatID: c.chatID).map(\.assistantID) == [a])
    }

    /// [Not now] while another turn of the chat is still generating: the in-place answer is queued (never refused,
    /// which left the bubble stuck in "queued") and starts once that turn has ended. Deterministic: `b`'s stream is held
    /// open by the engine's gate, not by a delay, and the refusals are counted by the controller.
    @Test func notNowWhileBusyIsQueuedNotDropped() async throws {
        let engine = GatedTextEngine()
        let (c, log, db, _) = try await controller(engine, packs: FakePacks(Self.notInstalled))
        await c.setChips(["image"])
        let (a, card) = try await send(c, log, "a fox in the snow")
        #expect(card.text.isEmpty && engine.texts.withLock { $0.isEmpty })
        await c.setChips([])
        // A second turn is generating (its stream held open by the gate) when [Not now] arrives.
        let b = StorageID.make()
        await c.start(.send(userID: StorageID.make(), text: "what is the capital of Portugal?", parentID: a), assistantID: b)
        #expect(engine.texts.withLock { $0.count } == 1)
        let answered = Task { await c.answerWithoutMedia(a, retryEvery: .milliseconds(5)) }
        // Wait (a condition, not a time window) until the controller has refused `a` at least twice: queued and retried.
        var polls = 0
        while await c.queuedAnswerRetries < 2, polls < 10_000 {
            polls += 1
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await c.queuedAnswerRetries >= 2)
        // While the gate is closed `b` cannot end, so `a` cannot have started: no request, no second finish, still the card.
        #expect(log.finished(b) == nil)
        #expect(engine.texts.withLock { $0.count } == 1)
        #expect(log.all.filter { u in
            if case .finished = u.kind { return u.assistantID == a }
            return false
        }.count == 1)
        #expect(try MessageRepository(db).parts(of: a).isEmpty)
        engine.open()
        _ = try await log.waitFinished(b)
        #expect(await answered.value)
        try await log.wait { l in
            l.all.filter { u in
                if case .finished = u.kind { return u.assistantID == a }
                return false
            }.count == 2
        }
        #expect(engine.texts.withLock { $0.count } == 2)  // b's request, then a's
        #expect(try MessageRepository(db).message(a)?.status == .done)
        #expect(try MessageRepository(db).parts(of: a).filter { $0.kind == .text }.map(\.body).joined() == "Answer 2")
    }

    /// [Not now] (ConversationModel.dismissInstallCard → answerWithoutMedia): the card's reply is answered IN PLACE by
    /// the model, in text, with no media tool offered or forced — even with the Create image chip still on — and no
    /// re-ask or second card.
    @Test func notNowAnswersTheSameReplyInTextWithoutMedia() async throws {
        let engine = TextOnlyEngine()
        let (c, log, db, _) = try await controller(engine, packs: FakePacks(Self.notInstalled))
        await c.setChips(["image"])
        let (a, first) = try await send(c, log, FallbackIntentCheckTests.imagePrompt)
        #expect(first.status == .done && first.text.isEmpty && engine.requests.withLock { $0.count } == 0)
        await c.answerWithoutMedia(a)
        func finishes(_ id: String) -> [TurnResult] {
            log.all.compactMap { u in
                guard u.assistantID == id, case .finished(let r) = u.kind else { return nil }
                return r
            }
        }
        try await log.wait { _ in finishes(a).count == 2 }
        let answer = try #require(finishes(a).last)
        #expect(answer.status == .done && answer.text == "Here is a description of a cat.")
        let reqs = engine.requests.withLock { $0 }
        #expect(reqs.count == 1)  // one text answer: no forced re-ask
        let media: Set<String> = ["create_image", "edit_image", "create_video"]
        #expect(!reqs[0].tools.contains { media.contains($0.name) })
        if case .function(let name)? = reqs[0].toolChoice { #expect(!media.contains(name)) }
        let card = await c.lastInstallCard
        let reasks = await c.lastFallbackReasks
        let offer = await c.lastMediaOffer
        #expect(card == nil && reasks == 0 && offer == nil)
        #expect(try MessageRepository(db).message(a)?.status == .done)
        #expect(try MessageRepository(db).parts(of: a).filter { $0.kind == .text }.map(\.body).joined() == "Here is a description of a cat.")
        #expect(try MessageTree(db).versionInfo(a).total == 1)  // the same reply, not a new version
        // The withholding was for that turn only: the next send (chip still on) shows the card again.
        let b = StorageID.make()
        await c.start(.send(userID: StorageID.make(), text: FallbackIntentCheckTests.imagePrompt, parentID: a), assistantID: b)
        let next = try await log.waitFinished(b)
        let again = await c.lastInstallCard
        #expect(next.text.isEmpty && again?.pack == .photo)
        #expect(engine.requests.withLock { $0.count } == 1)
    }

    @Test func installedPackSendsAsUsual() async throws {
        let engine = TextOnlyEngine()
        let (c, log, _, _) = try await controller(engine, packs: FakePacks([.photo: .installed, .video: .installed]))
        _ = try await send(c, log, FallbackIntentCheckTests.imagePrompt)
        #expect(await c.lastInstallCard == nil)
        #expect(engine.requests.withLock { $0.count } >= 1)
    }

    @Test func nonMediaTurnNeverCarded() async throws {
        let engine = TextOnlyEngine()
        let off = try await RouterStubs.router(enabled: false)
        let (c, log, _, _) = try await controller(engine, packs: FakePacks(Self.notInstalled), router: off)
        _ = try await send(c, log, "what is the capital of Portugal?")
        #expect(await c.lastInstallCard == nil)
        #expect(engine.requests.withLock { $0.count } == 1)
    }

    /// Step 4: the router did not see media (off), the model calls create_image anyway → `pack_not_installed` → the
    /// card, and no text-only step follows (exactly one engine request).
    @Test func packMissingToolCallBecomesTheCard() async throws {
        let script = """
            {"t":"textDelta","v":"Sure! Here is your fox.","delayMs":1}
            {"t":"toolCallDone","id":"call_1","name":"create_image","args":"{\\"prompt\\":\\"a fox\\"}","delayMs":1}
            {"t":"turn"}
            {"t":"textDelta","v":"Here is your picture of a fox!","delayMs":1}
            """
        let engine = CountingEngine(InProcessScriptedEngine(script: try EngineScript(text: script)))
        let off = try await RouterStubs.router(enabled: false)
        let (c, log, _, reg) = try await controller(engine, packs: FakePacks(Self.notInstalled), router: off)
        let (_, res) = try await send(c, log, "draw a fox")
        #expect(engine.count.withLock { $0 } == 1)
        #expect(res.text.isEmpty)  // the preamble is dropped and the "Here is your picture" step never ran
        #expect(reg.invocations(of: "create_image") == 0)
        #expect(await c.lastInstallCard?.pack == .photo)
    }

    /// M2 review #13: a top intent that only passed the `low` threshold (not confident) never replaces the reply with
    /// a card — "describe what a photo of a sunset usually looks like" gets its text answer (R-241).
    @Test func onlyAConfidentMediaIntentShowsTheCard() {
        #expect(InstallCardPolicy.pack(for: RouteDecision(top: .imageCreate, confident: false)) == nil)
        #expect(InstallCardPolicy.pack(for: RouteDecision(top: .videoCreate, confident: false)) == nil)
        #expect(InstallCardPolicy.pack(for: RouteDecision(top: .imageCreate, confident: true)) == .photo)
        #expect(InstallCardPolicy.pack(for: RouteDecision(top: nil, forcedTool: "create_video")) == .video)
        // Soak dry run 2: confident but not backed by the words → no card (the model answers; its call still cards).
        #expect(InstallCardPolicy.pack(for: RouteDecision(top: .imageCreate, confident: true, mediaConfirmed: false)) == nil)
        #expect(InstallCardPolicy.pack(for: RouteDecision(top: nil, mediaConfirmed: false, forcedTool: "create_image")) == .photo)
    }

    /// Soak dry run 2 (build/soak/20261112T034152Z, 16 of 16 failed legs): "Suggest a name for a small bakery that sells
    /// sourdough." (chat-9b-q4, Normal) and "Name three classic cocktails made with gin, one line each." (evil-9b, Evil)
    /// scored image_create confidently, the Photo pack was not installed, and the card replaced the answer: no engine
    /// request, no parts, no usage, `done` (pending_request held 16 `photo` rows). With the router confident on every
    /// intent, these prompts now reach the model and get its answer.
    @Test(arguments: ["Suggest a name for a small bakery that sells sourdough.",
                      "Name three classic cocktails made with gin, one line each."])
    func soakPromptsGetAnAnswerNotACard(_ prompt: String) async throws {
        let engine = TextOnlyEngine()
        let (c, log, db, _) = try await controller(engine, packs: FakePacks(Self.notInstalled))
        let (a, res) = try await send(c, log, prompt)
        #expect(await c.lastInstallCard == nil)
        #expect(engine.requests.withLock { $0.count } == 1)  // answered, never re-asked with a forced media tool
        #expect(res.status == .done && res.text == "Here is a description of a cat.")
        #expect(PendingRequestStore(db).pending(chatID: c.chatID).isEmpty)
        #expect(try MessageRepository(db).parts(of: a).contains { $0.kind == .text && !$0.body.isEmpty })
    }

    /// The same shape through the router: a confident image_create the words do not back (a no-cue prototype) sends
    /// the request; the model's own create_image call still shows the card (step 4).
    @Test func unconfirmedRouteSendsAndTheModelsCallStillCards() async throws {
        let router = try await FallbackIntentCheckTests.confidentRouter()
        let prompt = try #require(await FallbackIntentCheckTests.unconfirmedImagePrompt(router))
        let script = """
            {"t":"toolCallDone","id":"call_1","name":"create_image","args":"{\\"prompt\\":\\"mars city\\"}","delayMs":1}
            {"t":"turn"}
            {"t":"textDelta","v":"Here is your picture!","delayMs":1}
            """
        let engine = CountingEngine(InProcessScriptedEngine(script: try EngineScript(text: script)))
        let (c, log, _, _) = try await controller(engine, packs: FakePacks(Self.notInstalled), router: router)
        let (_, res) = try await send(c, log, prompt)
        #expect(engine.count.withLock { $0 } == 1)
        #expect(await c.lastInstallCard?.pack == .photo)
        #expect(res.status == .done && res.text.isEmpty)  // the card is the reply: not an `engine.emptyReply`
    }

    /// Lead decision B: a pack this build does not ship gets the "coming soon" card, without buttons.
    @Test func comingSoonCardHasNoButtons() {
        let c = InstallCardPolicy.card(.photo, availability: .comingSoon, userMessageID: "u1")
        #expect(c?.state == .comingSoon && c?.copyKey == "install.comingSoon" && c?.hasButtons == false)
    }
}

/// Counts chat requests of a wrapped engine.
final class CountingEngine: EngineService {
    let inner: any EngineService
    let count = Mutex(0)
    /// Every request as JSON (what the model was sent).
    let sent = Mutex<[String]>([])
    init(_ inner: any EngineService) { self.inner = inner }
    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? {
        await inner.warmup(slot, onLifecycle: onLifecycle)
    }
    func capabilities() async -> EngineCapabilities? { await inner.capabilities() }
    func cancel(_ requestID: UUID) { inner.cancel(requestID) }
    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        count.withLock { $0 += 1 }
        let json = (try? JSONEncoder().encode(request)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        sent.withLock { $0.append(json) }
        return inner.chat(request, onLifecycle: onLifecycle)
    }
}
