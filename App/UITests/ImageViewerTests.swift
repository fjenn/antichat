// AT-032 (R-032, M4.T12): the picture's card actions, the variant strip, and the full-window viewer (zoom, Save As,
// Copy, Show in Finder, the version rail, Esc back to the same scroll position).
// Committed, not run on this Mac (Q-015: XCUITest cannot start). In-process legs that run today:
// ImageResultCardTests (UI module: actions, viewer target, version rail order, snapshots light/dark/Evil/Incognito).
// testVariantStripSelects needs ScriptedImageEngine `count` 4, i.e. variants (AT-288), which D-026 moved to M11: it
// is written against the strip and stays pending with M4.T14.
import AppKit
import XCTest

final class ImageViewerTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func finishedPicture(_ extra: [String] = [], chatScript: String? = nil) -> XCUIApplication {
        let app = MediaUIApp.launch(chatScript: chatScript, extra)
        MediaUIApp.send(app, "Draw me a lighthouse at dusk")
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard.result").waitForExistence(timeout: 60))
        return app
    }

    @MainActor
    func testCardActions() {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("card-\(UUID().uuidString).png")
        let app = finishedPicture(["-SaveImageFile", out.path])
        MediaUIApp.element(app, "imageJobCard.result").hover()
        let save = MediaUIApp.element(app, "imageJobCard.save")
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.click()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: out.path), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        MediaUIApp.element(app, "imageJobCard.more").clickReliably()
        for id in ["imageResult.saveAs", "imageResult.copy", "imageResult.reveal", "imageJobCard.showPrompt", "imageResult.open"] {
            XCTAssertTrue(MediaUIApp.element(app, id).exists, id)
        }
        MediaUIApp.element(app, "imageResult.copy").click()
        XCTAssertNotNil(NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff))
    }

    @MainActor
    func testVariantStripSelects() throws {
        throw XCTSkip("variants (count > 1, AT-288) are M11 (D-026); the strip is covered by ImageResultCardTests")
    }

    @MainActor
    func testViewerZoomSaveCopyReveal() {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-\(UUID().uuidString).png")
        let app = finishedPicture(["-SaveImageFile", out.path])
        MediaUIApp.element(app, "imageJobCard.result").clickReliably()
        let viewer = MediaUIApp.element(app, "imageViewer")
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        let zoom = MediaUIApp.element(app, "imageViewer.zoom")
        MediaUIApp.element(app, "imageViewer.zoomIn").click()
        app.typeKey("+", modifierFlags: .command)
        app.typeKey("-", modifierFlags: .command)
        MediaUIApp.element(app, "imageViewer.fit").click()
        XCTAssertTrue(zoom.exists)
        MediaUIApp.element(app, "imageViewer.save").click()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: out.path), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        MediaUIApp.element(app, "imageViewer.copy").click()
        XCTAssertNotNil(NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff))
        // Q-015 r5: the pointer still rests on Copy, whose `.help` tooltip (its own window) can cover its neighbour;
        // move off the toolbar first, as a user's pointer would, then check Show in Finder.
        zoom.hover()
        let reveal = MediaUIApp.element(app, "imageViewer.reveal")
        let end = Date().addingTimeInterval(3)
        while !reveal.isHittable, Date() < end { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(reveal.isHittable)
    }

    @MainActor
    func testVersionRailListsVersions() {
        // Two versions of one picture: the scripted turn edits the first result (edit_image, M4.T13's tool).
        // Q-015 r4: the default script has no edit_image turn (the second send replayed create_image and was skipped as
        // a repeat), and the result is exposed as a button (it opens the viewer), not an image: any element type.
        // fix/overlay-field-focus: ImageEditTests.editChat (the old [create][edit] script never edited: see there).
        let app = finishedPicture(chatScript: ImageEditTests.editChat)
        let results = app.descendants(matching: .any).matching(identifier: "imageJobCard.result")
        MediaUIApp.send(app, "Make the sky purple")
        XCTAssertTrue(results.element(boundBy: 1).waitForExistence(timeout: 60))
        results.element(boundBy: 1).clickReliably()
        let rail = MediaUIApp.element(app, "versionRail")
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        let first = MediaUIApp.element(app, "versionRail.item.2"), second = MediaUIApp.element(app, "versionRail.item.1")
        XCTAssertTrue(first.exists && second.exists)
        XCTAssertLessThan(first.frame.minY, second.frame.minY, "newest at the top")
    }

    @MainActor
    func testEscReturnsToScrollPosition() {
        let app = finishedPicture()
        let transcript = MediaUIApp.element(app, "conversation")
        let card = MediaUIApp.element(app, "imageJobCard.result")
        let before = card.frame
        card.click()
        XCTAssertTrue(MediaUIApp.element(app, "imageViewer").waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(MediaUIApp.element(app, "imageViewer").waitForExistence(timeout: 2))
        XCTAssertTrue(transcript.exists)
        XCTAssertEqual(card.frame.minY, before.minY, accuracy: 1, "same scroll position")
    }
}
