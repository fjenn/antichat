// Per-turn memory capture in a turn (owner 2026-11-17): after the reply is delivered, a gated user message costs one
// short call on the chat model (stubbed here). certain → saved, and the reply gets its "Memory updated" line
// (`.memoryCaptured` + a stored activity part with the event id, which is what Undo needs); unsure → a pending
// suggestion; already stored → nothing; the turn's own `memory` call wrote → no call; incognito / Paused / Off / Evil
// without the switch / an ungated message → no call at all; the next message mid-capture → cancelled, nothing written.
//   make test-unit FILTER=MemoryCaptureTurnTests
import AntiChatEngineProtocol
import AntiChatKnowledge
import AntiChatStorage
import Foundation
import GRDB
import Synchronization
import Testing
@testable import AntiChatHarness

/// The chat model of the capture: the extraction answer `facts` (ADD for a comparison); counts its calls. `hold`: it
/// answers only once its task is cancelled.
final class TurnCaptureModel: MemoryDecisionModel, Sendable {
    let facts: String?
    let hold: Bool
    let calls = Mutex(0)
    init(facts: String?, hold: Bool = false) {
        self.facts = facts
        self.hold = hold
    }
    func complete(system: String, user: String) async -> String? {
        calls.withLock { $0 += 1 }
        if hold { try? await Task.sleep(for: .seconds(60)) }
        return system == MemoryUpdateDecider.systemPrompt ? #"{"event":"ADD"}"# : facts
    }
}

@Suite struct MemoryCaptureTurnTests {
    static let metric = "From now on I always want measurements in metric units. Which is longer, a mile or a kilometre?"
    static let certain = #"[{"topic":"Units","text":"Wants measurements in metric units","confidence":"certain","sensitive_category":"none"}]"#
    static let unsure = #"[{"topic":"Units","text":"May prefer metric units","confidence":"unsure","sensitive_category":"none"}]"#
    static let reply = """
        {"t":"textDelta","v":"A mile is longer. I have noted your preference for metric units.","delayMs":0}
        {"t":"turn"}
        {"t":"textDelta","v":"You are welcome.","delayMs":0}
        """

    struct Chat {
        let db: AppDatabase
        let memory: MemoryRuntime
        let model: TurnCaptureModel
        let controller: TurnController
        let log: UpdateLog
        let chatID = StorageID.make()

        init(facts: String? = MemoryCaptureTurnTests.certain, hold: Bool = false, policy: MemoryPolicy = MemoryPolicy(),
             mode: ChatMode = .normal, incognito: Bool = false, script: String = MemoryCaptureTurnTests.reply) throws {
            db = try AppDatabase.inMemory()
            memory = MemoryRuntime(database: db, policy: { policy })
            model = TurnCaptureModel(facts: facts, hold: hold)
            memory.attach(embedder: nil, model: model)
            let registry = ToolRegistry([memory.tool()])
            let runtime = ToolLoopHarness.runtime(registry: registry, database: db, tier: .t0, selection: .off)
            // An incognito chat gets no memory runtime (ChatEnvironment).
            controller = TurnController(chatID: chatID, database: db, engine: InProcessScriptedEngine(script: try EngineScript(text: script)),
                                        mode: mode, tools: runtime, memory: incognito ? nil : memory) { .scripted("inline") }
            log = UpdateLog(controller)
        }

        @discardableResult
        func send(_ text: String, parent: String? = nil) async throws -> String {
            let a = StorageID.make()
            await controller.start(.send(userID: StorageID.make(), text: text, parentID: parent), assistantID: a)
            _ = try await log.waitFinished(a)
            return a
        }

        func captured(_ id: String) -> [ToolActivity] {
            log.all.filter { $0.assistantID == id }.compactMap { if case .memoryCaptured(let a) = $0.kind { a } else { nil } }
        }

        var store: MemoryStore { memory.store }
        var calls: Int { model.calls.withLock { $0 } }
        func suggestions() throws -> [MemorySuggestion] { try db.read { try MemorySuggestion.fetchAll($0) } }
    }

