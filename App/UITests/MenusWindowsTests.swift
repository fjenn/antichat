// AT-104 UI legs (M1.T24; R-104). Committed, not run on this Mac (Q-015); `tools/at/at-103-probe.sh` covers them.
import XCTest

final class MenusWindowsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testMenusAndWindows() {
        let app = XCUIApplication.antichat(["-DefaultsSuite", "com.antichat.uitest.menus", "-UseScriptedEngine", "basic",
                                            "-OfflineOnly", "YES"])
        app.launch()
        for title in ["New Chat", "New Incognito Chat", "New Project", "New Window", "Close"] {
            XCTAssertTrue(app.menuBars.menuBarItems["File"].menuItems[title].exists, title)
        }
        for title in ["Report a Problem…", "Legal"] {
            XCTAssertTrue(app.menuBars.menuBarItems["Help"].menuItems[title].exists, title)
        }
        app.typeKey("n", modifierFlags: [.command, .option])
        XCTAssertEqual(app.windows.count, 2)
        // Q-015 r4: a normal quit (⌘Q), as the user does: `terminate()` kills the process, and macOS saves window
        // state lazily, so a killed run often had nothing to restore (an empty new-chat window has no chat entry
        // in the app's own last-shown store either).
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "quit")
        app.launch()
        XCTAssertEqual(app.windows.count, 2, "restored")
        app.terminate()
    }
}
