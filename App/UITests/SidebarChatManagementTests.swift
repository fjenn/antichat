// R-011 sidebar / chat menu (M1.T07 step 6; AT-011 closes in M1.T22): rename, pin, archive, delete with
// confirmation, through the title-bar ⋯ menu and its shortcuts. Blocked by Q-015 like WindowLayoutTests; the probe's
// leg 7 covers the same operations in-process.
import XCTest

final class SidebarChatManagementTests: XCTestCase {
    @MainActor
    func testRenamePinArchiveDelete() {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-OfflineOnly", "YES",
                                            "-UseScriptedEngine", TurnApp.script("basic.jsonl")])
        app.launch()
        let window = app.mainWindow
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let field = window.descendants(matching: .any)["composerText"]
        field.click()
        field.typeText("First chat\r")
        let rows = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chatRow.' AND identifier != 'chatRow.streaming'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 2))

        // Rename ⌥⌘R (title bar), inline field, Return.
        app.typeKey("r", modifierFlags: [.command, .option])
        let renameField = window.textFields.firstMatch
        XCTAssertTrue(renameField.waitForExistence(timeout: 2))
        renameField.typeText("Renamed chat\r")
        XCTAssertTrue(window.staticTexts["Renamed chat"].waitForExistence(timeout: 1))

        // Pin ⌥⌘P → Pinned section.
        app.typeKey("p", modifierFlags: [.command, .option])
        XCTAssertTrue(window.descendants(matching: .any)["sidebarSection.pinned"].waitForExistence(timeout: 1))

        // Archive ⇧⌘A → row gone, back to a new chat.
        app.typeKey("a", modifierFlags: [.command, .shift])
        XCTAssertTrue(window.staticTexts["emptyHeadline"].waitForExistence(timeout: 1))
        XCTAssertFalse(window.staticTexts["Renamed chat"].exists)

        // Delete via the row menu with confirmation.
        field.click()
        field.typeText("Second chat\r")
        window.menuButtons["chatMoreMenu"].click()
        window.menuItems["menu.delete"].click()
        let confirm = app.buttons["deleteConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        confirm.click()
        XCTAssertTrue(window.staticTexts["emptyHeadline"].waitForExistence(timeout: 1))
    }
}
