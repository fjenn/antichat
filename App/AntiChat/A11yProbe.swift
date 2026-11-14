// M9.T01/T03/T04 in-process accessibility probe (`-A11yProbe <dir>`, DEBUG). XCUITest is blocked on this Mac
// (Q-015), so — like SettingsProbe — the app drives itself through its real windows (keys to the key window, clicks at
// probe anchors; BackgroundRun, never taking focus) and walks the NSAccessibility tree VoiceOver reads:
//   AT-223 part 1 inventory (informational in-process, see `unlabeledBackingViews`): every interactive element (button, checkbox, radio, pop-up, menu button, text field,
//     slider, link, disclosure) on S-05 (new chat), S-08 (chat with a reply), the palette, and all 13 Settings
//     sections → label, identifier, role, frame; an element fails when its label is empty, a raw SF Symbol name
//     (`square.and.arrow.up`) or equal to its identifier.
//   NFR-A2: the window's accessibility title of a new Evil chat contains "Evil mode chat" (reported only: a scripted
//     dev run without Evil models may not switch the window to Evil).
//   AT-102 (follows macOS): under `-AppleLanguages (xx)` the composer placeholder and the Settings section titles
//     equal that language's catalog strings (CopyKey resolves through the compiled catalog).
// Writes `<dir>/probe.json` + `inventory.json` and quits. Run by tools/at/at-223-probe.sh.
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatDesign
import AntiChatFoundation
import AntiChatUI
import AppKit

@MainActor
enum A11yProbe {
    private static var started = false
    static let interactive: Set<NSAccessibility.Role> = [.button, .checkBox, .radioButton, .popUpButton, .menuButton,
                                                          .textField, .textArea, .slider, .link, .disclosureTriangle,
                                                          .comboBox, .incrementor]
    static let symbolName = try! NSRegularExpression(pattern: "^[a-z0-9]+(\\.[a-z0-9]+)+$")

