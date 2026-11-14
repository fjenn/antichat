// M4.T11 task check (no AT owned; AT-016 in M6.T13) on the Debug artifacts host (`-ArtifactsHarness <dir>`):
// click a card → panel opens; version switch; Edit selection; resize; × closes. XCUITest can't start on the build
// Mac (Q-015): SidePanelModelTests / SidePanelTests (in-process windows) cover the same behaviour.
import AppKit
import XCTest

final class SidePanelTests: XCTestCase {
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

    @MainActor
    private func launch() throws {
        let fx = FileCardTests.fixtures
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sidepanel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdf = fx.appendingPathComponent("docs/pdf/text-10p.pdf")
        try FileManager.default.copyItem(at: pdf, to: dir.appendingPathComponent("report.pdf"))
        try FileManager.default.copyItem(at: pdf, to: dir.appendingPathComponent("report.v2.pdf"))
        try FileManager.default.copyItem(at: fx.appendingPathComponent("images/photos-cc0/001.jpg"),
                                         to: dir.appendingPathComponent("photo.jpg"))
        // The panel width is remembered in the app domain, so each run started from where the last drag left it
        // (down to the 320 pt minimum); the argument domain pins the start to the default 480 pt.
        app = XCUIApplication.antichat(["-ArtifactsHarness", dir.path, "-sidePanel.width.artifactsHarness", "480"])
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["artifactsHarness"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testOpenSwitchVersionEditSelectionClose() throws {
        try launch()
        let any = app.descendants(matching: .any)
        any.matching(identifier: "fileCard").element(boundBy: 1).click()  // report.pdf
        XCTAssertTrue(any["sidePanel"].waitForExistence(timeout: 5))
        any["panelVersionPicker"].clickReliably()
        app.menuItems["panelVersion1"].clickReliably()
        // Q-015 r4: PDFView exposes its scroll view, not itself, so its identifier never reaches accessibility.
        let pdf = any["panelPDF"].exists ? any["panelPDF"] : any["sidePanel"].scrollViews.firstMatch
        pdf.staticTexts.firstMatch.doubleClick()
        XCTAssertTrue(any["panelEditSelection"].waitForExistence(timeout: 5))
        any["panelEditSelection"].clickReliably()
        XCTAssertTrue((any["harnessPrefill"].value as? String ?? any["harnessPrefill"].displayText).hasPrefix("> "))
        let resize = any["sidePanelResize"]
        let before = any["sidePanel"].frame.width
        let start = resize.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // Round 65 (f5326cb5d): with minChatWidth 480 the harness window has no room to widen the panel, so the
        // handle is proven by narrowing it (a drag to the right).
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 120, dy: 0)))
        XCTAssertLessThan(any["sidePanel"].frame.width, before - 60)
        any["panelClose"].clickReliably()
        XCTAssertTrue(any["sidePanel"].waitForNonExistence(timeout: 5))
    }
}
