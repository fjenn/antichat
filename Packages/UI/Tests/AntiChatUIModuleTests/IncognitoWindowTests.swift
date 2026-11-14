// M1.T20 (R-090): the window's incognito flow on WindowState + ChatSessions: entry, a turn in the in-memory store
// (no sidebar row, no disk row, no title), the close confirmation for every way out, and discard.
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatUI

// In the serialized WindowSuites: run beside the window suites, the scripted turns starved. Those suites spin the
// main run loop from inside main-actor jobs (RunLoop.main.run(until:) in snapshot / host rigs), and a nested run
// does not drain the main queue, so every main-actor hop of a turn waited behind them: under load the reply did
// not finish inside 30 s (load ~60). Serialized with them, nothing spins while a turn runs.
extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct IncognitoWindowTests {
    private func make() throws -> (WindowState, ChatSessions, ChatEnvironment) {
        let engine = InProcessScriptedEngine(script: try EngineScript(text: #"{"t":"title","v":"Never"}"# + "\n"
            + #"{"t":"textDelta","v":"incognito reply","delayMs":5}"#))
        let env = ChatEnvironment(database: try AppDatabase.inMemory(), engine: engine, slot: { .scripted("inline") })
        let state = WindowState(service: ChatListService(environment: env), seed: 1)
        let sessions = ChatSessions(environment: env)
        state.makeIncognito = { [sessions] in try sessions.makeIncognitoSession() }  // strong: tests may drop the tuple
        state.onIncognitoClosed = { [weak sessions] in sessions?.incognitoClosed($0) }
        sessions.incognito = { [weak state] in state?.incognito }
        sessions.onEmptyChatRemoved = { [weak state] in state?.emptyChatRemoved($0) }
        state.activate()
        return (state, sessions, env)
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

    @Test func entryShowsAnEmptyIncognitoChatWithoutARow() throws {
        let (state, _, env) = try make()
        state.newIncognitoChat()
        #expect(state.isIncognito)
        #expect(state.incognito != nil)
        #expect(state.currentChatID == nil)  // no row until the first send
        #expect(!state.isDocked)
        #expect(state.canToggleIncognito)
        #expect(state.incognitoPersonalization == .personalized)
        #expect(try ChatListService(environment: env).sidebarCount() == 0)
        // The toolbar button on an empty incognito chat leaves it without asking.
        let session = try #require(state.incognito)
        state.toggleIncognito()
        #expect(state.route == .newChat)
        #expect(state.pendingIncognitoLeave == nil)
        #expect(session.isClosed)
        #expect(!FileManager.default.fileExists(atPath: session.tempDirectory.path))
    }

    @Test func aTurnStaysInMemoryAndLeavingAsksFirst() async throws {
        let (state, sessions, env) = try make()
        state.newIncognitoChat()
        state.incognitoPersonalization = .unpersonalized
        let session = try #require(state.incognito)
        send("zephyrquartz hello", state, sessions)
        let chatID = try #require(state.currentChatID)
        #expect(state.isIncognito && state.isDocked)
        #expect(!state.canToggleIncognito)  // disabled inside a non-empty chat
        let m = sessions.model(for: chatID)
        #expect(await until { !m.isGenerating && m.messages.last?.text == "incognito reply" })
        #expect(env.stores.isEphemeral(chatID))
        #expect(try ChatRepository(env.database).chat(chatID) == nil)
        #expect(try ChatRepository(session.store).chat(chatID) != nil)
        #expect(try ChatListService(environment: env).sidebarCount() == 0)
        #expect(state.sidebar.isEmpty)
        #expect(session.engine.lastRequest?.incognito == true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sessions.titleLatency[chatID] == nil)  // no title call
        #expect(session.personalization == .unpersonalized)

        // ⌘N asks; Cancel keeps the chat.
        state.newChat()
        #expect(state.pendingIncognitoLeave == .newChat)
        #expect(state.isIncognito)
        state.cancelIncognitoLeave()
        #expect(state.isIncognito && state.pendingIncognitoLeave == nil)
        // A sidebar click asks too; confirming navigates and discards.
        state.open(.library)
        #expect(state.pendingIncognitoLeave == .navigate(.library))
        state.confirmIncognitoLeave()
        #expect(state.route == .library)
        #expect(state.incognito == nil && session.isClosed)
        #expect(!env.stores.isEphemeral(chatID))
        #expect(!FileManager.default.fileExists(atPath: session.tempDirectory.path))
        #expect(!state.backStack.contains(.incognito) && !state.forwardStack.contains(.incognito))
    }

    @Test func closingTheWindowAndQuittingAsk() async throws {
        let (state, sessions, _) = try make()
        var closed = 0
        var quitAnswer: Bool?
        state.closeWindow = { closed += 1 }
        state.answerQuit = { quitAnswer = $0 }
        state.newIncognitoChat()
        send("hello", state, sessions)
        #expect(state.hasIncognitoContent)
        #expect(!state.requestCloseWindow())
        #expect(state.pendingIncognitoLeave == .closeWindow)
        state.cancelIncognitoLeave()
        #expect(closed == 0 && state.isIncognito)
        #expect(!state.requestQuit())
        state.cancelIncognitoLeave()
        #expect(quitAnswer == false)
        #expect(!state.requestCloseWindow())
        state.confirmIncognitoLeave()
        #expect(closed == 1)
        #expect(state.incognito == nil)
        // Without content the window closes at once.
        state.newIncognitoChat()
        #expect(state.requestCloseWindow())
        #expect(state.incognito == nil)
    }
}
}  // extension WindowSuites