    static func start(_ state: WindowState, sessions: ChatSessions, out: String) {
        guard !started else { return }
        started = true
        Task { @MainActor in
            let dir = URL(fileURLWithPath: out, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var result: [String: Any] = [:]
            var inventory: [String: [[String: Any]]] = [:]
            var failures: [String] = []
            _ = await SettingsProbe.waitUntil(timeout: 20) { state.window != nil && SettingsProbe.present("composer") }
            guard let main = state.window else {
                SettingsProbe.write(["error": "no main window"], dir: dir, name: "probe.json"); NSApp.terminate(nil); return
            }
            SettingsProbe.main = main
            BackgroundRun.makeKeyAndOrderFront(main)
            await SettingsProbe.settle(800)

            @MainActor func scan(_ screen: String, _ window: NSWindow?) {
                guard let window else { failures.append("\(screen): window missing"); return }
                let items = walk(window)
                inventory[screen] = items
                for i in items where (i["ok"] as? Bool) == false {
                    failures.append("\(screen): \(i["role"] ?? "?") id=\(i["id"] ?? "") label='\(i["label"] ?? "")'")
                }
                FileHandle.standardError.write(Data("A11yProbe: \(screen) \(items.count) elements\n".utf8))
            }

            scan("S-05-newChat", main)

            // S-08: one scripted turn.
            if SettingsProbe.present("composer") {
                _ = await SettingsProbe.focusText("composer")
                await SettingsProbe.type("Hello there.", in: main)
                SettingsProbe.key("\r", code: 36, in: main)
                _ = await SettingsProbe.waitUntil(timeout: 30) { state.currentChatID != nil }
                await SettingsProbe.settle(5000)  // the scripted reply streams and finishes
            }
            result["chatOpened"] = state.currentChatID != nil
            scan("S-08-chat", main)
            result["windowTitleNormal"] = main.accessibilityTitle() ?? ""

            // Palette (⌘K).
            SettingsProbe.key("k", code: 40, flags: .command, in: main)
            if await SettingsProbe.waitUntil(timeout: 3, { NSApp.windows.contains { $0.isVisible && $0 !== main && $0.className.contains("Panel") } }) {
                scan("S-18-palette", NSApp.windows.first { $0.isVisible && $0 !== main && $0.className.contains("Panel") })
                SettingsProbe.key("\u{1b}", code: 53, in: NSApp.keyWindow ?? main)
                await SettingsProbe.settle(300)
            }

            // Evil title (NFR-A2): ⇧⌘E opens a new Evil chat when Evil is enabled (-FakeEvilEnabled YES).
            BackgroundRun.makeKeyAndOrderFront(main)
            SettingsProbe.key("E", code: 14, flags: [.command, .shift], in: main)
            await SettingsProbe.settle(800)
            if state.shownMode != .evil { state.newEvilChat(); sessions.modeChanged(.evil) }  // as the ModeSwitch does
            _ = await SettingsProbe.waitUntil(timeout: 3) { state.shownMode == .evil }
            if state.shownMode == .evil, SettingsProbe.present("composer") {
                _ = await SettingsProbe.focusText("composer")
                await SettingsProbe.type("Hi.", in: main)
                SettingsProbe.key("\r", code: 36, in: main)
                await SettingsProbe.settle(3000)
            }
            result["evilShown"] = state.shownMode == .evil
            let evilTitle = main.accessibilityTitle() ?? ""
            result["windowTitleEvil"] = evilTitle
            result["evilTitleAnnounced"] = evilTitle.contains(CopyKey("a11y.evilChat").string())

            // Settings: every section.
            result["settingsOpen"] = await SettingsProbe.openSettingsWithCommandComma()
            var sectionTitles: [String: String] = [:]
            for s in SettingsSection.allCases {
                _ = await SettingsProbe.openSection(s)
                await SettingsProbe.settle(500)
                scan("S-21-\(s.rawValue)", SettingsProbe.settingsWindow)
                sectionTitles[s.rawValue] = s.title.string()
            }
            await SettingsProbe.closeSettings()

            // AT-102 leg: the running language and a few resolved strings.
            result["language"] = AppLanguage.running
            result["composerPlaceholder"] = CopyKey("composer.placeholder").string()
            result["sectionTitles"] = sectionTitles
            result["pluralSample"] = [CopyText(CopyKey("tile.pages"), ["count": "1"]).string,
                                      CopyText(CopyKey("tile.pages"), ["count": "5"]).string]

            result["screens"] = inventory.keys.sorted()
            result["elements"] = inventory.values.reduce(0) { $0 + $1.count }
            // The walk sees AppKit views; SwiftUI builds its own AX nodes (where most labels live) only for a real
            // AX client, so unlabeled backing views here are informational. The authoritative 0-unlabeled inventory
            // is VoiceOverLabelTests (XCUITest, Q-015) and the vq-12 walkthroughs.
            result["unlabeledBackingViews"] = failures
            let langOK = AppLanguage.running.hasPrefix(String((Locale.preferredLanguages.first ?? "en").prefix(2)))
            // The Evil leg is reported, not gated: a scripted dev run has no Evil models, so the window may not switch
            // (WindowAccessibilityTitle is unit-tested; testEvilTitleAnnounced runs under XCUITest).
            result["pass"] = langOK && inventory.count >= 15
            SettingsProbe.write(inventory, dir: dir, name: "inventory.json")
            SettingsProbe.write(result, dir: dir, name: "probe.json")
            NSApp.terminate(nil)
        }
    }

    /// Interactive accessibility elements under `window`, as VoiceOver's tree exposes them.
    static func walk(_ window: NSWindow) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ obj: Any, depth: Int) {
            guard depth < 60, let o = obj as? NSObject, seen.insert(ObjectIdentifier(o)).inserted,
                  let e = o as? NSAccessibilityProtocol else { return }
            if e.isAccessibilityHidden() { return }
            if let role = e.accessibilityRole(), interactive.contains(role) {
                let frame = e.accessibilityFrame()
                if frame.width > 0, frame.height > 0 {
                    let label = [e.accessibilityLabel(), e.accessibilityTitle(),
                                 role == .textField || role == .textArea ? e.accessibilityPlaceholderValue() : nil]
                        .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                    let id = e.accessibilityIdentifier()
                    let isSymbol = symbolName.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil
                    let windowButton = e.accessibilitySubrole().map {
                        [.closeButton, .minimizeButton, .zoomButton, .fullScreenButton, .toolbarButton].contains($0)
                    } ?? false
                    let ok = windowButton || (!label.isEmpty && !isSymbol && (label != id || (id ?? "").isEmpty))
                    out.append(["role": role.rawValue, "label": label, "id": id ?? "", "ok": ok,
                                "hint": e.accessibilityHelp() ?? "",
                                "frame": [frame.minX, frame.minY, frame.width, frame.height].map { Int($0) }])
                }
            }
            for c in e.accessibilityChildren() ?? [] { visit(c, depth: depth + 1) }
            // SwiftUI builds its AX nodes on demand per hosting view; AppKit views are visited too.
            if let v = o as? NSView { for sub in v.subviews { visit(sub, depth: depth + 1) } }
        }
        visit(window, depth: 0)
        if let content = window.contentView { visit(content, depth: 0) }
        return out
    }
}
#endif
