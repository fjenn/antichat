// AT-093 / AT-019 UI legs (M8.T07; R-093, R-019, S-21, S-24): Settings › Privacy & Data › Export all data… → options
// (media toggle) → (the `-ExportFile` DEBUG stand-in for the save panel) → progress → "Exported to …" with Show in
// Finder; and the title-bar Share menu with exactly its six items in order. Committed, not run on this Mac (Q-015:
// XCUITest cannot enable automation mode); ExportAllTests, RoundTripTests and ShareExportTests cover the exporters.
import XCTest

final class ExportUITests: XCTestCase {
    @MainActor
    func testExportAllWithProgressAndChosenLocation() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-ui-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("AntiChat-Export-ui.zip")
        let app = XCUIApplication.antichat(["-ANTICHAT_DEV_CONTAINER", dir.appendingPathComponent("container").path,
                                            "-ApplePersistenceIgnoreState", "YES", "-UseScriptedEngine", "basic",
                                            "-OfflineOnly", "YES", "-ExportFile", out.path])
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        let privacy = app.descendants(matching: .any).matching(identifier: "settings.nav.privacy").firstMatch
        XCTAssertTrue(privacy.waitForExistence(timeout: 10))
        privacy.click()
        let open = app.descendants(matching: .any).matching(identifier: "settings.control.exportAll").firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "export.includeMedia").firstMatch.waitForExistence(timeout: 5))
        app.descendants(matching: .any).matching(identifier: "export.choose").firstMatch.click()
        let done = app.descendants(matching: .any).matching(identifier: "export.done").firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 30))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "export.showInFinder").firstMatch.exists)
    }

    @MainActor
    func testShareMenuItems() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-ui-\(UUID().uuidString)")
        let app = XCUIApplication.antichat(["-ANTICHAT_DEV_CONTAINER", dir.path, "-ApplePersistenceIgnoreState", "YES",
                                            "-UseScriptedEngine", "basic", "-OfflineOnly", "YES"])
        app.launch()
        let composer = app.descendants(matching: .any).matching(identifier: "composerText").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.click()
        composer.typeText("Hello\n")
        let share = app.descendants(matching: .any).matching(identifier: "shareButton").firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        XCTAssertTrue(share.wait(10) { $0.isEnabled }, "Share stays disabled until the chat exists")
        share.click()
        let ids = ["share.copyMarkdown", "share.exportMarkdown", "share.exportPDF", "share.exportHTML", "share.copyImage", "share.sheet"]
        let items = ids.map { app.menuItems.matching(identifier: $0).firstMatch }
        for item in items { XCTAssertTrue(item.waitForExistence(timeout: 5)) }
        let ys = items.map(\.frame.minY)
        XCTAssertEqual(ys, ys.sorted(), "Share items out of order")
        items[5].click()
        XCTAssertTrue(app.popovers.firstMatch.waitForExistence(timeout: 5) || app.sheets.firstMatch.exists)
    }
}
