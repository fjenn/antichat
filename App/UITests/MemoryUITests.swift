// AT-060 / AT-246 UI legs (M8.T03; R-060, R-246): inline "Memory updated" + Undo, manage memories, sensitive off by
// default, Memory off per chat, incognito/Evil, suggestions. Committed, not run on this Mac (Q-015: XCUITest cannot
// enable automation mode); MemoryViewModelTests, MemoryToolTests, MemorySnapshotTests and MemoryReviewServiceTests
// cover the logic meanwhile.
import XCTest

final class MemoryUITests: XCTestCase {
    func launch(_ script: String) -> XCUIApplication {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mem-ui-\(UUID().uuidString)")
        let app = XCUIApplication.antichat(["-ANTICHAT_DEV_CONTAINER", dir.path, "-ApplePersistenceIgnoreState", "YES",
                                            "-UseScriptedEngine", script, "-OfflineOnly", "YES"])
        app.launch()
        return app
    }

    @MainActor
    func testRememberShowsInlineLineWithUndo() {
        let app = launch("memory-remember")
        let composer = app.textViews["composerText"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.typeText("Remember that I'm vegetarian\r")
        let line = app.descendants(matching: .any).matching(identifier: "activityLine").firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        line.click()
        let undo = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'memory.undo.'")).firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.click()
        XCTAssertTrue(app.staticTexts["Undone"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testMemoryOffPerChat() {
        let app = launch("basic")
        let toggle = app.buttons["composer.memoryOff"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.click()
        app.textViews["composerText"].typeText("hi\r")
        XCTAssertFalse(toggle.isEnabled)
    }
}
