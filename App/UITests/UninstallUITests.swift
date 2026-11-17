// AT-226 UI leg (M8.T11; R-226 AC1, S-24) + the AT-205 Storage sheets (M8.T10): AntiChat › Uninstall AntiChat… lists
// what goes with sizes and paths and needs the exact word UNINSTALL; `-UninstallDryRun YES` stops before the
// destructive step. Remove everything needs REMOVE. Committed, not run on this Mac (Q-015); UninstallServiceTests and
// RemoveEverythingTests cover the logic, tools/install-test the real removal.
import XCTest

final class UninstallUITests: XCTestCase {
    @MainActor
    func launch() -> XCUIApplication {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-ui-\(UUID().uuidString)")
        let app = XCUIApplication.antichat(["-ANTICHAT_DEV_CONTAINER", dir.path, "-ApplePersistenceIgnoreState", "YES",
                                            "-UseScriptedEngine", "basic", "-OfflineOnly", "YES", "-UninstallDryRun", "YES"])
        app.launch()
        return app
    }

    @MainActor
    func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    @MainActor
    func testSheetListsPathsAndRequiresTypedConfirm() {
        let app = launch()
        app.menuBars.menuBarItems["AntiChat"].click()
        app.menuItems["Uninstall AntiChat…"].click()
        XCTAssertTrue(el(app, "uninstallSheet").waitForExistence(timeout: 5))
        // Every row names its path (a dev-container run lists the container's paths, not ~/Library/Application Support).
        XCTAssertTrue(el(app, "uninstall.list").staticTexts.matching(NSPredicate(format: "label BEGINSWITH '/' OR value BEGINSWITH '/'")).count >= 3)
        let field = el(app, "uninstall.field"), confirm = el(app, "uninstall.confirm")
        field.click()
        field.typeText("UNINSTAL")
        XCTAssertFalse(confirm.isEnabled)
        field.typeText("LL")
        XCTAssertFalse(confirm.isEnabled, "UNINSTALL exactly (not UNINSTALLL)")
        field.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(confirm.wait(2) { $0.isEnabled }, "UNINSTALL enables the button")
        confirm.click()  // dry run: the sheet closes, nothing is removed
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    @MainActor
    func testRemoveEverythingRequiresREMOVE() {
        let app = launch()
        app.typeKey(",", modifierFlags: .command)
        el(app, "settings.nav.privacy").click()
        // The page grows while it measures (bar, legend, model rows): a click aimed before that lands on whatever moved
        // under it (it opened the Clean up sheet). Refresh is disabled while measuring.
        let measured = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: el(app, "storage.refresh"))
        wait(for: [measured], timeout: 20)
        el(app, "settings.control.removeEverything").click()
        let field = el(app, "removeEverything.field"), confirm = el(app, "removeEverything.confirm")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("REMOV")
        XCTAssertFalse(confirm.isEnabled)
        el(app, "settings.control.removeEverything").typeKey(.escape, modifierFlags: [])
    }
}
