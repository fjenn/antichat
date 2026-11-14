// AT-090 (M1.T20, R-090; journey J08 Incognito). Run wrapped in the disk diff:
//   python3 -I tools/ci/disk-diff.py run --grep-fixture fixtures/prompts/copy-check/incognito-phrases.txt -- \
//     xcodebuild test … -only-testing:AntiChatUITests/J08IncognitoTests
// Blocked by Q-015 like the other XCUITests; the in-process probe (`-IncognitoProbe`, App/AntiChat/IncognitoProbe.swift,
// tools/at/t20-probe.sh) runs the same legs meanwhile (build/at/AT-090/).
import XCTest

final class J08IncognitoTests: XCTestCase {
    static var phrases: [String] {
        let f = TurnApp.repoRoot.appendingPathComponent("fixtures/prompts/copy-check/incognito-phrases.txt")
        let staged = TurnApp.repoRoot.appendingPathComponent("tools/fixtures/staged/prompts/copy-check/incognito-phrases.txt")
        let text = (try? String(contentsOf: f, encoding: .utf8)) ?? (try? String(contentsOf: staged, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    @MainActor
    private func launch() -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication.antichat(["-UseScriptedEngine", TurnApp.script("regen-slow.jsonl"), "-OfflineOnly", "YES"])
        app.launch()
        let window = app.mainWindow
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        return (app, window)
    }

    private func element(_ window: XCUIElement, _ id: String) -> XCUIElement {
        window.descendants(matching: .any)[id]
    }

    private func assertIncognitoChrome(_ window: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for id in ["incognitoBadge", "incognitoHeadline", "incognitoSub", "incognitoPersonalization"] {
            XCTAssertTrue(element(window, id).waitForExistence(timeout: 2), "\(id) missing", file: file, line: line)
        }
        XCTAssertFalse(element(window, "suggestions").exists, file: file, line: line)
    }

    /// The newest main window whose title says it is incognito (⇧⌘N opens a new window, M1.T24 WindowRestoration).
    @MainActor private func incognitoWindow(_ app: XCUIApplication) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'main-' AND title CONTAINS 'Incognito'")).firstMatch
    }

    /// The reply finished: Send is back (no Stop) and an ActionBar shows.
    @MainActor private func waitIdle(_ window: XCUIElement, timeout: TimeInterval = 20) {
        XCTAssertTrue(window.buttons["voiceOrSend"].waitForExistence(timeout: timeout), "reply did not finish")
        XCTAssertTrue(element(window, "actionBar").waitForExistence(timeout: 5))
    }

    /// (1) ⇧⌘N opens a new incognito window; the toolbar button turns the current window's new chat incognito and
    /// back: frame, "Incognito" badge, personalization choice, no suggestions.
    @MainActor
    func testEntryPoints() {
        let (app, window) = launch()
        app.typeKey("n", modifierFlags: [.command, .shift])
        let inc = incognitoWindow(app)
        XCTAssertTrue(inc.waitForExistence(timeout: 5), "⇧⌘N opened no incognito window")
        assertIncognitoChrome(inc)
        app.typeKey("w", modifierFlags: .command)  // an empty incognito chat closes without asking
        XCTAssertTrue(inc.waitForNonExistence(timeout: 5))
        element(window, "incognitoButton").click()
        assertIncognitoChrome(window)
        element(window, "incognitoButton").click()  // off: back to a new chat
        XCTAssertTrue(element(window, "emptyHeadline").waitForExistence(timeout: 2))
    }

    /// (2)–(4) three turns incl. a 12k paste card and a regenerate; no sidebar row; Unpersonalized; ⌘W asks.
    @MainActor
    func testJourneyLeavesNoTraceAndAsksOnClose() {
        let (app, window) = launch()
        let rows = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chatRow.'"))
        let rowsBefore = rows.count
        element(window, "incognitoButton").click()
        assertIncognitoChrome(window)
        element(window, "incognitoPersonalization").radioButtons.element(boundBy: 1).click()  // Unpersonalized
        let p = Self.phrases
        XCTAssertGreaterThanOrEqual(p.count, 5)
        let field = window.descendants(matching: .any).matching(identifier: "composerText").firstMatch
        field.click()
        app.typeText(p[0])
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(p[1] + " " + String(repeating: "lorem ipsum ", count: 1_000), forType: .string)
        app.typeKey("v", modifierFlags: .command)
        app.typeKey(.return, modifierFlags: [])
        waitIdle(window)
        field.click()
        app.typeText(p[2] + "\r")
        XCTAssertTrue(window.buttons["stop"].waitForExistence(timeout: 5))
        waitIdle(window)
        let regen = window.buttons.matching(identifier: "action.regenerate")
        regen.element(boundBy: max(0, regen.count - 1)).click()
        window.buttons["regenerate.tryAgain"].firstMatch.clickReliably()
        XCTAssertTrue(window.buttons["stop"].waitForExistence(timeout: 5))
        waitIdle(window)
        field.click()
        app.typeText(p[3] + "\r")
        XCTAssertTrue(window.buttons["stop"].waitForExistence(timeout: 5))
        waitIdle(window)
        XCTAssertEqual(rows.count, rowsBefore, "an incognito chat reached the sidebar")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 2) || app.dialogs.firstMatch.waitForExistence(timeout: 2))
        app.buttons["Close chat"].firstMatch.click()
        XCTAssertFalse(window.waitForExistence(timeout: 2) && element(window, "incognitoBadge").exists)
    }
}
