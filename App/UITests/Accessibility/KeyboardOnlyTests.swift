// AT-223 part 1 keyboard half / AT-NFR-A3 (M9.T01 step 4): every entry of tools/a11y/keyboard-paths.yml runs with
// typeKey/typeText only (no click) and reaches its expected element; onboarding completes keyboard-only; ⌘K rebinds.
// Needs Full Keyboard Access on the test user: `defaults write -g AppleKeyboardUIMode -int 2` (restore after).
import XCTest

final class KeyboardOnlyTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    struct Path { var id: String; var keys: [String]; var expect: String }

    /// Minimal reader for keyboard-paths.yml (`- id:` / `keys:` / `expect:` lines).
    static func paths() throws -> [Path] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "tools/a11y/keyboard-paths.yml")
        var out: [Path] = []
        var cur: Path?
        for raw in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("- id:") { if let c = cur { out.append(c) }; cur = Path(id: String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces), keys: [], expect: "") }
            else if line.hasPrefix("keys:") {
                // Q-015 r5: keys are separated by ", ". Splitting on "," and trimming every "[" / "]" broke `⌘,`
                // (Settings: "⌘" + an empty key, NSInvalidArgumentException) and `⌘[` (Back: plain "⌘").
                var inner = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if inner.hasPrefix("[") { inner.removeFirst() }
                if inner.hasSuffix("]") { inner.removeLast() }
                cur?.keys = inner.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            else if line.hasPrefix("expect:") { cur?.expect = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        }
        if let c = cur { out.append(c) }
        return out
    }

    /// "⌘K" → typeKey("k", .command); "Tab", "Esc", "Return", "Space", arrows.
    static func press(_ k: String, _ app: XCUIApplication) {
        if k.hasPrefix("type:") { app.typeText(String(k.dropFirst(5))); return }
        if k == "VO-Space" { app.typeKey(.space, modifierFlags: []); return }  // Full Keyboard Access activate
        var flags: XCUIElement.KeyModifierFlags = []
        var key = k
        for (sym, f) in [("⌘", XCUIElement.KeyModifierFlags.command), ("⇧", .shift), ("⌥", .option), ("⌃", .control)] where key.contains(sym) {
            flags.insert(f); key = key.replacingOccurrences(of: sym, with: "")
        }
        let named: [String: XCUIKeyboardKey] = ["Tab": .tab, "Esc": .escape, "Return": .return, "Space": .space,
                                                "Up": .upArrow, "Down": .downArrow, "Left": .leftArrow, "Right": .rightArrow,
                                                "Delete": .delete]
        if let n = named[key] { app.typeKey(n, modifierFlags: flags) } else { app.typeKey(key.lowercased(), modifierFlags: flags) }
    }

    @MainActor
    func testEveryKeyboardPath() throws {
        let paths = try Self.paths()
        XCTAssertGreaterThanOrEqual(paths.count, 100)
        var results: [String: Bool] = [:]
        for p in paths where !p.expect.isEmpty && !p.keys.contains("manual") {
            let app = A11y.launch()
            for k in p.keys { Self.press(k, app) }
            results[p.id] = A11y.element(app, p.expect).waitForExistence(timeout: 5)
            XCTAssertTrue(results[p.id] ?? false, p.id)
            app.terminate()
        }
        A11y.write(results, "build/at/AT-223/keyboard-paths.json")
    }

    @MainActor
    func testOnboardingKeyboardOnly() throws {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-ResetOnboarding", "YES", "-OfflineOnly", "YES"])
        app.launch()
        for _ in 0..<4 { app.typeKey(.return, modifierFlags: []) }
        XCTAssertTrue(A11y.element(app, "onboarding.step4").waitForExistence(timeout: 10)
                      || A11y.element(app, "composer").waitForExistence(timeout: 10))
    }

    @MainActor
    func testShortcutRebind() throws {
        let app = A11y.launch()
        app.typeKey(",", modifierFlags: .command)
        // Q-015 r5: Settings opens on General; the recorders are in Shortcuts. Get there by keyboard, as the
        // `settings.shortcutRebind` path does (⌘F, "shortcuts", Return).
        app.typeKey("f", modifierFlags: .command)
        app.typeText("shortcuts")
        app.typeKey(.return, modifierFlags: [])
        let recorder = A11y.element(app, "settings.shortcut.palette")  // r5: the recorder's id (ShortcutsSection)
        XCTAssertTrue(recorder.waitForExistence(timeout: 5))
        recorder.typeKey(.space, modifierFlags: [])
        app.typeKey("k", modifierFlags: [.command, .option])
        XCTAssertTrue((recorder.value as? String ?? recorder.displayText).contains("⌥⌘K"))
    }
}
