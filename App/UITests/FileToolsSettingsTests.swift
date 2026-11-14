import XCTest

final class FileToolsSettingsTests: XCTestCase {
    func testFileToolsRowsAndInstantSave() {
        let suite = "com.antichat.uitest.filetools"
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-DefaultsSuite", suite,
                                            "-UseScriptedEngine", "basic", "-OfflineOnly", "YES"])
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.containing(.any, identifier: "settings.root").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.descendants(matching: .any).matching(identifier: "settings.nav.tools").firstMatch.click()
        let detail = settings.scrollViews.matching(identifier: "settings.detail.tools").firstMatch
        for id in ["createFiles", "runCode", "codeNet"] {
            // The row's control (these rows carry no settings.row id of their own; Q-015 r2).
            let row = settings.descendants(matching: .any).matching(identifier: "settings.control.\(id)").firstMatch
            XCTAssertTrue(detail.scrollUntilVisible(row), id)  // below the fold of Tools & Connections
        }
        let create = settings.descendants(matching: .any).matching(identifier: "settings.control.createFiles").firstMatch
        XCTAssertEqual(create.stringValue, "1")
        create.click()
        XCTAssertEqual(create.stringValue, "0")
        XCTAssertEqual(UserDefaults(suiteName: suite)?.bool(forKey: "createFilesEnabled"), false)
    }
}
