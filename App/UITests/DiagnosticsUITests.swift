// AT-218 / AT-NFR-PR2 UI legs (M8.T09; R-218, NFR-PR2, S-24, S-21): the next-launch crash prompt (DEBUG
// `-SimulateCrashOnNextLaunch YES` writes a synthetic crash file), no prompt during onboarding, Export logs with
// "Include chat content" off by default, the prefilled Report a problem form and System report Copy. Committed, not
// run on this Mac (Q-015: XCUITest cannot enable automation mode); DiagnosticsTests cover the logic.
import XCTest

final class DiagnosticsUITests: XCTestCase {
    @MainActor
    func launch(_ extra: [String] = [], container: URL? = nil) -> XCUIApplication {
        let dir = container ?? FileManager.default.temporaryDirectory.appendingPathComponent("diag-ui-\(UUID().uuidString)")
        let app = XCUIApplication.antichat(["-ANTICHAT_DEV_CONTAINER", dir.path, "-ApplePersistenceIgnoreState", "YES",
                                            "-UseScriptedEngine", "basic", "-OfflineOnly", "YES"] + extra)
        app.launch()
        return app
    }

    @MainActor
    func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    @MainActor
    func testCrashPromptAfterCrash() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diag-ui-\(UUID().uuidString)")
        launch(container: dir).terminate()  // first launch starts the marker
        let app = launch(["-SimulateCrashOnNextLaunch", "YES"], container: dir)
        XCTAssertTrue(el(app, "crashPrompt").waitForExistence(timeout: 10))
        for id in ["crash.preview", "crash.send", "crash.dontSend", "crash.always"] { XCTAssertTrue(el(app, id).exists, id) }
        el(app, "crash.preview").click()
        XCTAssertTrue(el(app, "crash.previewText").waitForExistence(timeout: 2))
        el(app, "crash.dontSend").click()
    }

    @MainActor
    func testNoPromptDuringOnboarding() {
        let app = launch(["-SimulateCrashOnNextLaunch", "YES", "-ResetOnboarding", "YES"])
        XCTAssertFalse(el(app, "crashPrompt").waitForExistence(timeout: 5))
    }

    @MainActor
    func testExportLogsCheckboxDefaultOff() {
        let app = launch()
        app.menuBars.menuBarItems["Help"].click()
        app.menuItems["Export Logs…"].click()
        let box = el(app, "logs.includeContent")
        XCTAssertTrue(box.waitForExistence(timeout: 5))
        XCTAssertEqual(box.value as? Int, 0)
    }

    @MainActor
    func testReportFormPrefilled() {
        let app = launch()
        app.menuBars.menuBarItems["Help"].click()
        app.menuItems["Report a Problem…"].click()
        let system = el(app, "report.system")
        XCTAssertTrue(system.waitForExistence(timeout: 5))
        XCTAssertTrue((system.displayText as String).contains("Tier") || (system.value as? String ?? "").contains("Tier"))
        XCTAssertEqual(el(app, "report.attachLogs").value as? Int, 1)
        XCTAssertFalse(el(app, "report.github").isEnabled)
    }

    @MainActor
    func testSystemReportCopy() {
        let app = launch()
        app.typeKey(",", modifierFlags: .command)
        el(app, "settings.nav.about").click()
        el(app, "settings.control.systemReport").click()
        XCTAssertTrue(el(app, "systemReport.text").waitForExistence(timeout: 5))
        el(app, "systemReport.copy").click()
        XCTAssertTrue((NSPasteboard.general.string(forType: .string) ?? "").contains("Tier:"))
    }
}
