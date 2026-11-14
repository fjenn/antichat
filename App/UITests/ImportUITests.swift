// AT-092 UI leg (M8.T06; R-092, S-24): Settings › Privacy & Data › Import → guide sheet → (the `-ImportFile` DEBUG
// stand-in for the open panel) → progress → summary with the kept-as-text counts → "Imported" chips in the sidebar.
// Committed, not run on this Mac (Q-015: XCUITest cannot enable automation mode); ChatGPTImportTests,
// ClaudeImportTests and ImportDedupTests cover the import itself.
import XCTest

final class ImportUITests: XCTestCase {
    static var fixtures: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("fixtures/chats")
    }

    @MainActor
    func importFile(_ rel: String) -> XCUIApplication {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-ui-\(UUID().uuidString)")
        let app = XCUIApplication.antichat(["-ANTICHAT_DEV_CONTAINER", dir.path, "-ApplePersistenceIgnoreState", "YES",
                                            "-UseScriptedEngine", "basic", "-OfflineOnly", "YES",
                                            "-ImportFile", Self.fixtures.appendingPathComponent(rel).path])
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        let privacy = app.descendants(matching: .any).matching(identifier: "settings.nav.privacy").firstMatch
        XCTAssertTrue(privacy.waitForExistence(timeout: 10))
        privacy.click()
        let open = app.descendants(matching: .any).matching(identifier: "settings.control.importChats").firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        let choose = app.descendants(matching: .any).matching(identifier: "import.choose").firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        return app
    }

    @MainActor
    func testChatGPTImportShowsSummaryAndChips() {
        let app = importFile("chatgpt-export/export.zip")
        let summary = app.descendants(matching: .any).matching(identifier: "import.summary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'kept as plain text' OR value CONTAINS 'kept as plain text'")).firstMatch.exists)
        app.descendants(matching: .any).matching(identifier: "import.done").firstMatch.click()
        let chip = app.descendants(matching: .any).matching(identifier: "chatRow.imported").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
    }

    @MainActor
    func testClaudeImport() {
        let app = importFile("claude-export/export.zip")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "import.summary").firstMatch.waitForExistence(timeout: 30))
    }
}
