// M4.T10 task check (no AT owned; AT-017/AT-277 in M6.T13). Runs on the Debug artifacts host
// (`-ArtifactsHarness <dir>`) over a temp folder holding the six card fixtures. XCUITest can't start on the build
// Mac (Q-015): the same actions are covered in-process by FileCardViewModelTests / DragOutProviderTests; cross-app
// drag to Finder and Mail is vq-05 step 21 (computer use).
import AppKit
import XCTest

final class FileCardTests: XCTestCase {
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
    private func launchOnCardSet() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("filecards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for rel in ["docs/pdf/text-10p.pdf", "docs/office/report.docx", "docs/office/budget.xlsx", "docs/office/deck.pptx",
                    "docs/office/notes.csv", "images/photos-cc0/001.jpg"] {
            let src = Self.fixtures.appendingPathComponent(rel)
            try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent(src.lastPathComponent))
        }
        app = XCUIApplication.antichat(["-ArtifactsHarness", dir.path])
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["artifactsHarness"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testOpenSaveRevealOnFixtures() throws {
        try launchOnCardSet()
        let cards = app.descendants(matching: .any).matching(identifier: "fileCard")
        XCTAssertEqual(cards.count, 6)
        for i in 0..<cards.count {
            let card = cards.element(boundBy: i)
            XCTAssertTrue(card.buttons["fileCardOpen"].isEnabled)
            card.descendants(matching: .any)["fileCardMore"].clickReliably()
            XCTAssertTrue(app.menuItems["fileCardSaveAs"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.menuItems["fileCardReveal"].exists)
            app.typeKey(.escape, modifierFlags: [])
            // The menu is closed before the next card's ⋯ is clicked (a click while it is open only closes it).
            XCTAssertTrue(app.menuItems["fileCardSaveAs"].waitForNonExistence(timeout: 5), "menu closes on Escape")
        }
        // Save As opens a sheet with the display name prefilled.
        let first = cards.element(boundBy: 0)
        first.descendants(matching: .any)["fileCardMore"].clickReliably()
        app.menuItems["fileCardSaveAs"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.sheets.firstMatch.buttons["Cancel"].click()
    }

    @MainActor
    func testQuickLookSpace() throws {
        try launchOnCardSet()
        // M4.T11: the harness has a side panel, so a click opens the card in the panel and Space on the focused card
        // keeps Quick Look (FileCard `onOpenInPanel`; M4.T10 step 2). Q-015 r4: the test predates the panel and
        // expected the click itself to open Quick Look.
        let card = app.descendants(matching: .any).matching(identifier: "fileCard")
            .matching(NSPredicate(format: "label BEGINSWITH 'text-10p'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.click()
        XCTAssertTrue(app.descendants(matching: .any)["sidePanel"].waitForExistence(timeout: 5), "click opens the side panel")
        app.typeKey(" ", modifierFlags: [])
        let preview = app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'QLPreview' OR title CONTAINS[c] 'text-10p' OR title == 'Quick Look'"))  // the panel's title on macOS 26
        XCTAssertTrue(preview.firstMatch.waitForExistence(timeout: 10), "Space opens Quick Look")
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(preview.firstMatch.waitForNonExistence(timeout: 10), "Space closes Quick Look")
    }
}
