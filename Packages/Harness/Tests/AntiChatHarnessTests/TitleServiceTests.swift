// M1.T19 AT-010 leg (1) harness half: the temporary title, the sanitiser (2–6 words), the title request, a silent
// failure on timeout/error, the ScriptedEngine `title` line, and the database rules (pending → auto; a user rename
// is never overwritten; no row before the first send).
//   make test-unit FILTER=TitleServiceTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

/// Answers every request with `reply` after `delay` (or fails / never finishes).
final class TitleTestEngine: EngineService {
    enum Mode { case reply(String), error, hang }
    let mode: Mode
    let delay: Duration
    let requests = Mutex<[ChatRequest]>([])
    let cancelled = Mutex<[UUID]>([])

    init(_ mode: Mode, delay: Duration = .zero) {
        self.mode = mode
        self.delay = delay
    }

    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? { nil }
    func capabilities() async -> EngineCapabilities? { nil }
    func cancel(_ requestID: UUID) { cancelled.withLock { $0.append(requestID) } }

    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        requests.withLock { $0.append(request) }
        let mode = mode, delay = delay
        return AsyncThrowingStream { c in
            let t = Task {
                try? await Task.sleep(for: delay)
                switch mode {
                case .reply(let s):
                    c.yield(.textDelta(s))
                    c.yield(.done(.stop))
                case .error:
                    c.yield(.error(AntiChatError(.engineRestarted, detail: "test")))
                case .hang:
                    try? await Task.sleep(for: .seconds(60))
                }
                c.finish()
            }
            c.onTermination = { _ in t.cancel() }
        }
    }
}

@Suite("TitleServiceTests") struct TitleServiceTests {
    static let slot = ModelSlot.scripted("t.jsonl", key: "chat-0.8b")

    @Test func temporaryTitleIsTheFirst60Characters() {
        let long = String(repeating: "word ", count: 30)
        let t = TitleService.temporaryTitle(long)
        #expect(t.count <= 60)
        #expect(long.hasPrefix(t))
        #expect(TitleService.temporaryTitle("  How do\n\nI   bake bread?  ") == "How do I bake bread?")
        #expect(TitleService.temporaryTitle("") == "")
    }

    @Test func sanitizeKeepsTwoToSixWords() {
        #expect(TitleService.sanitize("Title: \"Baking Sourdough Bread at Home.\"") == "Baking Sourdough Bread at Home")
        #expect(TitleService.sanitize("**Weekend trip planning**\nHere is why…") == "Weekend trip planning")
        #expect(TitleService.sanitize("One two three four five six seven eight") == "One two three four five six")
        #expect(TitleService.sanitize("Greetings") == nil)  // one word: keep the temporary title
        #expect(TitleService.sanitize("  \n ") == nil)
        #expect(TitleService.sanitize("{\"title\": \"x y\"}") == nil)  // leaked JSON
        #expect(TitleService.sanitize("Hello! How can I help you today?") == "Hello! How can I help you")
        for raw in ["Rust ownership explained", "Plan für das Wochenende", "Quick SQL index question here today"] {
            let words = TitleService.sanitize(raw)?.split(separator: " ").count ?? 0
            #expect((TitleService.minTitleWords...TitleService.maxTitleWords).contains(words))
        }
    }

    @Test func requestShape() throws {
        let s = TitleService(engine: TitleTestEngine(.reply("x")), slot: Self.slot)
        let r = try #require(s.request(userMessage: String(repeating: "a", count: 2_000), assistantResponse: "Sure"))
        #expect(EngineScript.isTitleRequest(r))
        #expect(r.reasoning == .off)
        #expect(r.sampling.maxTokens == TitleService.maxTokens)
        #expect(r.modelSlot.key == "chat-0.8b")
        guard case .layer(let system)? = r.messages.first, case .message(let user)? = r.messages.last else {
            Issue.record("shape")
            return
        }
        #expect(system.content == TitleService.systemPrompt)
        #expect(system.content.contains("2 to 6 words"))
        #expect(user.content.count < 700)  // 600-character clip + labels
        #expect(user.content.contains("Assistant response:\nSure"))
        #expect(s.request(userMessage: "   ", assistantResponse: "") == nil)  // never titles an empty session
    }

    @Test func generatesAndSanitises() async {
        let s = TitleService(engine: TitleTestEngine(.reply("\"Sourdough at home.\"")), slot: Self.slot)
        #expect(await s.generateTitle(userMessage: "How do I bake sourdough?") == "Sourdough at home")
    }

