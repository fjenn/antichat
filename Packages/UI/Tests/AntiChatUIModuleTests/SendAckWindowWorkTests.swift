// M9.T05 (NFR-U2 send ack ≤ 16 ms): which window views a send re-evaluates in its ack frame, counted on the real
// MainWindow + ChatSessions + LiveComposer in an NSWindow of the test process (ScriptedEngine, in-memory database).
// The ack frame draws the user's bubble, the pending reply and Send → Stop, and empties the field. It re-evaluates
// the conversation column (its message list changed), its two new rows, the composer's hosts (WindowComposer and
// LiveComposer: the window's composer text and the shown chat's phase), the composer's placeholder and its Send/Stop
// button; not
// MainWindow (toolbar, split view), not the sidebar or any of its rows, not the composer's body (the + button and
// its popovers, chips, Think harder, mode switch, mic buttons, status row) and no row already on screen.
// Counted through `ViewWork` / `SidebarChatRow.evaluated` / `ConversationRow.evaluated` (DEBUG only; no timing).
//   make test-unit FILTER=SendAckWindowWorkTests
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import AppKit
import Foundation
import QuartzCore
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct SendAckWindowWorkTests {
    @MainActor private struct Rig {
        let env: ChatEnvironment
        let state: WindowState
        let sessions: ChatSessions
        let window: NSWindow
        var composer: ComposerModel { sessions.composer }
    }

    private static func spinRunLoop(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func pump(_ ms: Int) async {
        let end = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < end {
            Self.spinRunLoop(0.005)
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func until(_ timeout: Double = 15, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            await pump(10)
        }
        return cond()
    }

    private func make() async throws -> Rig {
        _ = NSApplication.shared
        BackgroundRun.enable()
        let engine = InProcessScriptedEngine(script: try EngineScript(
            text: #"{"t":"textDelta","v":"A finished **reply** with a [link](https://example.com).","delayMs":20}"#))
        let env = ChatEnvironment(database: try AppDatabase.inMemory(), engine: engine, slot: { .scripted("inline") })
        let state = WindowState(service: ChatListService(environment: env), seed: 1)
        let sessions = ChatSessions(environment: env)
        state.rowActivity = { [weak sessions] in sessions?.activity(for: $0) ?? .idle }
        sessions.onTitle = { [weak state] in state?.applyTitle($0, title: $1) }
        sessions.onEmptyChatRemoved = { [weak state] in state?.emptyChatRemoved($0) }
        let host = NSHostingView(rootView: MainWindow(state: state, slots: sessions.slots))
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1180, height: 820),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        BackgroundRun.present(window)
        await pump(500)
        return Rig(env: env, state: state, sessions: sessions, window: window)
    }

    /// Types `text` into the composer and sends it with the composer's own Send (as Return does).
    private func send(_ text: String, _ rig: Rig) async -> Bool {
        rig.composer.text = text
        await pump(60)
        return rig.composer.send()
    }

    @Test func theAckFrameReEvaluatesOnlyWhatTheSendChanged() async throws {
        let rig = try await make()
        defer { rig.window.close() }
        // Other chats in the sidebar (their rows must stay untouched).
        for t in ["Trip to Lisbon", "Sourdough", "Bike repair"] {
            let c = try rig.state.service.create(firstPrompt: t)
            try rig.state.service.appendUserMessage(c.id, text: t)
        }
        #expect(await send("first", rig))
        #expect(await until { rig.state.currentChatID != nil && rig.state.isDocked })
        let chatID = try #require(rig.state.currentChatID)
        // The toolbar (title, Outputs, Share, ⋯) follows the new chat after the first send's ack frame.
        #expect(await until(5) { rig.state.toolbarChatID == chatID }, "the toolbar never showed the new chat")
        let m = rig.sessions.model(for: chatID)
        #expect(await until { !m.isGenerating && m.messages.count == 2 })
        for i in 0..<3 {
            #expect(await send("again \(i)", rig))
            #expect(await until { !m.isGenerating && m.messages.count == 4 + 2 * i })
        }
        // Settled: the sidebar has the chat's stored row, the title, the reply's end and the drafts are done.
        await pump(1500)
        rig.composer.text = "measured"
        await pump(300)
        let host = try #require(rig.window.contentView)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let before = Set(m.messages.map(\.id))

        ViewWork.evaluated = []
        SidebarChatRow.evaluated = []
        ConversationRow.evaluated = []
        // The ack frame: the Return key's implicit transaction stands open while the window updates (as in the app).
        CATransaction.begin()
        #expect(rig.composer.send())
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let views = ViewWork.evaluated
        let sidebarRows = SidebarChatRow.evaluated
        let rows = ConversationRow.evaluated
        CATransaction.commit()
        print("SendAckWindowWork ack frame: views \(views), sidebar rows \(sidebarRows.count), transcript rows \(rows.count)")

        let sent = Set(m.messages.map(\.id)).subtracting(before)
        #expect(sent.count == 2)
        #expect(m.isGenerating || m.messages.last?.status != .pending, "the send started no turn")
        #expect(rig.composer.text.isEmpty, "the field was not emptied")
        // What the send changed was drawn in the ack frame.
        #expect(views.contains("conversation"), "the new rows were not drawn in the ack frame")
        #expect(views.contains("sendStop"), "Send → Stop was not drawn in the ack frame")
        #expect(views.contains("placeholder"), "the emptied field's placeholder was not drawn in the ack frame")
        #expect(sent.isSubset(of: Set(rows)), "the sent rows were not drawn in the ack frame")
        // And nothing else.
        let allowed: Set<String> = ["conversation", "windowComposer", "liveComposer", "placeholder", "sendStop"]
        #expect(Set(views).isSubset(of: allowed), "the ack frame re-evaluated \(Set(views).subtracting(allowed).sorted())")
        #expect(sidebarRows.isEmpty, "the ack frame re-evaluated \(sidebarRows.count) sidebar rows")
        #expect(Set(rows).isSubset(of: sent), "the ack frame re-evaluated \(Set(rows).subtracting(sent).count) older rows")

        // The work deferred past the ack frame still happens: the sidebar spinner, then the reply, then Send again.
        #expect(await until(5) { rig.sessions.activity(for: chatID) == .streaming || !m.isGenerating })
        #expect(await until { !m.isGenerating && m.messages.count == 10 })
        #expect(await until(5) { rig.composer.phase == .idle })
        #expect(rig.sessions.activity(for: chatID) == .idle)
        // Leaving the chat clears the toolbar's chat at once (no deferral outside a new chat's first send).
        rig.state.newChat()
        await pump(100)
        #expect(rig.state.toolbarChatID == nil)
    }

    /// The environment ConversationView hands its transcript is the same value on every pass (a new closure changed
    /// the environment of every row, and every platform view in them was updated in a send's ack frame), and it acts
    /// on the column's current model.
    @Test func conversationEnvironmentActionsAreStable() throws {
        let env = ChatEnvironment(database: try AppDatabase.inMemory(),
                                  engine: InProcessScriptedEngine(script: try EngineScript(text: #"{"t":"textDelta","v":"ok"}"#)),
                                  slot: { .scripted("inline") })
        let a = ConversationModel(environment: env, chatID: nil), b = ConversationModel(environment: env, chatID: nil)
        let actions = ConversationActions(model: a)
        func bytes<T>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v) { Array($0) } }
        let lookup = bytes(actions.bind(a).artifactLookup), image = bytes(actions.openImageViewer)
        let video = bytes(actions.openVideoViewer)
        #expect(bytes(actions.bind(a).artifactLookup) == lookup)
        #expect(bytes(actions.openImageViewer) == image)
        #expect(bytes(actions.openVideoViewer) == video)
        // Rebound to another chat's model: the same values, acting on the new model.
        #expect(bytes(actions.bind(b).artifactLookup) == lookup)
        actions.openImageViewer(ImageViewerTarget(paths: ["/tmp/none.png"], selected: 0, artifactID: nil, current: "/tmp/none.png"))
        #expect(b.imageViewer?.id == "/tmp/none.png" && a.imageViewer == nil)
        actions.openVideoViewer(VideoViewerTarget(path: "/tmp/none.mp4"))
        #expect(actions.video?.id == "/tmp/none.mp4")
    }

    /// A keystroke reaches the composer's host and placeholder only (MainWindow made the composer's text binding in
    /// its body, so every keystroke re-evaluated the whole window).
    @Test func typingReEvaluatesOnlyTheComposerHost() async throws {
        let rig = try await make()
        defer { rig.window.close() }
        #expect(await send("first", rig))
        #expect(await until { rig.state.isDocked && !(rig.sessions.current?.isGenerating ?? true) })
        await pump(1000)
        let host = try #require(rig.window.contentView)
        rig.composer.text = "Hel"
        await pump(200)
        ViewWork.evaluated = []
        rig.composer.text = "Hell"
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        await pump(100)
        let views = Set(ViewWork.evaluated)
        print("SendAckWindowWork keystroke: views \(ViewWork.evaluated)")
        #expect(rig.state.composerText == "Hell", "the window's composer text did not follow the field")
        let allowed: Set<String> = ["windowComposer", "liveComposer", "placeholder", "sendStop"]
        #expect(views.isSubset(of: allowed), "a keystroke re-evaluated \(views.subtracting(allowed).sorted())")
    }
}
}
