// AT-012 in-process ⌘K probe (M1.T11). XCUITest cannot start on this Mac (Q-015), so — like WindowProbe (AT-001) —
// the app drives itself: real key events through `NSApp.sendEvent` (⌘K menu key equivalent, typing into the
// palette field, ↓, Return, Tab, Esc; the vendored view's key monitor sees them as it would a keyboard), real clicks
// on the tab chips, element presence from the `probeID` anchors, and window captures. Run on the 10,000-chat
// fixture container (`-ANTICHAT_DEV_CONTAINER`, tools/at/at-012-probe.sh). J09PaletteTests asserts the same legs
// once automation mode is enabled. DEBUG only (`-PaletteProbe <dir>`, M1.md convention 10).
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatDesign
import AntiChatHarness
import AntiChatUI
import AppKit
import SwiftUI

@MainActor
enum PaletteProbe {
    private static var started = false

    static func start(_ state: WindowState, out: String) {
        guard !started else { return }
        started = true
        FileHandle.standardError.write(Data("PaletteProbe: start → \(out)\n".utf8))
        Task { @MainActor in
            await run(state, dir: URL(fileURLWithPath: out, isDirectory: true))
            NSApp.terminate(nil)
        }
    }

    // MARK: Events

    static var window: NSWindow!

    /// One key press (down + up) sent through the application, like the keyboard would.
    static func key(_ chars: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            else { continue }
            NSApp.sendEvent(e)
        }
    }

    static func type(_ text: String) async {
        for ch in text {
            key(String(ch), code: ch == " " ? 49 : 0)
            await settle(8)
        }
    }

    static func clear(_ count: Int) async {
        for _ in 0..<count {
            key("\u{7f}", code: 51)
            await settle(5)
        }
    }

    static func down() { key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125, flags: [.numericPad, .function]) }
    static func returnKey() { key("\r", code: 36) }
    static func tab() { key("\t", code: 48) }
    static func escape() { key("\u{1b}", code: 53) }
    static func commandK() { key("k", code: 40, flags: .command) }

    static func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    static func waitUntil(timeout: Double = 3, _ cond: () -> Bool) async -> Double? {
        let start = ContinuousClock.now
        while true {
            if cond() { return seconds(ContinuousClock.now - start) }
            if seconds(ContinuousClock.now - start) > timeout { return nil }
            await settle(5)
        }
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    static func present(_ id: String) -> Bool { UIProbeRegistry.frame(id, in: window) != nil }

    @discardableResult
    static func click(_ id: String) -> Bool {
        guard let f = UIProbeRegistry.frame(id, in: window) else { return false }
        let p = CGPoint(x: f.midX, y: f.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1) else { return false }
            window.sendEvent(e)
        }
        return true
    }

    static func capture(_ name: String, _ dir: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", dir.appendingPathComponent(name).path]
        if (try? p.run()) != nil { p.waitUntilExit() }
    }

    /// Opens the palette with ⌘K (menu key equivalent); returns how it opened.
    static func open(_ palette: PaletteController) async -> String {
        if palette.isPresented { return "already" }
        commandK()
        if await waitUntil(timeout: 1.5, { palette.isPresented && present("palette.field") }) != nil {
            await settle(250)
            return "commandK"
        }
        palette.present()
        _ = await waitUntil { present("palette.field") }
        await settle(250)
        return "fallback-present"
    }

    /// Types `q` into a freshly opened palette and waits for its chat results; returns the end-to-end seconds from
    /// the last keystroke to the results being applied.
    static func search(_ q: String, _ palette: PaletteController) async -> Double? {
        let g = palette.resultGeneration
        await type(q)
        let t0 = ContinuousClock.now
        let ok = await waitUntil(timeout: 3) { palette.query == q && palette.resultGeneration > g }
        return ok == nil ? nil : seconds(ContinuousClock.now - t0)
    }

    // MARK: Run

    static func run(_ state: WindowState, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var legs: [String: [String: Any]] = [:]
        await settle(1500)
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "AntiChat" }),
              let palette = PaletteController.lastAttached else {
            write(["error": "no AntiChat window or palette"], dir: dir)
            return
        }
        window = w
        BackgroundRun.activate()
        BackgroundRun.makeKeyAndOrderFront(window)
        window.setFrame(CGRect(x: 80, y: 80, width: 1180, height: 820), display: true)
        await settle(500)

        let chatCount = (try? state.service.sidebarCount()) ?? -1
        let tokenChat = (try? state.service.search("zebracorn"))?.first?.chatID
        legs["0-fixture"] = ["pass": chatCount >= 10_000 && tokenChat != nil, "nonArchivedChats": chatCount,
                             "zebracornChat": tokenChat ?? ""]

        // Leg 1: ⌘K opens the chat search: one field, no tabs and no footer; the empty field lists New chat and
        // the recent chats.
        do {
            let how = await open(palette)
            let noTabs = !present("palette.tab.all") && !present("palette.footer")
            let recents = palette.items.filter { if case .chat = $0.kind { true } else { false } }.count
            capture("S-18-empty-light.png", dir)
            let pass = how == "commandK" && noTabs && recents > 0 && palette.items.first?.kind == .newChat
            legs["1-open-recents"] = ["pass": pass, "openedBy": how, "noTabsNoFooter": noTabs, "recentChatsShown": recents]
        }

        // Leg 2: a body-only token finds its chat; a title word finds title matches.
        do {
            let t = await search("zebracorn", palette)
            await settle(150)
            let found = palette.items.contains { $0.id == "chat.\(tokenChat ?? "-")" && !$0.titleMatched }
            let excerpt = palette.items.first { $0.id.hasPrefix("chat.") }?.excerpt.contains { $0.isMatch } ?? false
            let row = present("palette.row.chat.\(tokenChat ?? "-")")
            capture("S-18-typing-light.png", dir)
            await clear("zebracorn".count)
            let t2 = await search("pasta", palette)
            await settle(100)
            let titleHits = palette.items.filter { $0.id.hasPrefix("chat.") && $0.titleMatched }.count
            await clear("pasta".count)
            let pass = found && excerpt && row && titleHits > 0 && t != nil && t2 != nil
            legs["2-body-and-title"] = ["pass": pass, "bodyTokenFound": found, "highlightedExcerpt": excerpt,
                                        "rowOnScreen": row, "titleMatchesForPasta": titleHits,
                                        "secondsZebracorn": t ?? -1, "secondsPasta": t2 ?? -1]
        }

        // Leg 3 (NFR-U10 through the UI; the authoritative perf leg is `make perf METRIC=U10`, M1.T26): 20 queries,
        // last keystroke → results applied (includes the 30 ms debounce).
        do {
            let queries = ["zebracorn", "pasta", "tax", "garden", "bike", "swift", "consider", "simple steps", "quality",
                           "measure", "example", "detail", "first", "note time", "useful", "check", "result list",
                           "plan", "small start", "repair"]
            var ms: [Double] = []
            var inApp: [Double] = []
            for q in queries {
                if let s = await search(q, palette) { ms.append(s * 1000) }
                inApp.append((palette.lastResultLatency ?? -1) * 1000)
                await clear(q.count)
                await settle(60)
            }
            let sorted = ms.sorted()
            let p95 = sorted.isEmpty ? -1 : sorted[max(0, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
            let pass = ms.count == queries.count && p95 <= 200
            legs["3-latency-20-queries"] = ["pass": pass, "n": ms.count, "p50_ms": sorted.isEmpty ? -1 : sorted[sorted.count / 2],
                                            "p95_ms": p95, "max_ms": sorted.last ?? -1, "samples_ms": ms,
                                            "queryChangeToApplied_ms": inApp,
                                            "note": "end-to-end from the last synthesized keystroke, incl. 30 ms debounce"]
        }

        // Leg 4: no results → `search.empty`; keyboard selection ↓↓ then Return opens the third row's chat.
        do {
            _ = await search("qwxzvbnm", palette)
            await settle(150)
            let empty = palette.items.isEmpty
            capture("S-18-noresults-light.png", dir)
            await clear("qwxzvbnm".count)
            _ = await search("pasta", palette)
            await settle(150)
            down(); await settle(80); down(); await settle(150)
            capture("S-18-selection-light.png", dir)
            let third = palette.items.count > 2 ? palette.items[2] : nil
            returnKey()
            let opened = await waitUntil {
                if case let .chat(id, _) = third?.kind { return state.route == .chat(id) && !palette.isPresented }
                return false
            }
            legs["4-noresults-selection"] = ["pass": empty && opened != nil, "noResultsEmpty": empty,
                                             "noResultsCopy": CopyKey("search.empty").string(["query": "qwxzvbnm"]),
                                             "thirdRow": third?.id ?? "", "returnOpenedIt": opened != nil]
        }

        // Leg 7: Tab asks the query as a new chat (text in the composer, not sent); Esc closes.
        do {
            if let first = state.sidebar.first { state.open(.chat(first.id)) }
            await settle(300)
            let before = state.sidebar.count
            _ = await open(palette)
            _ = await search("hello from the palette", palette)
            tab()
            let asked = await waitUntil {
                !palette.isPresented && state.route == .newChat && state.composerText == "hello from the palette"
            }
            await settle(300)
            capture("S-18-tab-newchat-light.png", dir)
            let notSent = state.sidebar.count == before && state.route == .newChat
            _ = await open(palette)
            escape()
            let escClosed = await waitUntil { !palette.isPresented && !present("palette.field") }
            // A click on the dimmed window outside the card closes it too (window coordinates, origin bottom-left).
            _ = await open(palette)
            let card = UIProbeRegistry.frame("palette", in: window) ?? .zero
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: CGPoint(x: card.midX, y: card.minY - 40),
                                              modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: 1, pressure: 1) { window.sendEvent(e) }
            }
            let outsideClosed = await waitUntil { !palette.isPresented }
            if palette.isPresented { escape() }
            legs["7-tab-escape"] = ["pass": asked != nil && notSent && escClosed != nil && outsideClosed != nil,
                                    "tabToNewChat": asked != nil, "composerText": state.composerText,
                                    "notSent": notSent, "escapeClosed": escClosed != nil,
                                    "clickOutsideClosed": outsideClosed != nil]
        }

        // Dark captures: empty, typing, no results, keyboard selection.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await settle(400)
        _ = await open(palette)
        capture("S-18-empty-dark.png", dir)
        _ = await search("zebracorn", palette)
        await settle(150)
        capture("S-18-typing-dark.png", dir)
        await clear("zebracorn".count)
        _ = await search("qwxzvbnm", palette)
        await settle(150)
        capture("S-18-noresults-dark.png", dir)
        await clear("qwxzvbnm".count)
        _ = await search("pasta", palette)
        await settle(150)
        down(); await settle(80); down(); await settle(150)
        capture("S-18-selection-dark.png", dir)
        escape()
        await settle(200)
        NSApp.appearance = nil

        let pass = legs.values.allSatisfy { ($0["pass"] as? Bool) == true }
        write(["pass": pass, "legs": legs,
               "notes": ["Key events go through NSApp.sendEvent (menu key equivalents + the vendored view's local key monitor).",
                         "AT-012 leg (2) 'opens Settings at that row' is a forward leg to M1.T22 (convention 9).",
                         "AT-012 leg (1) perf key report.json .metrics.U10.na is a forward leg to M1.T26."]],
              dir: dir)
    }

    static func write(_ obj: [String: Any], dir: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("probe.json"))
        }
    }
}
#endif
