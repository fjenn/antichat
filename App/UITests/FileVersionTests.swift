// AT-273 check 4, UI leg (R-273 AC4; M6.T10 step 5) — XCUITest. XCUITest can't start on the build Mac (Q-015):
// recorded `pending (Q-015)`; the in-process legs are AntiChatHarnessTests/FileVersionToolTests (revises → version 2 on
// the same artifact, version 1 kept), AntiChatToolsTests/XLSXWriterGoldenTests.revisionsMakeVersionTwoAndKeepVersionOne
// and AntiChatUIModuleTests/FileOutActivityTests (the ‹ v1 v2 › switcher from the persisted result).
// Setup: ScriptedEngine `fileout-version.jsonl` (create_spreadsheet, then — after the user's change request — the same
// call with `revises`).
import XCTest

final class FileVersionTests: XCTestCase {
    private var turn: TurnApp!
    private var app: XCUIApplication { turn.app }

    override func setUp() { continueAfterFailure = false }

    override func tearDown() { turn?.app.terminate() }

    @MainActor
    func testChangeRequestShowsVersionTwoWithSwitcher() {
        turn = TurnApp(script: "fileout-version.jsonl")
        turn.launch()
        turn.send("Make a budget spreadsheet")
        XCTAssertTrue(app.descendants(matching: .any)["fileOutCard"].waitForExistence(timeout: 30))
        turn.send("Add a total row")
        let switcher = app.descendants(matching: .any)["fileVersionSwitcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["fileVersionLabel"].value as? String ?? app.staticTexts["fileVersionLabel"].displayText, "Version 2")
        app.buttons["fileVersionPrevious"].click()
        XCTAssertEqual(app.staticTexts["fileVersionLabel"].displayText, "Version 1")
        XCTAssertTrue(app.buttons["fileCardOpen"].firstMatch.isEnabled, "version 1 still opens")
    }
}
