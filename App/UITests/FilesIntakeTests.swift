// AT-020 (R-020 AC1/AC3/AC4; M6.T01) — XCUITest leg. XCUITest can't start on the build Mac (Q-015): recorded
// `pending (Q-015)`; the same paths run in-process in FilesIntakeHostTests (tiles, 21 → 20 + toast, corrupt → error
// tile + toast, × removes, files-only send) and IntakeTests (513 MB sparse file, encrypted, incognito).
// Paths: + → Add photos & files opens the open panel as a sheet; dragging 3 files onto the window shows the
// `files.drop` overlay and 3 tiles; ⌘V of a PNG adds an image tile.
import AppKit
import XCTest

final class FilesIntakeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() { continueAfterFailure = false }

    override func tearDown() {
        if let app {
            let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    static var fixtures: URL {
        if let env = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !env.isEmpty { return URL(fileURLWithPath: env) }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent("fixtures")
    }

    @MainActor
    private func launch() {
        app = XCUIApplication.antichat(["-UseScriptedEngine", "YES"])
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
    }

    @MainActor
    func testOpenPanelIsASheet() {
        launch()
        app.buttons["composerAdd"].click()
        app.buttons["addRow.files"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5), "the open panel is a sheet on the window")
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testPasteOfAPNGAddsATile() throws {
        launch()
        let image = try XCTUnwrap(NSImage(contentsOf: Self.fixtures.appendingPathComponent("images/upload-errors/sample.png")))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        app.descendants(matching: .any).matching(identifier: "composer").firstMatch.click()
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "fileTile").firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    func testCorruptPDFShowsErrorTileAndToast() throws {
        launch()
        let url = Self.fixtures.appendingPathComponent("docs/pdf/corrupt.pdf")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        app.descendants(matching: .any).matching(identifier: "composer").firstMatch.click()
        app.typeKey("v", modifierFlags: .command)
        let tile = app.descendants(matching: .any).matching(identifier: "fileTile").firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        // The toast first (it dismisses itself after a few seconds; the 10 s wait below used to outlast it), as any
        // element showing the text; the tile is one element whose label carries its state (Q-015 r3).
        // Static texts only (the toast's line is a Text): a CONTAINS on label/value over every element type made XCTest
        // fetch every element's value and timed out with the app idle (Q-015 r2/r5, "Timed out while evaluating UI query").
        let toast = app.mainWindow.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                                                    "Couldn't read corrupt.pdf.", "Couldn't read corrupt.pdf."))
        XCTAssertTrue(toast.firstMatch.waitForExistence(timeout: 5), "toast")
        let failed = NSPredicate(format: "label CONTAINS %@", "Couldn't read this file")
        expectation(for: failed, evaluatedWith: tile)
        waitForExpectations(timeout: 10)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "error-tile"
        shot.lifetime = .keepAlways
        add(shot)
        tile.hover()
        app.buttons["fileTileRemove"].click()
        XCTAssertFalse(tile.exists)
    }
}