    @Test func aCertainFactIsSavedAndTheReplyGetsItsUndoLine() async throws {
        let chat = try Chat()
        let a = try await chat.send(Self.metric)
        // The answer is out before anything of the capture: `.finished` precedes `.memoryCaptured`.
        await chat.controller.memoryCaptureSettled()
        try await chat.log.wait { _ in !chat.captured(a).isEmpty }
        let item = try #require(try chat.store.active().first?.item)
        #expect(item.text == "Wants measurements in metric units" && item.origin == .review && item.sourceChatID == chat.chatID)
        let event = try #require(try chat.store.events(itemID: item.id).first)
        // The line: the `memory` tool's activity shape with the event id (MemoryNotice → "Memory updated ▸ Undo").
        let line = try #require(chat.captured(a).first)
        #expect(line.tool == MemoryTool.name && line.kind == .tool && line.state == .done)
        #expect(MemoryToolExecutor.eventIDs(inResult: line.result ?? "") == [event.id])
        // Stored with the reply (a reopened chat shows it), after its text; the text is the model's, untouched.
        let parts = try MessageRepository(chat.db).parts(of: a)
        let stored = ToolActivity.activities(in: parts)
        #expect(stored.map(\.id) == [line.id] && stored.first?.result == line.result && parts.last?.kind == .activity)
        #expect(parts.filter { $0.kind == .text }.map(\.body) == ["A mile is longer. I have noted your preference for metric units."])
        let order = chat.log.all.filter { $0.assistantID == a }.compactMap { u -> String? in
            switch u.kind {
            case .finished: "finished"
            case .memoryCaptured: "captured"
            default: nil
            }
        }
        #expect(order == ["finished", "captured"])
        #expect(chat.calls == 1 && chat.memory.captures.counts.started == 1)
        // Undo through the event the line carries.
        try chat.store.undo(eventID: event.id)
        #expect(try chat.store.active().isEmpty)
        // The stored line is not sent to the model as history (only text parts are).
        try await chat.send("Thanks", parent: a)
        let history = await chat.controller.requests[0].messages.map { "\($0)" }.joined()
        #expect(!history.contains("memoryEventIDs"))
    }

    @Test func anUnsureFactBecomesAPendingSuggestionWithoutALine() async throws {
        let chat = try Chat(facts: Self.unsure)
        let a = try await chat.send(Self.metric)
        await chat.controller.memoryCaptureSettled()
        #expect(chat.calls == 1)
        #expect(try chat.store.active().isEmpty)
        #expect(try chat.suggestions().map(\.state) == [.pending])
        let lines = ToolActivity.activities(in: try MessageRepository(chat.db).parts(of: a))
        #expect(chat.captured(a).isEmpty && lines.isEmpty)
    }

    @Test func aFactThatIsAlreadyStoredOrUnparseableOutputChangesNothing() async throws {
        let chat = try Chat()
        try chat.store.insert(topic: "Units", key: "units", text: "Wants measurements in metric units", origin: .user)
        let a = try await chat.send(Self.metric)
        await chat.controller.memoryCaptureSettled()
        #expect(chat.calls == 1)
        #expect(try chat.store.active().count == 1)
        #expect(try chat.suggestions().isEmpty && chat.captured(a).isEmpty)

        let broken = try Chat(facts: "I have noted your preference.")
        let b = try await broken.send(Self.metric)
        await broken.controller.memoryCaptureSettled()
        #expect(broken.calls == 1)
        #expect(try broken.store.active().isEmpty)
        #expect(try broken.suggestions().isEmpty && broken.captured(b).isEmpty)
    }

