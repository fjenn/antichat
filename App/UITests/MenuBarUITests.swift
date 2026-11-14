// AT-105 UI leg (M8.T13; R-105 AC1, XCUITest journey 15 part): the menu bar item exists by default; its menu is New
// Chat, Quick Panel, Start Voice, Open AntiChat, Quit AntiChat (+ progress rows while something runs); each item
// acts; turning Settings › General › Menu bar item off removes it.
// Committed, not run on this Mac (Q-015). In-process legs that run today: MenuBarModelTests and
// tools/at/at-105-probe.sh (MacIntegrationProbe mode `menubar`).
import XCTest

final class MenuBarUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-SkipOnboarding", "YES", "-OfflineOnly", "YES",
                                            "-DefaultsSuite", "com.antichat.uitest.menubar"] + extra)
        app.launch()
        return app
    }

    @MainActor
    func item(_ app: XCUIApplication) -> XCUIElement { app.menuBars.statusItems["AntiChat"] }

    @MainActor
    func testMenuItemsInOrderAndActions() {
        let app = launch()
        let status = item(app)
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        status.click()
        let titles = app.menuBars.statusItems["AntiChat"].menus.menuItems.allElementsBoundByIndex.map(\.title).filter { !$0.isEmpty }
            .map { $0.components(separatedBy: ", ").first ?? $0 }  // "Quick Panel, ⌥Space": the item shows its hotkey
        XCTAssertEqual(titles, ["New Chat", "Quick Panel", "Start Voice", "Open AntiChat", "Quit AntiChat"])
        // The status item's own menu ("New Chat" is in the main menu too; Q-015 r2: multiple matches).
        status.menus.menuItems["New Chat"].click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 3))
        status.click()
        status.menus.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Quick Panel'")).firstMatch.click()
        XCTAssertTrue(app.dialogs.matching(identifier: "quickPanel").firstMatch.waitForExistence(timeout: 3))  // an NSPanel: AX dialog
        app.typeKey(.escape, modifierFlags: [])
        status.click()
        status.menus.menuItems["Quit AntiChat"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    }

    @MainActor
    func testToggleOffRemovesTheItem() {
        let app = launch(["-menuBarItem", "NO"])
        XCTAssertFalse(item(app).waitForExistence(timeout: 3))
    }
}
