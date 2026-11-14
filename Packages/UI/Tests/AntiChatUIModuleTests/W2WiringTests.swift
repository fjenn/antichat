// W2 wiring (A-M1-W2-wire): MainWindow's send path through `ChatSessions.slots` on the ScriptedEngine. A send in a
// new chat creates the row, docks, and streams the reply into the chat's ConversationModel; paste cards are saved
// on the user message; a send while the chat is replying is queued behind the reply (M1.T19, R-014; it was refused
// before M1.T19).
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct W2WiringTests {
    private func make(_ script: String) throws -> (WindowState, ChatSessions, ChatEnvironment) {
        let env = ChatEnvironment(
            database: try AppDatabase.inMemory(), engine: InProcessScriptedEngine(script: try EngineScript(text: script)),
            slot: { .scripted("inline") })
        let state = WindowState(service: ChatListService(environment: env), seed: 1)
        return (state, ChatSessions(environment: env), env)
    }

    private func waitIdle(_ m: ConversationModel) async {
        for _ in 0..<500 where m.isGenerating || [.pending, .streaming].contains(m.messages.last?.status) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func sendInNewChatStreamsReply() async throws {
        let (state, sessions, _) = try make("""
            {"t":"textDelta","v":"Hello!","delayMs":5}
            {"t":"textDelta","v":" How can I help?","delayMs":5}
            """)
        let slots = sessions.slots
        #expect(slots.conversation != nil)
        state.send("hi", reduceMotion: true, turn: slots.startTurn)
        let chatID = try #require(state.currentChatID)
        #expect(state.isDocked)
        let model = sessions.model(for: chatID)
        #expect(model.isGenerating)  // send acknowledgement: Stop at once
        #expect(sessions.acceptedSends == 1)
        await waitIdle(model)
        #expect(model.messages.map(\.role) == [.user, .assistant])
        #expect(model.messages.last?.text == "Hello! How can I help?")
        #expect(try state.service.transcript(chatID).map(\.text) == ["hi", "Hello! How can I help?"])
    }

    @Test func pasteCardIsSavedOnTheUserMessage() async throws {
        let (state, sessions, env) = try make(#"{"t":"textDelta","v":"ok","delayMs":1}"#)
        let pasted = String(repeating: "y", count: 10_001)
        state.send("", pastedTexts: [pasted], reduceMotion: true, turn: sessions.slots.startTurn)
        let chatID = try #require(state.currentChatID)
        let model = sessions.model(for: chatID)
        await waitIdle(model)
        let userID = try #require(model.messages.first?.id)
        let cards = try AttachmentRepository(env.database).attachments(messageID: userID)
        #expect(cards.count == 1)
        #expect(try env.pastes.text(of: cards[0]) == pasted)
    }

    @Test func sendWhileReplyingIsQueued() async throws {
        let (state, sessions, _) = try make(#"{"t":"textDelta","v":"slow","delayMs":300}"#)
        state.send("one", reduceMotion: true, turn: sessions.slots.startTurn)
        let model = sessions.model(for: try #require(state.currentChatID))
        state.send("two", reduceMotion: true, turn: sessions.slots.startTurn)
        #expect(sessions.acceptedSends == 2)
        #expect(model.followUps.items.map(\.text) == ["two"])
        model.stop()  // the turn ends (interrupted) → "two" goes out
        for _ in 0..<300 where !model.followUps.isEmpty || model.messages.count < 4 { try? await Task.sleep(for: .milliseconds(10)) }
        await waitIdle(model)
        #expect(model.messages.filter { $0.role == .user }.map(\.text) == ["one", "two"])
        #expect(!model.isGenerating)
    }
}
