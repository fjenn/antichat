// AT-001 (R-001, M1.T07): window layout, toolbar, empty state, suggestions, docking, disclaimer, transcript scroll.
// Blocked on this Mac by Q-015 (automation mode); the in-process probe (tools/at/at-001-probe.sh) checks the same
// legs with the same identifiers until automation mode is enabled.
import XCTest

final class WindowLayoutTests: XCTestCase {
    private let headlines: Set<String> = [
        "What's on your mind?", "What can I help with?", "Where should we begin?", "Ready when you are.",
        "What are you working on?",
    ]
    private let chatSuggestions: Set<String> = [
        "Explain something simply", "Help me write an email", "Brainstorm ideas", "Plan my week",
    ]

    @MainActor
    private func launch(_ extra: [String] = []) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-OfflineOnly", "YES",
                                            "-UseScriptedEngine", TurnApp.script("basic.jsonl")] + extra)
        app.launch()
        let window = app.mainWindow
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        return (app, window)
    }

    /// Leg 1: sidebar 260 ± 1 pt, collapsible; no icon rail or product switcher.
    @MainActor
    func testSidebarWidthAndCollapse() {
        let (app, window) = launch()
        let sidebar = window.descendants(matching: .any).matching(identifier: "sidebar").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        // The sidebar List (AXOutline) reports a 1 pt outset on every side of its 260 pt column (Q-015 r4 AX dump).
        XCTAssertEqual(sidebar.frame.width - 2, 260, accuracy: 1)
        XCTAssertFalse(app.descendants(matching: .any)["iconRail"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["productSwitcher"].exists)
        window.buttons["sidebarToggle"].click()
        XCTAssertTrue(waitFor { !sidebar.exists || sidebar.frame.width < 1 })
        window.buttons["sidebarToggle"].click()
        XCTAssertTrue(waitFor { sidebar.exists && abs(sidebar.frame.width - 2 - 260) <= 1 })
    }

    /// Leg 2: traffic lights, sidebarToggle, navBack, navForward, centred toolbarTitle, chatMoreMenu.
    @MainActor
    func testToolbar() {
        let (_, window) = launch()
        for id in [XCUIIdentifierCloseWindow, XCUIIdentifierMinimizeWindow, XCUIIdentifierFullScreenWindow] {
            XCTAssertTrue(window.buttons[id].exists, id)
        }
        for id in ["sidebarToggle", "navBack", "navForward", "toolbarTitle", "chatMoreMenu"] {
            XCTAssertTrue(window.descendants(matching: .any)[id].exists, id)
        }
        let title = window.descendants(matching: .any)["toolbarTitle"]
        XCTAssertTrue(waitFor { abs(title.frame.midX - window.frame.midX) <= 2 })
    }

    /// Leg 3: headline ∈ empty.headline.1…5 (≥ 5 distinct over 30 new chats), composer centred ±10 %, docks ≤ 300 ms.
    @MainActor
    func testEmptyStateHeadlineAndDocking() {
        let (app, window) = launch()
        var seen = Set<String>()
        for _ in 0..<30 {
            app.typeKey("n", modifierFlags: .command)
            let h = window.staticTexts["emptyHeadline"]
            XCTAssertTrue(h.waitForExistence(timeout: 2))
            seen.insert(h.displayText)
        }
        XCTAssertTrue(seen.isSubset(of: headlines), "\(seen)")
        XCTAssertGreaterThanOrEqual(seen.count, 5)
        let composer = window.descendants(matching: .any).matching(identifier: "composer").firstMatch
        // Q-015 r5: the `chatColumn` group's AX frame is the union of its children (tour tip top … last suggestion), not
        // the column (AX dump: 237…815.5 in a 217…985 detail area), so the column is the window below its toolbar.
        XCTAssertTrue(window.descendants(matching: .any).matching(identifier: "chatColumn").firstMatch.exists)
        let toolbar = window.toolbars.firstMatch.frame
        let column = CGRect(x: window.frame.minX, y: toolbar.maxY, width: window.frame.width, height: window.frame.maxY - toolbar.maxY)
        XCTAssertGreaterThan(column.height, 0.5 * window.frame.height, "toolbar \(toolbar)")
        XCTAssertLessThanOrEqual(abs(composer.frame.midY - column.midY), 0.1 * column.height)
        let field = window.descendants(matching: .any)["composerText"]
        field.click()
        field.typeText("Hello there\r")
        XCTAssertTrue(window.staticTexts["composerDisclaimer"].waitForExistence(timeout: 2))
        XCTAssertGreaterThan(composer.frame.midY, column.midY + 0.3 * column.height)
        // Dock duration: signpost `composerDock` (≤ 300 ms) is read by the probe / Instruments run.
    }

    /// Leg 4: ≤ 4 suggestions from the enabled packs; click fills the composer (no send); no network (-OfflineOnly).
    @MainActor
    func testSuggestionsFillComposer() {
        let (_, window) = launch()
        let cards = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'suggestion.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(cards.count, 4)
        let first = cards.element(boundBy: 0)
        let text = first.displayText
        XCTAssertTrue(chatSuggestions.contains(text), text)
        first.click()
        let field = window.descendants(matching: .any)["composerText"]
        XCTAssertEqual(field.value as? String, text)
        XCTAssertTrue(window.staticTexts["emptyHeadline"].exists, "a suggestion must not send")
    }

    /// Legs 5–6: disclaimer under the docked composer; StartSeparator; scroll up 500 pt → JumpToBottom.
    @MainActor
    func testDisclaimerSeparatorAndJumpToBottom() {
        let (_, window) = launch()
        let field = window.descendants(matching: .any)["composerText"]
        field.click()
        for i in 0..<25 {
            field.typeText("Message \(i) with enough words to take some vertical room.\r")
            // Each send runs a scripted reply; the next send waits for Send to return (W2 wiring).
            XCTAssertTrue(window.buttons["voiceOrSend"].waitForExistence(timeout: 10))
        }
        let disclaimer = window.staticTexts["composerDisclaimer"]
        XCTAssertTrue(disclaimer.waitForExistence(timeout: 2))
        XCTAssertGreaterThanOrEqual(disclaimer.frame.minY, window.descendants(matching: .any).matching(identifier: "composer").firstMatch.frame.maxY - 1)
        let transcript = window.scrollViews["transcript"]
        transcript.scroll(byDeltaX: 0, deltaY: 500)
        let jump = window.buttons["jumpToBottom"]
        XCTAssertTrue(jump.waitForExistence(timeout: 2))
        jump.click()
        XCTAssertTrue(waitFor { !jump.exists })
        transcript.scroll(byDeltaX: 0, deltaY: 100_000)
        XCTAssertTrue(window.descendants(matching: .any)["startSeparator"].waitForExistence(timeout: 2))
    }

    private func waitFor(_ timeout: TimeInterval = 3, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return cond()
    }
}
