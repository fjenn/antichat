// AT-103 UI legs (M1.T24; R-103). Committed, not run on this Mac (Q-015: XCUITest cannot enable automation mode);
// the in-process probe `tools/at/at-103-probe.sh` (`-ShortcutsProbe`) covers the same legs meanwhile.
import XCTest

final class ShortcutsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testDefaultsRebindConflictRestore() {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-DefaultsSuite", "com.antichat.uitest.shortcuts",
                                            "-UseScriptedEngine", "basic", "-OfflineOnly", "YES"])
        app.launch()
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "palette").firstMatch.waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("/", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "shortcutList").firstMatch.waitForExistence(timeout: 3))
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.containing(.any, identifier: "settings.root").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.descendants(matching: .any).matching(identifier: "settings.nav.shortcuts").firstMatch.click()
        let palette = settings.descendants(matching: .any).matching(identifier: "settings.shortcut.palette").firstMatch
        palette.click()
        app.typeKey("k", modifierFlags: [.command, .option])
        XCTAssertTrue(app.menuBars.menuItems["Search"].exists)
        settings.descendants(matching: .any).matching(identifier: "settings.control.shortcutsRestore").firstMatch.click()
        app.terminate()
    }
}
