// AT-017 check 2 (R-017 AC2; M6.T13 step 7) — XCUITest. XCUITest can't start on the build Mac (Q-015): recorded
// `pending (Q-015)`; the in-process legs are AntiChatStorageTests/ChatFilesQueryTests (attached + produced rows, latest
// version, newest first) and AntiChatUIModuleTests/FilesOutPanelTests (Outputs filter, row subtitle).
// Setup: ScriptedEngine `artifacts-page.jsonl`; a CSV attached from fixtures/docs/formats-8.
import XCTest

final class FilesInChatTests: XCTestCase {
    private var turn: TurnApp!
    private var app: XCUIApplication { turn.app }

    override func setUp() { continueAfterFailure = false }

    override func tearDown() { turn?.app.terminate() }

    @MainActor
    func testSheetListsAttachedAndProduced() {
        turn = TurnApp(script: "artifacts-page.jsonl")
        turn.launch()
        turn.send("Make the page")
        XCTAssertTrue(app.descendants(matching: .any)["artifactCard"].firstMatch.waitForExistence(timeout: 30))
        app.menuButtons["chatMoreMenu"].click()
        app.menuItems["Files in this chat"].click()
        // Round 65 (098544b61, S-24): each name is a link (`filesInChat.open`) that opens the file, its text the label.
        let row = app.links.matching(NSPredicate(format: "identifier == 'filesInChat.open' AND label == 'Launch checklist.html'"))
        XCTAssertTrue(row.firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testEmptyState() {
        turn = TurnApp(script: "basic.jsonl")
        turn.launch()
        turn.send("Hi")
        app.menuButtons["chatMoreMenu"].click()
        app.menuItems["Files in this chat"].click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'no files' OR value CONTAINS[c] 'no files'")).firstMatch
            .waitForExistence(timeout: 5))
    }
}
