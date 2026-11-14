// M1.T19 host tests (window wiring on the ScriptedEngine, no app): the follow-up queue drains in order and skips a
// removed message (AT-014 (1)); ⌘Return stops the reply (interrupted) and sends first (AT-014 (2)); a send while the
// model loads is held with a rising percent and released by `.ready`, a cancelled one sends nothing and leaves no
// chat row (AT-299); the completion pass changes the composer, the spinner and the message together (AT-003 (4));
// a reply that ends off screen marks its chat unread, opening clears it; the auto title replaces the temporary one
// (AT-010 (1)(3)).
//   make test-unit FILTER=TurnQueueHostTests
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import Foundation
import Synchronization
import Testing
@testable import AntiChatUI

// In the serialized WindowSuites: run beside the window suites, the scripted turns starved. Those suites spin the
// main run loop from inside main-actor jobs (RunLoop.main.run(until:) in snapshot / host rigs), and a nested run
// does not drain the main queue, so every main-actor hop of a turn waited behind them: under load the reply did
// not finish inside 30 s (load ~60). Serialized with them, nothing spins while a turn runs.
extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct TurnQueueHostTests {
    private func make(_ script: String) throws -> (WindowState, ChatSessions, ChatEnvironment, InProcessScriptedEngine) {
        let engine = InProcessScriptedEngine(script: try EngineScript(text: script))
        let env = ChatEnvironment(database: try AppDatabase.inMemory(), engine: engine, slot: { .scripted("inline") })
        let state = WindowState(service: ChatListService(environment: env), seed: 1)
        let sessions = ChatSessions(environment: env)
        state.rowActivity = { [weak sessions] in sessions?.activity(for: $0) ?? .idle }
        sessions.onTitle = { [weak state] in state?.applyTitle($0, title: $1) }
        sessions.onEmptyChatRemoved = { [weak state] in state?.emptyChatRemoved($0) }
        state.activate()
        return (state, sessions, env, engine)
    }

    private func until(_ timeout: Double = 30, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return cond()
    }

    private func send(_ text: String, _ state: WindowState, _ sessions: ChatSessions) {
        sessions.currentChatID = state.currentChatID
        state.send(text, reduceMotion: true, turn: sessions.slots.startTurn)
        sessions.currentChatID = state.currentChatID
    }

    private func userTexts(_ chatID: String, _ env: ChatEnvironment) throws -> [String] {
        try env.database.read { db in
            try MessageTree.visiblePath(chatID, db: db).filter { $0.role == .user }
                .map { try MessageRepository.parts(of: $0.id, db: db).map(\.body).joined() }
        }
    }

    @Test func followUpsDrainInOrderAndSkipTheRemovedOne() async throws {
        let (state, sessions, env, engine) = try make(#"{"t":"textDelta","v":"slow reply","delayMs":200}"#)
        send("first", state, sessions)
        let chatID = try #require(state.currentChatID)
        let m = sessions.model(for: chatID)
        send("A", state, sessions)
        send("B", state, sessions)
        send("C", state, sessions)
        #expect(m.followUps.items.map(\.text) == ["A", "B", "C"])
        m.editQueued(m.followUps.items[1].id, text: "B edited")
        m.removeQueued(m.followUps.items[2].id)
        #expect(await until(60) { m.followUps.isEmpty && !m.isGenerating && m.messages.count == 6 })
        #expect(try userTexts(chatID, env) == ["first", "A", "B edited"])
        #expect(engine.requestCount == 3 + 1)  // + the chat's one title request
    }

    @Test func commandReturnStopsAndSendsFirst() async throws {
        let (state, sessions, env, _) = try make(#"{"t":"textDelta","v":" word","delayMs":20,"repeat":3000}"#)
        send("long one", state, sessions)
        let chatID = try #require(state.currentChatID)
        let m = sessions.model(for: chatID)
        #expect(await until { m.messages.last?.status == .streaming })
        let first = try #require(m.messages.last?.id)
        send("queued", state, sessions)
        #expect(m.sendNow("now please"))
        #expect(await until { m.messages.first { $0.id == first }?.status == .interrupted })
        #expect(await until { (try? userTexts(chatID, env).count) == 2 })
        #expect(try userTexts(chatID, env) == ["long one", "now please"])  // before the queued follow-up
        #expect(m.followUps.items.map(\.text) == ["queued"])
        m.stop()
        #expect(await until(30) { m.followUps.isEmpty && (try? userTexts(chatID, env).count) == 3 })
        m.stop()
    }

    @Test func heldUntilReadyThenReleased() async throws {
        let (state, sessions, env, engine) = try make(#"{"t":"textDelta","v":"ok"}"#)
        sessions.readinessEvent(.lifecycle(.loadState(.loading)))
        sessions.readinessEvent(.lifecycle(.loadProgress(0.2)))
        #expect(sessions.composer.availability == .queued(percent: 20))
        send("before ready", state, sessions)
        let chatID = try #require(state.currentChatID)
        let m = sessions.model(for: chatID)
        #expect(m.heldUserID != nil)
        #expect(m.isGenerating)  // Stop shows; the reply area shows status.loadingModel
        #expect(m.messages.last.map { m.statusModel(for: $0).status(elapsed: .zero) } == .loadingModel)
        #expect(m.heldPercent == 20)
        sessions.readinessEvent(.lifecycle(.loadProgress(0.6)))
        #expect(m.heldPercent == 60)
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.requestCount == 0)
        #expect(try userTexts(chatID, env).isEmpty)  // nothing written while held
        sessions.readinessEvent(.lifecycle(.loadState(.ready)))
        let ready = try #require(sessions.lastReadyAt)
        let released = try #require(m.lastReleaseAt)
        // Released by the ready event itself: no await between the event and these checks, so the hold is gone
        // synchronously (order; the old < 200 ms gap measured the host's load).
        #expect(released >= ready)
        #expect(m.heldUserID == nil)
        #expect(await until { engine.requestCount == 2 && !m.isGenerating })  // reply + title
        #expect(try userTexts(chatID, env) == ["before ready"])
    }

    @Test func cancelledHeldSendSendsNothingAndLeavesNoRow() async throws {
        let (state, sessions, env, engine) = try make(#"{"t":"textDelta","v":"ok"}"#)
        sessions.readinessEvent(.lifecycle(.loadState(.loading)))
        send("never sent", state, sessions)
        let chatID = try #require(state.currentChatID)
        let m = sessions.model(for: chatID)
        m.cancelHeld()
        #expect(m.messages.isEmpty && !m.isGenerating)
        #expect(state.route == .newChat)
        #expect(try ChatRepository(env.database).chat(chatID) == nil)
        sessions.readinessEvent(.lifecycle(.loadState(.ready)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.requestCount == 0)
    }

    @Test func completionPassChangesEverythingTogether() async throws {
        let (state, sessions, _, _) = try make(#"{"t":"textDelta","v":"done soon","delayMs":20}"#)
        var seen: [String: Bool] = [:]
        sessions.composer.text = "go"
        send("go", state, sessions)
        sessions.composer.turnStarted()
        let chatID = try #require(state.currentChatID)
        let m = sessions.model(for: chatID)
        // fix/t05-u2-u5: the spinner starts once the send's ack frame has committed (`ConversationModel.afterAck`).
        #expect(await until { sessions.activity(for: chatID) == .streaming })
        sessions.completion.register { c in
            seen["composerIdle"] = sessions.composer.phase == .idle
            seen["spinnerOff"] = sessions.activity(for: c.chatID) == .idle
            seen["messageDone"] = m.messages.last?.status == .done
            seen["statusHidden"] = m.messages.last.map { m.statusModel(for: $0).status(elapsed: .seconds(9)) == .hidden } ?? false
        }
        #expect(await until { !m.isGenerating })
        #expect(seen == ["composerIdle": true, "spinnerOff": true, "messageDone": true, "statusHidden": true])
        #expect(sessions.completion.history.count == 1)
    }

    @Test func backgroundReplyMarksUnreadAndAutoTitleApplies() async throws {
        let (state, sessions, env, _) = try make("""
            {"t":"title","v":"Background harbour question","delayMs":10}
            {"t":"textDelta","v":"answer","delayMs":150}
            """)
        send("A question about the harbour that is answered in the background", state, sessions)
        let chatID = try #require(state.currentChatID)
        #expect(state.sidebar.first?.title == TitleService.temporaryTitle("A question about the harbour that is answered in the background"))
        // Leave the chat while it replies.
        state.newChat()
        sessions.currentChatID = nil
        let m = sessions.model(for: chatID)
        #expect(await until { !m.isGenerating })
        #expect(await until { (try? ChatRepository(env.database).chat(chatID))?.unread == true })
        #expect(await until { state.sidebar.first { $0.id == chatID }?.title == "Background harbour question" })
        #expect(try ChatRepository(env.database).chat(chatID)?.titleState == .auto)
        #expect(await until { state.sidebar.first { $0.id == chatID }?.unread == true })
        state.open(.chat(chatID))
        #expect(try ChatRepository(env.database).chat(chatID)?.unread == false)
    }

    /// S3 review (AT-NFR-S3): the first prompt was edited (VQ round 65 S-09). The re-title is enqueued on the writer
    /// (the call returns while the writer is busy), the sidebar row shows the edited prompt's temporary title (pending
    /// again), and a title the user set is never overwritten.
    @Test func retitleAfterEditIsEnqueuedAndKeepsARename() async throws {
        let (state, sessions, env, _) = try make("""
            {"t":"title","v":"Harbour question","delayMs":10}
            {"t":"textDelta","v":"answer","delayMs":20}
            """)
        send("A question about the harbour", state, sessions)
        let chatID = try #require(state.currentChatID)
        let m = sessions.model(for: chatID)
        #expect(await until { !m.isGenerating })
        #expect(await until { (try? ChatRepository(env.database).chat(chatID))?.titleState == .auto })

        let edited = "What time does the ferry leave the harbour tomorrow"
        let applied = Mutex<Bool?>(nil)
        sessions.retitle(chatID: chatID, firstPrompt: edited) { ok in applied.withLock { $0 = ok } }
        #expect(await until { applied.withLock { $0 } != nil })
        #expect(applied.withLock { $0 } == true)
        let row = try #require(try ChatRepository(env.database).chat(chatID))
        #expect(row.title == TitleService.temporaryTitle(edited) && row.titleState == .pending)
        #expect(await until { state.sidebar.first { $0.id == chatID }?.title == TitleService.temporaryTitle(edited) })

        // A rename wins: the re-title changes nothing.
        try ChatListService(environment: env).rename(chatID, to: "Mine")
        let kept = Mutex<Bool?>(nil)
        sessions.retitle(chatID: chatID, firstPrompt: "Something else entirely about boats") { ok in kept.withLock { $0 = ok } }
        #expect(await until { kept.withLock { $0 } != nil })
        #expect(kept.withLock { $0 } == false)
        let renamed = try #require(try ChatRepository(env.database).chat(chatID))
        #expect(renamed.title == "Mine" && renamed.titleState == .user)
    }
}
}  // extension WindowSuites
