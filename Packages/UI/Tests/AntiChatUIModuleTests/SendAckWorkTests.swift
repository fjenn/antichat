// M9.T05 (NFR-U2 send ack ≤ 16 ms): structural / work-counting checks of what a send does in its ack frame (no
// timing). The ack frame draws the user's bubble and the pending reply; it no longer
//   - moves the transcript's eager/lazy boundary (the two oldest eager rows were rebuilt in the ack frame),
//   - writes `chat.tools_json` when the chips did not change (a main-thread write + a sidebar re-fetch per send),
//   - re-evaluates the rows already on screen (fix/t05-u2-u5: closures that never compare equal and `busy` made every
//     row on screen rebuild in the ack frame),
//   - flips the rows' busy state, starts the sidebar spinner or saves the chips (after the ack: `afterAck`).
//   make test-unit FILTER=SendAckWorkTests
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import Foundation
import QuartzCore
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct SendAckWorkTests {
    typealias List = TranscriptList<ConversationModel.Message, EmptyView>

    @Test func unsettledSendRowsDoNotMoveTheLazyBoundary() {
        let tail = List.eagerTail, step = List.splitStep
        /// Merge (fix/t05-ui-latency × fix/u5-renderer-4): the boundary moves in `splitStep` steps.
        func stepped(_ n: Int) -> Int { max(0, (n - tail) / step * step) }
        // A send that crosses a step: settled rows put the boundary just below the step, the send's 2 rows cross it.
        let settled = tail + 3 * step - 1      // boundary at 2 steps
        #expect(List.lazyCount(items: settled, unsettled: 0) == stepped(settled))
        // While unsettled the boundary stays where the previous frame had it (the step is not taken in the ack frame).
        #expect(List.lazyCount(items: settled + 2, unsettled: 2) == stepped(settled))
        #expect(stepped(settled + 2) > stepped(settled), "the fixture must cross a step")
        // The next frame (settled): the boundary catches up.
        #expect(List.lazyCount(items: settled + 2, unsettled: 0) == stepped(settled + 2))
        // A short chat has no lazy section either way.
        #expect(List.lazyCount(items: 4, unsettled: 2) == 0)
        #expect(List.lazyCount(items: 10, unsettled: 2) == 0)
        // A large jump (another chat, a history load) is never held: no eager section of hundreds of rows.
        #expect(List.lazyCount(items: 500, unsettled: 400) == stepped(500))
        #expect(List.lazyCount(items: 500, unsettled: List.maxUnsettledRows + 1) == stepped(500))
        // The single-argument form is the settled rule.
        #expect(List.lazyCount(61) == List.lazyCount(items: 61, unsettled: 0))
    }

    private func make(_ script: String) throws -> (WindowState, ChatSessions, ChatEnvironment) {
        let engine = InProcessScriptedEngine(script: try EngineScript(text: script))
        let env = ChatEnvironment(database: try AppDatabase.inMemory(), engine: engine, slot: { .scripted("inline") })
        let state = WindowState(service: ChatListService(environment: env), seed: 1)
        let sessions = ChatSessions(environment: env)
        state.rowActivity = { [weak sessions] in sessions?.activity(for: $0) ?? .idle }
        sessions.onTitle = { [weak state] in state?.applyTitle($0, title: $1) }
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

    private func frames(_ h: RendererRig.Host, _ n: Int = 4) async {
        for _ in 0..<n {
            try? await Task.sleep(for: .milliseconds(20))
            h.host.layoutSubtreeIfNeeded()
            h.host.displayIfNeeded()
        }
    }

    /// fix/t05-u2-u5: in a chat with turns on screen, a send's ack frame evaluates its own two rows and no other; the
    /// rows' busy state and the sidebar spinner change after it. The reply's end then re-evaluates the reply's row
    /// only (its action bars follow the busy state through the environment). Before: every row on screen, twice.
    @Test func theAckFrameEvaluatesOnlyTheSentRows() async throws {
        let (state, sessions, _) = try make(#"{"t":"textDelta","v":"A finished **reply** with a [link](https://example.com).","delayMs":150}"#)
        send("first", state, sessions)
        let chatID = try #require(state.currentChatID)
        let m = sessions.model(for: chatID)
        #expect(await until { !m.isGenerating && m.messages.count == 2 })
        let h = RendererRig.Host(ConversationView(model: m).frame(height: 900), look: .light)
        for i in 0..<5 {
            send("again \(i)", state, sessions)
            #expect(await until { !m.isGenerating && m.messages.count == 4 + 2 * i })
            await frames(h)
        }
        await h.settle()
        await frames(h, 10)
        let before = Set(m.messages.map(\.id))
        ConversationRow.evaluated = []
        h.host.layoutSubtreeIfNeeded()
        h.host.displayIfNeeded()
        #expect(ConversationRow.evaluated.filter(before.contains).isEmpty, "rows re-evaluated while idle")

        // The ack frame: the key event's implicit transaction stands open while the window updates (as in the app).
        CATransaction.begin()
        send("measured", state, sessions)
        let busyAtSend = m.rowsBusy
        let spinnerAtSend = sessions.activity(for: chatID)
        #expect(m.ackPending)
        h.host.layoutSubtreeIfNeeded()
        h.host.displayIfNeeded()
        let ids = Set(m.messages.map(\.id))  // another suite's rows (parallel runs) do not count
        let inAck = ConversationRow.evaluated.filter(ids.contains)
        CATransaction.commit()
        #expect(await until(5) { !m.ackPending }, "the ack frame never committed")
        let sent = Set(m.messages.map(\.id)).subtracting(before)
        print("SendAckWork ack frame: rows evaluated \(inAck.count) (\(Set(inAck).count) distinct), \(before.count) rows before")
        #expect(sent.count == 2)
        #expect(sent.isSubset(of: Set(inAck)), "the sent rows were not drawn in the ack frame")
        #expect(Set(inAck).isSubset(of: sent), "the ack frame re-evaluated \(Set(inAck).subtracting(sent).count) older rows")
        #expect(!busyAtSend, "the rows' busy state changed in the ack frame")
        #expect(spinnerAtSend == .idle, "the sidebar spinner started in the ack frame")
        #expect(await until(5) { m.rowsBusy || !m.isGenerating }, "the rows' busy state never followed the turn")

        // The frame after the ack (the previous reply's bar hides), then the reply's end: the reply's row only.
        await frames(h)
        ConversationRow.evaluated = []
        let replyID = try #require(m.messages.last?.id)
        #expect(await until { !m.isGenerating })
        await frames(h, 6)
        #expect(!m.rowsBusy)
        let atEnd = Set(ConversationRow.evaluated.filter(ids.contains))
        #expect(atEnd.isSubset(of: [replyID]),
                "the reply's end re-evaluated \(atEnd.subtracting([replyID]).count) other rows")
    }

    /// RC e8fe19986 (ComposerMenusTests leg 3): a new chat's first send shows the new chat (LiveComposer -> showTools)
    /// before the chips' deferred save; the composer must keep the sticky chips, and the save still lands.
    @Test func newChatKeepsItsChipsWhenShownBeforeTheDeferredSave() async throws {
        let (state, sessions, env) = try make(#"{"t":"textDelta","v":"ok"}"#)
        sessions.composer.menus.chips.load(toolsJSON: #"["tool:echo"]"#)
        send("first", state, sessions)
        let chatID = try #require(state.currentChatID)
        let m = sessions.model(for: chatID)
        sessions.showTools(for: chatID)  // what LiveComposer does when the window's chat id changes
        #expect(sessions.composer.menus.chips.contains("tool:echo"), "the chip is still there for the next message")
        #expect(await until { !m.ackPending })
        #expect(await until { (try? ChatRepository(env.database).toolsJSON(chatID)) == #"["tool:echo"]"# })
        sessions.showTools(for: chatID)
        #expect(sessions.composer.menus.chips.contains("tool:echo"), "read back from chat.tools_json")
        #expect(await until { !m.isGenerating })
    }

    @Test func sendsWithUnchangedChipsDoNotRewriteToolsJSON() async throws {
        let (state, sessions, env) = try make(#"{"t":"textDelta","v":"ok"}"#)
        send("first", state, sessions)
        let chatID = try #require(state.currentChatID)
        let m = sessions.model(for: chatID)
        #expect(await until { !m.isGenerating && m.messages.count == 2 })
        let stored = try ChatRepository(env.database).toolsJSON(chatID)
        let skippedAfterFirst = sessions.toolsWritesSkipped
        for i in 0..<3 {
            send("again \(i)", state, sessions)
            #expect(await until { !m.isGenerating && m.messages.count == 4 + 2 * i })
        }
        #expect(sessions.acceptedSends == 4)
        #expect(sessions.toolsWritesSkipped >= skippedAfterFirst + 3, "the unchanged chip save of each send is skipped")
        #expect(try ChatRepository(env.database).toolsJSON(chatID) == stored, "the sticky chips are unchanged")
        // The send's rows settle once their frame commits (never left holding the boundary).
        #expect(await until { m.unsettledRows == 0 })
    }
}
}
