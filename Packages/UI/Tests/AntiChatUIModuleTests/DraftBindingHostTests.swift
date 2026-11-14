// AT-302 window legs in process (M1.T21, R-302; XCUITest `DraftTests` is committed but not run here, Q-015): the real
// MainWindow + ChatSessions + LiveComposer in an NSWindow of the test process, on the ScriptedEngine and an in-memory
// database. Switching chats restores each chat's text and paste card (and never writes one chat's text into another),
// a new chat keeps its own draft, the row lands ≤ 1 s after the last change, send clears it, termination flushes the
// pending debounce at once, a second window stack on the same database (relaunch) restores the new-chat draft at
// launch, and an incognito composer writes no `draft` row.
//   make test-unit FILTER=DraftBindingHostTests
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct DraftBindingHostTests {
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

    private func until(_ timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            await pump(10)
        }
        return cond()
    }

    private func make(database: AppDatabase? = nil) async throws -> Rig {
        _ = NSApplication.shared
        BackgroundRun.enable()
        let engine = InProcessScriptedEngine(script: try EngineScript(text: #"{"t":"textDelta","v":"ok.","delayMs":1}"#))
        let env = ChatEnvironment(database: try database ?? AppDatabase.inMemory(), engine: engine, slot: { .scripted("inline") })
        let state = WindowState(service: ChatListService(environment: env), seed: 1)
        let sessions = ChatSessions(environment: env)
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

    private func chat(_ rig: Rig, _ title: String) throws -> String {
        let c = try rig.state.service.create(firstPrompt: title)
        try rig.state.service.appendUserMessage(c.id, text: title)
        return c.id
    }

    private func row(_ rig: Rig, _ key: String) -> DraftRecord? { try? DraftRepository(rig.env.database).draft(chatID: key) }

    /// Types `text` the way the text view does (one change per character). Returns the time of the last change,
    /// taken just before it is made: a save of the full text can only come after it.
    @discardableResult
    private func type(_ text: String, _ rig: Rig) async -> Date {
        var last = Date()
        for ch in text {
            last = Date()
            rig.composer.text.append(ch)
            await pump(15)
        }
        return last
    }

    @Test func switchingChatsRestoresEachDraftAndCard() async throws {
        let rig = try await make()
        defer { rig.window.close() }
        let a = try chat(rig, "chat a"), b = try chat(rig, "chat b")
        rig.state.open(.chat(a))
        await pump(200)
        // The bound is the last change itself. Taking the time after `type` returned also counted its final pump,
        // which a loaded host stretched past the 500 ms debounce: the row was (correctly) saved inside that pump,
        // "before" the stamp.
        let typedA = await type("draft for A", rig)

        rig.state.open(.chat(b))
        #expect(await until { rig.composer.text.isEmpty && rig.state.composerText.isEmpty }, "B starts empty")
        await type("draft for B", rig)
        let card = String(repeating: "paste ", count: 2_000)  // 12,000 characters → a card
        let typedB = Date()  // B's last change: the paste
        #expect(rig.composer.handlePaste(card))
        await pump(100)

        rig.state.open(.chat(a))
        #expect(await until { rig.composer.text == "draft for A" }, "A restored: \(rig.composer.text)")
        #expect(rig.state.composerText == "draft for A")
        #expect(rig.composer.attachments.isEmpty)

        rig.state.open(.chat(b))
        #expect(await until { rig.composer.text == "draft for B" }, "B restored: \(rig.composer.text)")
        #expect(rig.composer.attachments.map(\.pastedText) == [card])

        // On disk after each chat's last change; no text crossed over. Order only: the ≤ 1 s debounce bound is
        // DraftStoreTests' virtual-clock test (on the wall clock a loaded host stretched it).
        #expect(await until(30) { row(rig, a)?.text == "draft for A" && row(rig, b)?.text == "draft for B" })
        let ra = try #require(row(rig, a)), rb = try #require(row(rig, b))
        #expect(ra.updatedAt >= typedA.addingTimeInterval(-0.01), "A saved before its last change")
        #expect(rb.updatedAt >= typedB.addingTimeInterval(-0.01))  // B's row is rewritten when B is shown again
        #expect(DraftStore.decode(rb.attachmentsJSON) == [.pastedText(card)])
        #expect(row(rig, DraftRecord.newChatKey) == nil, "nothing leaked into the new-chat draft")

        // The new chat keeps its own draft across a round trip.
        rig.state.newChat(seed: 2)
        #expect(await until { rig.composer.text.isEmpty })
        await type("brand new", rig)
        rig.state.open(.chat(a))
        #expect(await until { rig.composer.text == "draft for A" })
        rig.state.newChat(seed: 3)
        #expect(await until { rig.composer.text == "brand new" }, "new-chat draft: \(rig.composer.text)")
        #expect(await until(3) { row(rig, DraftRecord.newChatKey)?.text == "brand new" })
        #expect(row(rig, a)?.text == "draft for A")
    }

    @Test func sendClearsTheDraft() async throws {
        let rig = try await make()
        defer { rig.window.close() }
        let a = try chat(rig, "chat a")
        rig.state.open(.chat(a))
        await pump(200)
        await type("send me", rig)
        #expect(await until(3) { row(rig, a) != nil })
        #expect(rig.composer.send())
        let m = rig.sessions.model(for: a)
        #expect(await until { !m.isGenerating && m.messages.last?.status == .done })
        await pump(800)
        #expect(row(rig, a) == nil, "draft row after send")
        rig.state.newChat(seed: 2)
        await pump(100)
        rig.state.open(.chat(a))
        await pump(200)
        #expect(rig.composer.text.isEmpty)

        // The new chat's first send: its `new` draft goes, and the created chat has none.
        rig.state.newChat(seed: 3)
        await pump(100)
        await type("first message", rig)
        #expect(await until(3) { row(rig, DraftRecord.newChatKey) != nil })
        #expect(rig.composer.send())
        #expect(await until { rig.state.currentChatID != nil && rig.state.currentChatID != a })
        let created = try #require(rig.state.currentChatID)
        await pump(800)
        #expect(row(rig, DraftRecord.newChatKey) == nil)
        #expect(row(rig, created) == nil)
    }

    @Test func terminationFlushesAndRelaunchRestores() async throws {
        let db = try AppDatabase.inMemory()
        let first = try await make(database: db)
        await type("typed just before quit", first)
        // ⌘Q right away: the debounce has not fired; applicationWillTerminate flushes it synchronously.
        #expect(row(first, DraftRecord.newChatKey) == nil)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        #expect(row(first, DraftRecord.newChatKey)?.text == "typed just before quit")
        first.window.close()

        // Relaunch: a new window stack on the same database opens on the new chat with the draft restored.
        let second = try await make(database: db)
        defer { second.window.close() }
        #expect(await until { second.composer.text == "typed just before quit" }, "restored: \(second.composer.text)")
        #expect(second.state.composerText == "typed just before quit")
    }

    @Test func incognitoComposerWritesNoDraftRow() async throws {
        let rig = try await make()
        defer { rig.window.close() }
        rig.composer.isIncognito = true
        await type("incognito phrase 4417", rig)
        await pump(1200)
        rig.sessions.drafts.flush()
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        let count = try rig.env.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM draft") }
        #expect(count == 0)
        #expect(rig.sessions.drafts.store.memoryKeys == [.newChat])
    }
}
}  // extension WindowSuites