    @Test func failsSilently() async {
        #expect(await TitleService(engine: TitleTestEngine(.error), slot: Self.slot).generateTitle(userMessage: "hi there") == nil)
        #expect(await TitleService(engine: TitleTestEngine(.reply("Ok")), slot: Self.slot).generateTitle(userMessage: "hi there") == nil)
    }

    @Test func timesOutAfter8sAndCancels() async {
        let engine = TitleTestEngine(.hang)
        let clock = ContinuousClock()
        let t0 = clock.now
        let title = await TitleService(engine: engine, slot: Self.slot).generateTitle(userMessage: "hello world")
        let elapsed = clock.now - t0
        #expect(title == nil)
        // The engine hangs, so returning at all is the timeout; sleeps only give lower bounds (an upper bound measured
        // the host's load), so the check is "not before 8 s".
        #expect(TitleService.timeout == .seconds(8))
        #expect(elapsed >= .seconds(8), "\(elapsed)")
        #expect(engine.cancelled.withLock { $0.count } == 1)
    }

    @Test func scriptedEngineAnswersWithTheTitleLineWithoutAPlay() async throws {
        let script = try EngineScript(text: """
            {"t":"title","v":"Harbour town morning","delayMs":10}
            {"t":"textDelta","v":"Answer v{{v}}"}
            """)
        let engine = InProcessScriptedEngine(script: script)
        let s = TitleService(engine: engine, slot: Self.slot)
        #expect(await s.generateTitle(userMessage: "Tell me about the town") == "Harbour town morning")
        // The chat's own turn still plays its first segment as play 1 ({{v}} unaffected by the title request).
        let req = ChatRequest(sessionID: UUID(), modelSlot: Self.slot, messages: [.message(ChatMessage(role: .user, content: "x"))])
        var text = ""
        for try await e in engine.chat(req) { if case .textDelta(let d) = e { text += d } }
        #expect(text == "Answer v1")
        // No title line: an empty answer (the temporary title stays).
        let bare = InProcessScriptedEngine(script: try EngineScript(text: "{\"t\":\"textDelta\",\"v\":\"Hello there friend\"}"))
        #expect(await TitleService(engine: bare, slot: Self.slot).generateTitle(userMessage: "hi there") == nil)
    }

    @Test func databaseRules() throws {
        let service = try ChatListService.inMemory()
        let chat = try service.create(firstPrompt: "How do I bake sourdough bread at home without a starter kit please?")
        #expect(chat.titlePending)
        #expect(chat.title == TitleService.temporaryTitle("How do I bake sourdough bread at home without a starter kit please?"))
        #expect(try service.applyAutoTitle(chat.id, title: "Sourdough without a starter"))
        #expect(try service.chat(chat.id)?.title == "Sourdough without a starter")
        #expect(try service.chat(chat.id)?.titlePending == false)
        // Only a pending title is replaced: a second auto title and anything after a rename are refused.
        #expect(try !service.applyAutoTitle(chat.id, title: "Other"))
        let renamed = try service.create(firstPrompt: "Second chat prompt")
        try service.rename(renamed.id, to: "My name")
        #expect(try !service.applyAutoTitle(renamed.id, title: "Auto name"))
        #expect(try service.chat(renamed.id)?.title == "My name")
    }

    @Test func emptySessionLeavesNoRow() throws {
        let service = try ChatListService.inMemory()
        #expect(try service.sidebarCount() == 0)  // a new chat has no row until its first send
        let chat = try service.create(firstPrompt: "cancelled before the model was ready")
        #expect(try service.deleteIfEmpty(chat.id))
        #expect(try service.sidebarCount() == 0)
        let kept = try service.create(firstPrompt: "has a message")
        try service.appendUserMessage(kept.id, text: "has a message")
        #expect(try !service.deleteIfEmpty(kept.id))
    }

    @Test func unreadFlag() throws {
        let service = try ChatListService.inMemory()
        let chat = try service.create(firstPrompt: "background reply")
        #expect(try service.chat(chat.id)?.unread == false)
        let before = try service.chat(chat.id)?.updatedAt
        #expect(try service.setUnread(chat.id, true))
        #expect(try service.chat(chat.id)?.unread == true)
        #expect(try service.chat(chat.id)?.updatedAt == before)  // not an edit: sidebar order kept
        #expect(try !service.setUnread(chat.id, true))
        #expect(try service.setUnread(chat.id, false))
    }
}
