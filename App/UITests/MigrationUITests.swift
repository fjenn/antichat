// AT-301 UI legs (M8.T01; R-301 AC2/AC3, S-25): the newer-data window (text = `storage.newerVersion`, no sidebar,
// [Update AntiChat]) and Restore from backup (Settings → Privacy & Data, seeded dev container).
// Committed, not run on this Mac (Q-015: XCUITest cannot enable automation mode); MigrationRunnerTests and
// BackupServiceTests cover the logic, and `tools/visual/cap.sh vq-11 newer-data-*` captures the window.
import XCTest

final class MigrationUITests: XCTestCase {
    static var fixtures: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("fixtures").path)
            .appendingPathComponent("chats/db")
    }

    func container(_ fixture: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mig-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(fixture),
                                         to: dir.appendingPathComponent("antichat.sqlite"))
        return dir
    }

    @MainActor
    func testNewerDataWindow() throws {
        let dir = try container("future-v999.sqlite")
        let app = XCUIApplication.antichat(["-ANTICHAT_DEV_CONTAINER", dir.path, "-ApplePersistenceIgnoreState", "YES"])
        app.launch()
        let window = app.descendants(matching: .any).matching(identifier: "newerData.window").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let message = app.staticTexts.matching(identifier: "blocking.message").firstMatch
        XCTAssertEqual(message.displayText, "This data was made by a newer AntiChat. Please update.")
        XCTAssertTrue(app.buttons["newerData.update"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "sidebar.root").firstMatch.exists)
    }

    @MainActor
    func testRestoreFromBackup() throws {
        let dir = try container("v13_artifact.sqlite")  // migrating it to head writes a pre-update backup
        let app = XCUIApplication.antichat(["-ANTICHAT_DEV_CONTAINER", dir.path, "-ApplePersistenceIgnoreState", "YES",
                                            "-UseScriptedEngine", "basic", "-OfflineOnly", "YES"])
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        app.descendants(matching: .any).matching(identifier: "settings.nav.privacy").firstMatch.click()
        let open = app.buttons["settings.control.restoreBackup"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        let list = app.descendants(matching: .any).matching(identifier: "restore.list").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(list.buttons.count, 1)
    }
}
