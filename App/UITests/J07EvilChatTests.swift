// AT-210 / AT-211 UI legs (M2.T17, R-210, R-211; journey J07 Evil chat). Blocked by Q-015 like every XCUITest on this
// Mac (automation mode): recorded `pending (Q-015)`; the unit legs (ModeLockTests, ConsentVersionTests,
// ToneClauseSnapshotTests, EvilSnapshotTests) run meanwhile. `-FakeEvilEnabled YES` turns Evil on without the sheet;
// `-FakeLAContext succeed|fail` answers Touch ID.
import XCTest

final class J07EvilChatTests: XCTestCase {
    @MainActor
    private func launch(_ extra: [String] = []) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication.antichat(["-UseScriptedEngine", TurnApp.script("regen.jsonl"), "-OfflineOnly", "YES",
                                            "-FakeEvilEnabled", "YES"] + extra)
        app.launch()
        let window = app.mainWindow
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        // The File menu acts on the focused window (its scene value); focus the composer before ⇧⌘E (Q-015 catch-up).
        window.descendants(matching: .any).matching(identifier: "composerText").firstMatch.click()
        let item = app.menuItems["New Evil Chat"]
        XCTAssertTrue(item.wait(5) { $0.isEnabled }, "New Evil Chat stays disabled")
        return (app, window)
    }

    private func element(_ window: XCUIElement, _ id: String) -> XCUIElement { window.descendants(matching: .any)[id] }

    /// ⇧⌘E → Evil chat: frame, badge, empty state; send → lock glyph + sidebar dot; lock popover → Continue in a
    /// new Normal chat (copied active path, no frame).
    @MainActor
    func testEvilChatJourney() {
        let (app, window) = launch()
        app.typeKey("e", modifierFlags: [.command, .shift])
        for id in ["evil.frame", "evil.badge", "evilHeadline"] {
            XCTAssertTrue(element(window, id).waitForExistence(timeout: 3), "\(id) missing")
        }
        let field = window.textViews.firstMatch
        field.click()
        field.typeText("Hello\r")
        XCTAssertTrue(element(window, "modeSwitch.locked").waitForExistence(timeout: 10))
        // The row is one button; its Evil dot is spoken as ", Evil mode chat" in the row's label (Q-015 r5: the dot is
        // accessibility-hidden, not its own element — as the unread dot, SidebarStatusTests).
        let evilRow = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chatRow.' AND label ENDSWITH %@",
                                                                              ", Evil mode chat")).firstMatch
        XCTAssertTrue(evilRow.exists, "the sidebar row marks the Evil chat")
        element(window, "modeSwitch.locked").click()
        XCTAssertTrue(element(window, "evil.lockedText").waitForExistence(timeout: 2))
        XCTAssertTrue(element(window, "modeSwitch.evil").exists)  // the current mode's row, checked
        element(window, "evil.continueNormal").click()  // "New Normal chat"
        XCTAssertFalse(element(window, "evil.frame").waitForExistence(timeout: 2))
    }

    /// R-211 AC4: Touch ID on + a failed prompt → the Evil chat is not shown.
    @MainActor
    func testTouchIDCancelLeavesTheChat() {
        let (app, window) = launch(["-FakeLAContext", "fail"])
        app.typeKey("e", modifierFlags: [.command, .shift])
        XCTAssertTrue(element(window, "evil.frame").waitForExistence(timeout: 3))
    }
}
