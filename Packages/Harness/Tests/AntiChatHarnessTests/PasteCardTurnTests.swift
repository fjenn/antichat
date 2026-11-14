// W2 wiring (A-M1-W2-wire): composer paste cards on the send path. A card saved by `PastedTextAttachmentStore`
// before the turn is linked to the user message in the turn's write and its text reaches the model's prompt.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

/// Records the requests, replies through the scripted engine.
private final class CapturingEngine: EngineService {
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

@Suite struct PasteCardTurnTests {
    @Test func pasteCardIsLinkedAndInThePrompt() async throws {
        let db = try AppDatabase.inMemory()
        let engine = try CapturingEngine(script: words(2, delayMs: 1))
        let env = ChatEnvironment(database: db, engine: engine, slot: { .scripted("inline") })
        let chatID = StorageID.make()
        let pasted = String(repeating: "x", count: 10_001)
        let card = try env.pastes.save(text: pasted, displayName: "Pasted text", messageID: nil)
        let controller = env.controller(chatID: chatID)
        let log = UpdateLog(controller)
        let u = StorageID.make()
        let a = StorageID.make()
        await controller.start(.send(userID: u, text: "Summarise this", parentID: nil, attachmentIDs: [card.id]),
                               assistantID: a)
        #expect(try await log.waitFinished(a).status == .done)
        #expect(try AttachmentRepository(db).attachments(messageID: u).map(\.id) == [card.id])
        let prompt = try #require(engine.requests.withLock { $0.last })
        guard case .message(let last)? = prompt.messages.last else { Issue.record("no message in the prompt"); return }
        #expect(last.role == .user)
        #expect(last.content == "Summarise this\n\n" + pasted)
    }
}
