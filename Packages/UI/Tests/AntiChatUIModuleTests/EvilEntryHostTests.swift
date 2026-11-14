// R-210 AC1 / journey J07, in-process form: the real MainWindow + ChatSessions in an NSWindow, Evil Mode on (a real
// consent, and the Debug `-FakeEvilEnabled` force), wired like the app's MainWindowHost. ⇧⌘E / File › New Evil Chat
// (`WindowState.newEvilChat`) and the composer's switch (`composer.mode`, as the ModeSwitch binding sets it) must
// leave the new chat Evil: frame, badge, Evil empty state. M9.T05 PR1 J07 found it flipping back to Normal: showing
// the Evil empty state moves the composer into another branch, the re-mounted composer re-ran `showMode(for: nil)`
// with the (already consumed) request gone and reset the new chat to the "last used" mode — Normal for a user whose
// last chat was Normal (⇧⌘E never records it), and always Normal under `-FakeEvilEnabled` (no consent row).
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import AppKit
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct EvilEntryHostTests {
    struct Rig {
        let state: WindowState
        let sessions: ChatSessions
        let evil: EvilModeModel
        let window: NSWindow
    }

    enum Setup { case consented, forced }

    private func make(_ setup: Setup) async throws -> Rig {
        _ = NSApplication.shared
        BackgroundRun.enable()
        let db = try AppDatabase.inMemory()
        let d = UserDefaults.inMemory()
        let manager = EvilModeManager(database: db, termsVersion: "v", defaults: d, flagDefaults: d)
        if setup == .consented { try manager.enable(adultSelfDeclared: true) }
        manager.recordLastMode(.normal)  // the user's last chat was a Normal one
        let evil = EvilModeModel(manager: manager, forceOn: setup == .forced)
        #expect(evil.showsSwitch)
        let script = #"{"t":"textDelta","v":"Hello there.","delayMs":20}"#
        let env = ChatEnvironment(database: db, engine: InProcessScriptedEngine(script: try EngineScript(text: script)),
                                  slot: { .scripted("inline") })
        let state = WindowState(service: ChatListService(environment: env), seed: 1)
        let sessions = ChatSessions(environment: env, evil: evil)
        // As AntiChatApp's MainWindowHost wires it.
        sessions.onModeShown = { [weak state] m in
            state?.shownMode = m
            state?.newChatMode = nil
        }
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1180, height: 820),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainWindow(state: state, slots: sessions.slots)
            .environment(\.reduceMotionOverride, true))
        BackgroundRun.present(window)
        await pump(400)
        return Rig(state: state, sessions: sessions, evil: evil, window: window)
    }

    private static func spinRunLoop(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func pump(_ ms: Int) async {
        let end = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < end {
            Self.spinRunLoop(0.005)
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func present(_ rig: Rig, _ id: String) -> Bool {
        rig.window.contentView?.layoutSubtreeIfNeeded()
        return UIProbeRegistry.frame(id, in: rig.window) != nil
    }

    /// The new chat is Evil and stays Evil (checked again after the re-mounts settle).
    private func expectEvil(_ rig: Rig, _ how: String) async {
        await pump(600)
        #expect(rig.state.shownMode == .evil, "\(how): window mode")
        #expect(rig.sessions.composer.mode == .evil, "\(how): composer mode")
        #expect(present(rig, "evilHeadline"), "\(how): Evil empty state")
        #expect(present(rig, "evil.frame"), "\(how): Evil frame")
        await pump(400)
        #expect(rig.state.shownMode == .evil && rig.sessions.composer.mode == .evil, "\(how): still Evil")
    }

    @Test(arguments: [Setup.consented, .forced])
    func shortcutAtLaunch(_ setup: Setup) async throws {
        let rig = try await make(setup)
        defer { rig.window.orderOut(nil) }
        #expect(rig.state.shownMode == .normal)
        rig.state.newEvilChat()  // ⇧⌘E and File › New Evil Chat
        await expectEvil(rig, "⇧⌘E (\(setup))")
    }

    @Test(arguments: [Setup.consented, .forced])
    func composerSwitchAtLaunch(_ setup: Setup) async throws {
        let rig = try await make(setup)
        defer { rig.window.orderOut(nil) }
        rig.sessions.composer.mode = .evil  // the ModeSwitch's binding
        await expectEvil(rig, "switch (\(setup))")
    }

    @Test(arguments: [Setup.consented, .forced])
    func shortcutAfterANormalTurn(_ setup: Setup) async throws {
        let rig = try await make(setup)
        defer { rig.window.orderOut(nil) }
        rig.state.send("Hello", reduceMotion: true, turn: rig.sessions.slots.startTurn)
        let id = try #require(rig.state.currentChatID)
        let model = rig.sessions.model(for: id)
        let end = Date().addingTimeInterval(10)
        while model.isGenerating, Date() < end { await pump(20) }
        rig.state.newEvilChat()
        await expectEvil(rig, "⇧⌘E after a turn (\(setup))")
        // ⌘N afterwards: a new chat in the last used mode — Evil now (it was used), as before.
        rig.state.newChat()
        await pump(400)
        #expect(rig.sessions.composer.mode == rig.evil.defaultModeForNewChat)
    }
}
}
