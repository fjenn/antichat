// AT-034 AC1/AC5 UI legs (R-034, M4.T15): the viewer's editor toolbar — Remove background and Erase each make a new
// version (top of the version rail), and the kept tools are present (Markup, Sketch, Comment pins and Resize moved to
// M11, D-026). The local jobs run through the queue, the helper's runner and its gate like every Photo output.
// Committed, not run on this Mac (Q-015: XCUITest cannot start). In-process legs that run today: ImageEditorActionsTests
// (queue job, next version, outcomes), MaskBrushTests, MaskCompositorTests, RemoveBackgroundTests, and
// R241PathTraceTests/testLocalJobGateCalls (tools/at/at-285-runner.sh).
import AppKit
import XCTest

final class ImageEditorTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func openViewer() -> XCUIApplication {
        let app = MediaUIApp.launch()
        MediaUIApp.send(app, "Draw me a lighthouse at dusk")
        let card = MediaUIApp.element(app, "imageJobCard.result")
        XCTAssertTrue(card.waitForExistence(timeout: 60))
        card.click()
        XCTAssertTrue(MediaUIApp.element(app, "imageViewer").waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    func testKeptTools() {
        let app = openViewer()
        XCTAssertTrue(MediaUIApp.element(app, "editorToolbar").exists)
        XCTAssertTrue(MediaUIApp.element(app, "editor.erase").exists)
        XCTAssertTrue(MediaUIApp.element(app, "editor.removeBg").exists)
        XCTAssertTrue(MediaUIApp.element(app, "editor.describe").exists)
        for moved in ["editor.markup", "editor.sketch", "editor.pins", "editor.resize"] {
            XCTAssertFalse(MediaUIApp.element(app, moved).exists, "\(moved) is M11 (D-026)")
        }
    }

    @MainActor
    func testRemoveBackgroundNewVersion() {
        let app = openViewer()
        MediaUIApp.element(app, "editor.removeBg").click()
        // The scripted picture (a gradient) may have no subject: either a new version or the honest notice.
        let rail = MediaUIApp.element(app, "versionRail.item.2"), notice = MediaUIApp.element(app, "editor.notice")
        let deadline = Date().addingTimeInterval(30)
        while !rail.exists && !notice.exists && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertTrue(rail.exists || notice.exists)
    }

    @MainActor
    func testEraseNewVersion() {
        let app = openViewer()
        MediaUIApp.element(app, "editor.erase").click()
        let canvas = MediaUIApp.element(app, "editor.maskCanvas")
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let a = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4))
        a.press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
        MediaUIApp.element(app, "editor.erase.apply").click()
        XCTAssertTrue(MediaUIApp.element(app, "versionRail.item.2").waitForExistence(timeout: 60), "Erase made v2")
    }
}
