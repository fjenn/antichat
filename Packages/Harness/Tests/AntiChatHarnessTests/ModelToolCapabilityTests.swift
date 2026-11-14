// D-023 (a): the 0.8B starter is chat-only. While it is the active chat model the harness exposes no tools (the
// request carries none, the composed prompt has no tool block) and the UI gate for tool chips is off; the full
// tier models keep the tool set.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

private final class ToolRecordingEngine: EngineService {
    let inner: InProcessScriptedEngine
    let requests = Mutex<[ChatRequest]>([])

    init(script: String) throws { inner = InProcessScriptedEngine(script: try EngineScript(text: script)) }

    func capabilities() async -> EngineCapabilities? { await inner.capabilities() }
    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? {
        await inner.warmup(slot, onLifecycle: onLifecycle)
    }
    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        requests.withLock { $0.append(request) }
        return inner.chat(request, onLifecycle: onLifecycle)
    }
    func cancel(_ requestID: UUID) { inner.cancel(requestID) }
}

@Suite struct ModelToolCapabilityTests {
    @Test func starterIsChatOnly() {
        #expect(!ModelToolCapability.supportsTools(modelKey: "chat-0.8b"))
        #expect(!ModelToolCapability.offersToolChips(activeModelKey: "chat-0.8b"))
        for key in ["chat-2b", "chat-9b-q4", "chat-g26", "chat-35b-q4", "evil-9b"] {
            #expect(ModelToolCapability.supportsTools(modelKey: key), "\(key)")
            #expect(ModelToolCapability.offersToolChips(activeModelKey: key), "\(key)")
        }
        let tools = [ToolSchema(name: "get_time", description: "Get the time.")]
        #expect(ModelToolCapability.exposedTools(tools, for: .scripted("x", key: "chat-0.8b")).isEmpty)
        #expect(ModelToolCapability.exposedTools(tools, for: .scripted("x", key: "chat-9b-q4")) == tools)
    }

    /// The turn sent while the starter is active carries no tools; switching to the full model brings them back.
    @Test func harnessExposesNoToolsWhileStarterIsActive() async throws {
        let db = try AppDatabase.inMemory()
        let engine = try ToolRecordingEngine(script: words(3, delayMs: 0))
        let tools = try PromptFixtures.tools()
        let active = Mutex("chat-0.8b")
        let controller = TurnController(
            chatID: StorageID.make(), database: db, engine: engine,
            promptSettings: PromptSettings(PromptInputs(tools: tools)),
            slot: { .scripted("inline", key: active.withLock { $0 }) })
        let log = UpdateLog(controller)
        var parent: String?
        for key in ["chat-0.8b", "chat-9b-q4"] {
            active.withLock { $0 = key }
            let u = StorageID.make(), a = StorageID.make()
            await controller.start(.send(userID: u, text: "What time is it?", parentID: parent), assistantID: a)
            #expect(try await log.waitFinished(a).status == .done)
            parent = a
        }
        let r = engine.requests.withLock { $0 }
        try #require(r.count == 2)
        #expect(r[0].modelSlot.key == "chat-0.8b")
        #expect(r[0].tools.isEmpty, "the starter is offered no tools")
        #expect(r[0].toolChoice == nil)
        #expect(r[1].modelSlot.key == "chat-9b-q4")
        #expect(r[1].tools.count == tools.count, "the full model gets the tool set")
    }
}
