// M1.T24 steps 2–3 (AT-103 (1) ⌘F / ⌘A legs, in-process): the find model counts every occurrence case- and
// diacritic-insensitively, steps with wrap-around and keeps its place when the transcript changes; the hosted
// ConversationView shows the bar, tints the matched rows and outlines the current one; Edit › Select All without a
// focused text view selects the transcript only and Copy copies exactly its text; with a text view focused both
// go to that view (the menu path itself is driven in the app by `-ShortcutsProbe`).
//   make test-unit FILTER=FindInChatTests
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import AppKit
import SwiftUI
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct FindInChatModelTests {
    let texts: [(id: String, text: String)] = [
        ("u1", "Tell me about the Harbour."),
        ("a1", "The harbour is old. HARBOUR walls, a café by the harbour."),
        ("u2", "And the lighthouse?"),
        ("a2", "The lighthouse stands at the harbour mouth."),
    ]

    @Test func countsEveryOccurrenceIgnoringCaseAndDiacritics() {
        let m = FindInChatModel()
        m.update(texts)
        m.query = "harbour"
        #expect(m.matches.count == 5)
        #expect(m.matches.map(\.messageID) == ["u1", "a1", "a1", "a1", "a2"])
        #expect(m.label == "1 of 5")
        m.query = "cafe"
        #expect(m.matches.map(\.messageID) == ["a1"])
        m.query = "zebra"
        #expect(m.current == nil && m.label == "No results")
        m.query = ""
        #expect(m.matches.isEmpty && m.label.isEmpty)
    }

    @Test func nextAndPreviousWrapAround() {
        let m = FindInChatModel()
        m.update(texts)
        m.query = "lighthouse"
        #expect(m.currentMatch?.messageID == "u2")
        m.next()
        #expect(m.currentMatch?.messageID == "a2" && m.label == "2 of 2")
        m.next()
        #expect(m.currentMatch?.messageID == "u2")
        m.previous()
        #expect(m.currentMatch?.messageID == "a2")
    }

    @Test func keepsItsPlaceWhenTheTranscriptGrows() {
        let m = FindInChatModel()
        m.update(texts)
        m.query = "lighthouse"
        m.next()
        m.update(texts + [("u3", "One more lighthouse question")])
        #expect(m.currentMatch?.messageID == "a2")
        #expect(m.matches.count == 3)
    }

    @Test func dismissClearsTheQuery() {
        let m = FindInChatModel()
        m.present()
        m.update(texts)
        m.query = "harbour"
        m.dismiss()
        #expect(!m.isPresented && m.query.isEmpty && m.matches.isEmpty)
    }
}

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct FindInChatWindowTests {
    struct Rig {
        let state: WindowState
        let sessions: ChatSessions
        let model: ConversationModel
        let window: NSWindow
    }

    private func make() async throws -> Rig {
        _ = NSApplication.shared
        let script = """
            {"t":"textDelta","v":"The harbour is old and the harbour walls are older.","delayMs":2}
            """
        let env = ChatEnvironment(database: try AppDatabase.inMemory(),
                                  engine: InProcessScriptedEngine(script: try EngineScript(text: script)),
                                  slot: { .scripted("inline") })
        let state = WindowState(service: ChatListService(environment: env), seed: 1)
        let sessions = ChatSessions(environment: env)
        state.activate()
        state.send("Tell me about the harbour.", reduceMotion: true, turn: sessions.slots.startTurn)
        let model = sessions.model(for: try #require(state.currentChatID))
        for _ in 0..<500 where model.isGenerating { try? await Task.sleep(for: .milliseconds(10)) }
        state.conversation = { [weak sessions, weak state] in state?.currentChatID.flatMap { sessions?.model(for: $0) } }
        let window = NSWindow(contentRect: CGRect(x: 60, y: 60, width: 760, height: 560), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ConversationView(model: model)
            .environment(\.reduceMotionOverride, true).frame(width: 760, height: 560))
        BackgroundRun.present(window)
        return Rig(state: state, sessions: sessions, model: model, window: window)
    }

    private func until(_ rig: Rig, _ cond: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            rig.window.contentView?.layoutSubtreeIfNeeded()
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    private func present(_ rig: Rig, _ id: String) -> Bool { UIProbeRegistry.frame(id, in: rig.window) != nil }

    @Test func findBarHighlightsMatchesAndSteps() async throws {
        let rig = try await make()
        defer { rig.window.orderOut(nil) }
        #expect(!present(rig, "findBar"))
        rig.model.find.present()
        #expect(await until(rig) { present(rig, "findBar") && present(rig, "findField") })
        rig.model.find.query = "harbour"
        #expect(rig.model.find.matches.count == 3)  // 1 in the question, 2 in the reply
        #expect(await until(rig) { UIProbeRegistry.frames("findMatch", in: rig.window).count == 2 && present(rig, "findCurrent") })
        #expect(rig.model.find.label == "1 of 3")
        rig.model.find.next()
        #expect(rig.model.find.currentMatch?.messageID == rig.model.messages.last?.id)
        rig.model.find.dismiss()
        #expect(await until(rig) { !present(rig, "findBar") && !present(rig, "findMatch") })
    }

    @Test func selectAllWithoutTextFocusSelectsOnlyTheTranscript() async throws {
        let rig = try await make()
        defer { rig.window.orderOut(nil) }
        BackgroundRun.present(rig.window)
        rig.window.makeFirstResponder(nil)
        #expect(!EditRouting.textHasFocus)
        #expect(EditRouting.selectAll(rig.state), "⌘A without a focused text view selects the transcript")
        #expect(rig.model.selection.isAll)
        #expect(await until(rig) { UIProbeRegistry.frames("transcriptSelected", in: rig.window).count == 2 })
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("antichat-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(EditRouting.copy(rig.state, to: pasteboard))
        #expect(pasteboard.string(forType: .string)
                == "Tell me about the harbour.\n\nThe harbour is old and the harbour walls are older.")
        // With a text view focused, ⌘A belongs to it.
        let field = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
        rig.window.contentView?.addSubview(field)
        rig.window.makeFirstResponder(field)
        // The window as key (a background run has no key window; the routing reads the key window's responder).
        EditRouting.keyWindow = { [window = rig.window] in window }
        #expect(EditRouting.textHasFocus && !EditRouting.selectAll(rig.state))
        EditRouting.keyWindow = { NSApp.keyWindow }
        field.removeFromSuperview()
        // A new message ends the selection.
        rig.state.send("Another one", reduceMotion: true, turn: rig.sessions.slots.startTurn)
        #expect(await until(rig) { !rig.model.selection.isAll })
    }
}
}  // extension WindowSuites