    @Test func aTurnWhoseOwnMemoryCallSavedCostsNoCall() async throws {
        let script = """
            {"t":"toolCallDone","id":"call_1","name":"memory","args":"{\\"action\\":\\"save\\",\\"topic\\":\\"Units\\",\\"value\\":\\"Prefers metric units\\"}","delayMs":1}
            {"t":"turn"}
            {"t":"textDelta","v":"A mile is longer. Noted.","delayMs":0}
            """
        let chat = try Chat(script: script)
        let a = try await chat.send(Self.metric)
        await chat.controller.memoryCaptureSettled()
        #expect(try chat.store.active().map(\.item.text) == ["Prefers metric units"], "the tool's save, once")
        #expect(chat.calls == 0 && chat.memory.captures.counts.started == 0)
        #expect(chat.captured(a).isEmpty)
    }

    @Test(arguments: ["incognito", "paused", "off", "evil", "chatOff", "ungated"])
    func noCallAtAllWhenTheChatMayNotWriteMemoryOrTheGateStaysQuiet(_ leg: String) async throws {
        let chat: Chat
        switch leg {
        case "incognito": chat = try Chat(incognito: true)
        case "paused": chat = try Chat(policy: MemoryPolicy(mode: .paused))
        case "off": chat = try Chat(policy: MemoryPolicy(mode: .off))
        case "evil": chat = try Chat(policy: MemoryPolicy(useInEvil: false), mode: .evil)
        default: chat = try Chat()
        }
        if leg == "chatOff" {  // the chat's own "Memory off" switch
            try chat.db.write { try ChatRecord(id: chat.chatID, mode: .normal, memoryEnabled: false).insert($0) }
        }
        let a = try await chat.send(leg == "ungated" ? "Which is longer, a mile or a kilometre?" : Self.metric)
        await chat.controller.memoryCaptureSettled()
        #expect(chat.calls == 0 && chat.memory.captures.counts.started == 0, "\(leg)")
        #expect(try chat.store.active().isEmpty)
        #expect(try chat.suggestions().isEmpty && chat.captured(a).isEmpty)
    }

    @Test func evilChatsCaptureWhenTheSwitchAllowsIt() async throws {
        let chat = try Chat(policy: MemoryPolicy(useInEvil: true), mode: .evil)
        try await chat.send(Self.metric)
        await chat.controller.memoryCaptureSettled()
        #expect(chat.calls == 1)
        #expect(try chat.store.active().count == 1)
    }

    @Test func theNextMessageCancelsAnOpenCaptureWithoutSideEffects() async throws {
        let chat = try Chat(hold: true)
        let a = try await chat.send(Self.metric)
        try await chat.log.wait { _ in chat.calls == 1 }  // the extraction call is open
        #expect(!chat.memory.captures.isFree)
        // The user sends the next message: the capture is cancelled, the turn runs as usual.
        let b = try await chat.send("Thanks", parent: a)
        await chat.controller.memoryCaptureSettled()
        #expect(chat.log.finished(b)?.text == "You are welcome.")
        #expect(chat.memory.captures.counts.cancelled == 1 && chat.memory.captures.isFree)
        #expect(chat.calls == 1, "the cancelled capture is dropped, and \"Thanks\" does not fire the gate")
        #expect(try chat.store.active().isEmpty)
        #expect(try chat.suggestions().isEmpty)
        #expect(try chat.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_event") } == 0)
        let lines = ToolActivity.activities(in: try MessageRepository(chat.db).parts(of: a))
        #expect(chat.captured(a).isEmpty && lines.isEmpty)
    }

    @Test func aTurnOfAnotherChatHoldsACaptureBackAndCancelsAnOpenOne() async throws {
        let c = MemoryCaptureCoordinator()
        let other = UUID()
        c.turnBegan(other)
        #expect(c.begin { _ in Task {} } == nil, "a turn is running: nothing starts")
        c.turnEnded(other)
        let open = try #require(c.begin { _ in Task { try? await Task.sleep(for: .seconds(60)) } })
        #expect(c.begin { _ in Task {} } == nil, "one capture at a time")
        c.turnBegan(other)
        #expect(open.isCancelled && c.counts.cancelled == 1)
        await open.value
    }
}
