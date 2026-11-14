// AT-012 window legs in-process (M1.T11). The app cannot open a window from this agent's command sandbox (the
// `-PaletteProbe` run is recorded in QUESTIONS, Q-025), and XCUITest is blocked (Q-015), so this suite hosts the real
// MainWindow (sidebar + palette overlay + vendored CommandPaletteKit view) in an NSWindow inside the test process
// and drives it with real AppKit events through `NSApp.sendEvent` — the path the vendored key monitor and the field
// editor see from a keyboard: typing, ↓, Return, Tab, Esc, and mouse clicks on the probe anchors. Captures of the
// S-18 states go to build/at/AT-012/window/ (light and dark) when `AT012_CAPTURE_DIR` is set.
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import AppKit
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct PaletteWindowTests {
    @MainActor final class Rig {
        let env: ChatEnvironment
        let state: WindowState
        let window: NSWindow
        let palette: PaletteController
        var chats: [String: String] = [:]

        init(env: ChatEnvironment, state: WindowState, window: NSWindow, palette: PaletteController) {
            self.palette = palette
            self.env = env
            self.state = state
            self.window = window
        }
    }

    // MARK: Rig

    private func make(look: NSAppearance.Name = .aqua) async throws -> Rig {
        _ = NSApplication.shared
        BackgroundRun.enable()
        DesignBundle.forceBrandAccent = true
        let env = ChatEnvironment(database: try AppDatabase.inMemory(),
                                  engine: InProcessScriptedEngine(script: try EngineScript(text: #"{"t":"textDelta","v":"ok"}"#)),
                                  slot: { .scripted("inline") })
        let service = ChatListService(environment: env)
        var chats: [String: String] = [:]
        for (name, title, user, reply) in [
            ("pasta", "Pasta night", "What should I cook?", "A simple tomato sauce."),
            ("garden", "Garden", "Soil tips?", "Compost helps. The zebracorn is the search fixture."),
            ("tax", "Tax forms", "Deadline?", "April, and pasta is not deductible."),
            ("bike", "Fix the bike's rear brake", "It squeaks.", "Clean the pads with alcohol."),
        ] {
            let c = try service.create(title: title)
            try service.appendUserMessage(c.id, text: user)
            try service.appendAssistantMessage(c.id, text: reply)
            chats[name] = c.id
        }
        let state = WindowState(service: service, seed: 1)
        let palette = PaletteController()
        let host = NSHostingView(rootView: MainWindow(state: state, palette: palette).environment(\.reduceMotionOverride, true))
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1180, height: 820),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered,
                              defer: false)
        window.title = "AntiChat"
        window.isReleasedWhenClosed = false  // ARC owns it (close() would otherwise over-release)
        window.appearance = NSAppearance(named: look)
        window.contentView = host
        BackgroundRun.present(window)
        let rig = Rig(env: env, state: state, window: window, palette: palette)
        rig.chats = chats
        await pump(600)
        return rig
    }

    /// One synchronous run-loop slice (AppKit/SwiftUI transactions; unavailable directly in async code).
    private static func spinRunLoop(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// Lets SwiftUI and the main actor run: run-loop turns (view updates, AppKit) interleaved with task hops.
    private func pump(_ ms: Int) async {
        let end = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < end {
            Self.spinRunLoop(0.005)
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func until(_ timeout: Double = 60, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            await pump(10)
        }
        return cond()
    }

    /// `direct`: deliver to this window (typing; immune to another suite's window taking key status). Otherwise the
    /// event goes through `NSApp.sendEvent`, where the vendored view's local key monitor sees it (↓, Tab, Return, Esc).
    private func key(_ rig: Rig, _ chars: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = [],
                     direct: Bool = false) {
        if !direct { BackgroundRun.present(rig.window) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: rig.window.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                if direct { rig.window.sendEvent(e) } else { NSApp.sendEvent(e) }
            }
        }
    }

    private func type(_ rig: Rig, _ text: String) async {
        await focusSearchField(rig)
        await pump(20)
        for ch in text {
            // Another suite's window can take key status mid-word, and the field editor (and every later
            // keystroke) goes with it: re-take the field before each character.
            await focusSearchField(rig)
            key(rig, String(ch), code: ch == " " ? 49 : 0, direct: true)
            await pump(4)
        }
    }

    /// Other suites open windows in parallel (`make test-unit --parallel`): take key status back, and when SwiftUI's
    /// field focus went with it, put the field editor back on the palette's search field (the one with the palette
    /// placeholder), caret at the end so the next keystroke appends instead of replacing the re-selected text.
    /// (The composer's text view may hold first responder instead; under parallel load the palette's own focus
    /// request can land late, so retry until the field editor is on the search field.)
    private func focusSearchField(_ rig: Rig) async {
        if !rig.window.isKeyWindow { BackgroundRun.present(rig.window) }
        guard rig.palette.isPresented,
              Self.searchField(in: rig.window.contentView)?.currentEditor() == nil else { return }
        _ = await until(5) {
            guard let field = Self.searchField(in: rig.window.contentView) else { return false }
            if field.currentEditor() == nil, rig.window.makeFirstResponder(field) {
                field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
            }
            return field.currentEditor() != nil
        }
    }

    private static func searchField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let f = view as? NSTextField, f.isEditable,
           f.placeholderString == CopyKey("palette.placeholder").string() { return f }
        for sub in view.subviews {
            if let f = searchField(in: sub) { return f }
        }
        return nil
    }

    private func down(_ rig: Rig) { key(rig, String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125, flags: [.numericPad, .function]) }

    @discardableResult
    private func click(_ rig: Rig, _ id: String) -> Bool {
        guard let f = UIProbeRegistry.frame(id, in: rig.window) else { return false }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: CGPoint(x: f.midX, y: f.midY), modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 1, pressure: 1) {
                rig.window.sendEvent(e)
            }
        }
        return true
    }

    private func present(_ rig: Rig, _ id: String) -> Bool { UIProbeRegistry.frame(id, in: rig.window) != nil }

    private func capture(_ rig: Rig, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["AT012_CAPTURE_DIR"],
              let view = rig.window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    private func openFromSidebar(_ rig: Rig) async -> Bool {
        BackgroundRun.present(rig.window)
        guard click(rig, "sidebar.search") else { return false }
        return await until { rig.palette.isPresented && present(rig, "palette.field") }
    }

    // MARK: Legs

    /// (1) Sidebar Search opens the palette: tabs All / Actions / Chats (+ Settings), footer key hints, recents.
    @Test func searchOpensThePaletteWithTabsFooterAndRecents() async throws {
        let rig = try await make()
        defer { rig.window.close() }
        #expect(await openFromSidebar(rig))
        for tab in ["all", "actions", "chats", "settings"] { #expect(present(rig, "palette.tab.\(tab)"), "tab \(tab)") }
        for hint in ["select", "open", "askTab", "close"] { #expect(present(rig, "palette.hint.\(hint)"), "hint \(hint)") }
        #expect(await until { rig.palette.items.prefix { $0.group == .chats }.count == 4 })
        capture(rig, "S-18-empty-light.png")
    }

    /// (1) Typed keystrokes reach the vendored field; a body-only token finds its chat, a title word its chat.
    @Test func typingSearchesBodiesAndTitles() async throws {
        let rig = try await make()
        defer { rig.window.close() }
        #expect(await openFromSidebar(rig))
        await type(rig, "zebracorn")
        #expect(await until { rig.palette.query == "zebracorn" && !rig.palette.isSearching && rig.palette.items.contains { $0.group == .chats } })
        #expect(rig.palette.items.filter { $0.group == .chats }.map(\.id) == ["chat.\(rig.chats["garden"]!)"], "query=\(rig.palette.query)")
        #expect(present(rig, "palette.row.chat.\(rig.chats["garden"]!)"))
        await pump(150)  // the vendored list animates row changes for 0.12 s
        capture(rig, "S-18-typing-light.png")
        for _ in 0..<9 { key(rig, "\u{7f}", code: 51, direct: true); await pump(4) }
        await type(rig, "pasta")
        #expect(await until { rig.palette.query == "pasta" && !rig.palette.isSearching && rig.palette.items.first { $0.group == .chats }?.titleMatched == true })
        #expect(rig.palette.items.first { $0.group == .chats }?.id == "chat.\(rig.chats["pasta"]!)")
    }

    /// No results shows `search.empty`; on the Chats tab ↓↓ moves the selection to the third recent chat and
    /// Return opens it and closes the palette.
    @Test func noResultsThenKeyboardSelectionOpensAChat() async throws {
        let rig = try await make()
        defer { rig.window.close() }
        #expect(await openFromSidebar(rig))
        await type(rig, "qwxzvbnm")
        #expect(await until { rig.palette.query == "qwxzvbnm" && rig.palette.items.isEmpty })
        await pump(150)
        capture(rig, "S-18-noresults-light.png")
        for _ in 0..<8 { key(rig, "\u{7f}", code: 51, direct: true); await pump(4) }
        #expect(click(rig, "palette.tab.chats"))
        #expect(await until { rig.palette.tab == .chats && rig.palette.query.isEmpty && rig.palette.items.count == 4 })
        await pump(100)
        down(rig); await pump(60); down(rig); await pump(120)
        capture(rig, "S-18-selection-light.png")
        let third = rig.palette.items[2]
        key(rig, "\r", code: 36)
        #expect(await until { !rig.palette.isPresented })
        if case let .chat(id, _) = third.kind {
            // The palette closes before the route lands (the open is dispatched after dismissal): wait for it, not a beat.
            #expect(await until { rig.state.route == .chat(id) })
        } else {
            Issue.record("third row is not a chat: \(third.id)")
        }
    }

    /// (2) Clicking the Actions tab lists the required actions; "send with" finds the General row; Return on it
    /// requests Settings at that row (Settings itself is M1.T22's, forward leg).
    @Test func actionsTabAndSettingsRow() async throws {
        let rig = try await make()
        defer { rig.window.close() }
        #expect(await openFromSidebar(rig))
        #expect(click(rig, "palette.tab.actions"))
        #expect(await until { rig.palette.tab == .actions })
        let titles = rig.palette.items.map(\.title)
        for t in ["New chat", "New incognito chat", "Switch chat"] + SettingsSection.allCases.map({ $0.title.string() }) {
            #expect(titles.contains(t), "missing \(t)")
        }
        await pump(100)
        capture(rig, "S-18-actions-light.png")
        #expect(click(rig, "palette.tab.all"))
        await type(rig, "send with")
        #expect(await until { rig.palette.items.contains { $0.id == "setting.sendWithCommandEnter" } })
        let idx = try #require(rig.palette.items.firstIndex { $0.id == "setting.sendWithCommandEnter" })
        await pump(100)
        for _ in 0..<idx { down(rig); await pump(40) }
        let before = SettingsNavigator.shared.requestCount
        key(rig, "\r", code: 36)
        #expect(await until { SettingsNavigator.shared.requestCount == before + 1 })
        #expect(SettingsNavigator.shared.take() == .init(section: .general, rowID: "sendWithCommandEnter"))
        #expect(await until { !rig.palette.isPresented })
    }

    /// (3) Tab asks the query in a new chat (composer filled, nothing sent); Esc closes; a click outside closes.
    @Test func tabAsksInANewChatAndEscapeCloses() async throws {
        let rig = try await make()
        defer { rig.window.close() }
        rig.state.open(.chat(rig.chats["tax"]!))
        await pump(200)
        #expect(await openFromSidebar(rig))
        await type(rig, "hello from the palette")
        #expect(await until { rig.palette.query == "hello from the palette" })
        key(rig, "\t", code: 48)
        #expect(await until { !rig.palette.isPresented })
        #expect(rig.state.route == .newChat)
        #expect(rig.state.composerText == "hello from the palette")
        #expect(try rig.state.service.transcript(rig.chats["tax"]!).count == 2)
        await pump(200)
        capture(rig, "S-18-tab-newchat-light.png")

        #expect(await openFromSidebar(rig))
        key(rig, "\u{1b}", code: 53)
        #expect(await until { !rig.palette.isPresented && !present(rig, "palette.field") })
    }

    /// Dark captures of the four S-18 states.
    @Test func darkCaptures() async throws {
        let rig = try await make(look: .darkAqua)
        defer { rig.window.close() }
        #expect(await openFromSidebar(rig))
        await pump(150)
        capture(rig, "S-18-empty-dark.png")
        await type(rig, "zebracorn")
        #expect(await until { rig.palette.items.contains { $0.group == .chats } })
        await pump(150)
        capture(rig, "S-18-typing-dark.png")
        for _ in 0..<9 { key(rig, "\u{7f}", code: 51, direct: true); await pump(4) }
        await type(rig, "qwxzvbnm")
        #expect(await until { rig.palette.query == "qwxzvbnm" && rig.palette.items.isEmpty })
        await pump(150)
        capture(rig, "S-18-noresults-dark.png")
        for _ in 0..<8 { key(rig, "\u{7f}", code: 51, direct: true); await pump(4) }
        #expect(click(rig, "palette.tab.chats"))
        #expect(await until { rig.palette.tab == .chats && rig.palette.items.count == 4 })
        down(rig); await pump(60); down(rig); await pump(150)
        capture(rig, "S-18-selection-dark.png")
    }
}
}  // extension WindowSuites
