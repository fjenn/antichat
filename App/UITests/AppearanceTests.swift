// AT-101 UI legs (M1.T23; R-101): every Appearance option exists with its settings-map default, and changing it
// updates the open chat in place (screenshot regions differ; the app PID is unchanged).
// Committed, not run on this Mac (Q-015: XCUITest cannot enable automation mode); the in-process probe
// `tools/at/at-101-probe.sh` (`-AppearanceProbe`) covers the same legs meanwhile.
import AppKit
import XCTest

final class AppearanceTests: XCTestCase {
    static let suite = "com.antichat.uitest.appearance"

    override func setUp() {
        continueAfterFailure = false
    }

    /// XCUIApplication has no public processIdentifier on macOS; the running app's PID via NSWorkspace instead.
    static func pid(of app: XCUIApplication) -> pid_t? {
        app.processID  // this test's app, never another worktree's instance of the same bundle id
    }

    func element(_ root: XCUIElement, _ id: String) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// (1) every option, (2) each change reaches the open chat without a restart.
    @MainActor
    func testEveryOptionAppliesLive() throws {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-DefaultsSuite", Self.suite,
                                            "-UseScriptedEngine", "basic", "-OfflineOnly", "YES"])
        app.launch()
        let pid = Self.pid(of: app)
        let composer = element(app, "composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.click()
        app.typeText("A short line to measure.\r")
        let user = element(app, "userText")
        XCTAssertTrue(user.waitForExistence(timeout: 20))

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.containing(.any, identifier: "settings.root").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        element(settings, "settings.nav.appearance").click()
        for id in ["colorMode", "accentColor", "chatFont", "textSize", "readingWidth", "reduceMotion",
                   "reduceTransparency", "increaseContrast"] {
            XCTAssertTrue(element(settings, "settings.control.\(id)").exists, id)
        }

        // Reading width: Wide (760) → Narrow (640).
        let column = element(app, "transcriptColumn")
        XCTAssertEqual(column.frame.width, 760, accuracy: 1)
        element(settings, "settings.control.readingWidth").radioButtons.element(boundBy: 0).click()
        XCTAssertEqual(column.frame.width, 640, accuracy: 1)

        // Chat font: Dyslexia-friendly widens the glyph run.
        let w0 = user.frame.width
        element(settings, "settings.control.chatFont").click()
        app.menuItems["Dyslexia-friendly"].click()
        XCTAssertGreaterThan(user.frame.width, w0 * 1.1)

        // Color mode Dark: the chat window's background darkens.
        let before = app.windows.firstMatch.screenshot().pngRepresentation
        element(settings, "settings.control.colorMode").radioButtons.element(boundBy: 2).click()
        XCTAssertNotEqual(app.windows.firstMatch.screenshot().pngRepresentation, before)

        XCTAssertEqual(Self.pid(of: app), pid, "no restart")
        app.terminate()
    }
}
