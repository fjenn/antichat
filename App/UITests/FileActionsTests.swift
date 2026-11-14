// AT-017 check 1 + AT-277 (R-017 AC1, R-277 AC1–AC3; M6.T13 steps 6, 8–10) — XCUITest, parameterised over
// fixtures/docs/formats-8. XCUITest can't start on the build Mac (Q-015): recorded `pending (Q-015)`; the in-process leg
// is AntiChatUIModuleTests/FileActionsMatrixTests (8 formats × 8 actions, attachment + generated legs, writes
// build/at/AT-277/<date>/matrix.json: 56/64 with Show in Library deferred to M5.T13). The Finder / Mail drag runs in
// vq-07 steps 24–25 (computer use, Q-021).
import XCTest

final class FileActionsTests: XCTestCase {
    private var turn: TurnApp!
    private var app: XCUIApplication { turn.app }
    static let formats = ["report.pdf", "report.docx", "budget.xlsx", "deck.pptx", "notes.csv", "photo.png", "photo.jpg", "memo.m4a"]

    override func setUp() { continueAfterFailure = false }

    override func tearDown() { turn?.app.terminate() }

    @MainActor
    func testOpenSaveReveal() {
        // The basic script makes no file, so no card ever came: create_document (vq-files-out) on a tool-capable model.
        turn = TurnApp(script: "vq-files-out.jsonl")
        turn.app.launchArguments += ["-ChatModel", "chat-9b-q4", "-FakeHardware", "T1", "-SkipOnboarding", "YES"]
        turn.launch()
        for name in Self.formats {
            let file = TurnApp.repoRoot.appendingPathComponent("fixtures/docs/formats-8/\(name)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), name)
        }
        turn.send("Summarise my weir notes as a PDF")
        let card = app.descendants(matching: .any)["fileOutCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["fileCardOpen"].firstMatch.isEnabled)
        app.menuButtons["fileCardMore"].firstMatch.clickReliably()
        // The More menu's items. Q-015 r4: their identifiers do reach the menu items (FileCardTests finds
        // `fileCardSaveAs`), while a title match depends on the per-file accessibility label ("Save <file> as…").
        for id in ["fileCardSaveAs", "fileCardReveal", "fileCardCopy", "fileCardShare"] {
            XCTAssertTrue(app.menuItems[id].firstMatch.waitForExistence(timeout: 3), id)
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testAccessibilityAudit() throws {
        turn = TurnApp(script: "artifacts-page.jsonl")
        turn.launch()
        turn.send("Make the page")
        XCTAssertTrue(app.descendants(matching: .any)["artifactCard"].firstMatch.waitForExistence(timeout: 30))
        // One failure per issue, naming the element; tools/a11y/audit-ignores.yml applies here too (Q-015 r4).
        try AccessibilityAuditTests.audit(app, "FileActions")
    }
}
