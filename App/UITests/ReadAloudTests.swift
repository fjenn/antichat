// M3.T07 (AT-054 AC1; R-054, IS-9): read aloud toggles in place — speaker → spinner → stop (`msg.stopReading`) in the
// same button frame — and a second click stops playback (≤ 200 ms) and returns the button to `msg.readAloud`.
// `-FakePackState voice=ready` (Kokoro). Committed, not run on this Mac (Q-015: XCUITest cannot enable automation
// mode); KokoroBackendTests (order, stop ≤ 200 ms), ClauseChunkerTests, SpeakableTextTests and ReadAloudLatencyTests
// (V8) cover the logic meanwhile.
import XCTest

final class ReadAloudTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func element(_ root: XCUIElement, _ id: String) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func reply(_ app: XCUIApplication) -> XCUIElement {
        let field = element(app, "composerText")
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.click()
        field.typeText("Hello\r")
        let msg = element(app, "assistantMessage")
        XCTAssertTrue(msg.waitForExistence(timeout: 10))
        msg.hover()
        return element(app, "action.readAloud")
    }

    func launch() -> XCUIApplication {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-UseScriptedEngine", "basic",
                                            "-FakePackState", "voice=ready"])
        app.launch()
        return app
    }

    @MainActor
    func testToggleInPlace() throws {
        let app = launch()
        let button = reply(app)
        let frame = button.frame
        XCTAssertEqual(button.displayText, "Read aloud")
        button.click()
        let stop = NSPredicate(format: "label == %@", "Stop reading")
        expectation(for: stop, evaluatedWith: button)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(button.frame, frame, "the toggle happens in place")
    }

    @MainActor
    func testSecondClickStops() throws {
        let app = launch()
        let button = reply(app)
        button.click()
        expectation(for: NSPredicate(format: "label == %@", "Stop reading"), evaluatedWith: button)
        waitForExpectations(timeout: 3)
        // Polled tightly (Q-015 r3): an NSPredicate expectation re-evaluates about once a second, so its own cadence
        // pushed the measured stop past the 1 s bar. The clock still starts before the click.
        let t0 = Date()
        button.click()
        var stopped = false
        while !stopped, Date().timeIntervalSince(t0) < 3 {
            stopped = button.label == "Read aloud"
            if !stopped { Thread.sleep(forTimeInterval: 0.02) }
        }
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertTrue(stopped, "the second click stops reading")
        XCTAssertLessThan(elapsed, 1.0)
    }
}
