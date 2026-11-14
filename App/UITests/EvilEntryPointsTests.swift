// R-210 AC1 (journey J07): every entry point to an Evil chat works in a fresh container with Evil on
// (`-FakeEvilEnabled YES`, as after onboarding's Evil step): ⇧⌘E, File › New Evil Chat and the composer's
// Normal | Evil switch. Each leg starts from the state a user is in: right after launch (nothing clicked), and after
// a Normal turn (the M9.T05 PR1 journey loop order). Self-contained launch helpers (no shared support edits).
import AppKit
import XCTest

final class EvilEntryPointsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func script(_ name: String) -> String {
        let f = repoRoot.appendingPathComponent("fixtures/scripts/\(name)")
        if FileManager.default.fileExists(atPath: f.path) { return f.path }
        return repoRoot.appendingPathComponent("tools/fixtures/scripts/\(name)").path
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication.foreground()  // Q-015 r3: the shared lifecycle (each test ends its own app)
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("antichat-uitest-evil-\(UUID().uuidString)", isDirectory: true)
        app.launchArguments = ["-ANTICHAT_DEV_CONTAINER", container.path, "-ApplePersistenceIgnoreState", "YES",
                               "-SkipOnboarding", "YES", "-OfflineOnly", "YES",
                               "-UseScriptedEngine", Self.script("regen.jsonl"), "-FakeEvilEnabled", "YES"]
        app.launchEnvironment["ANTICHAT_BACKGROUND"] = "0"  // a real foreground app (BackgroundRun off)
        app.launch()
        app.activate()
        XCTAssertTrue(window(app).waitForExistence(timeout: 30), "no main window")
        return app
    }

    @MainActor
    private func window(_ app: XCUIApplication) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'main-'")).firstMatch
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// The Evil chrome of a new Evil chat: the frame, the badge by the title and the Evil empty state.
    @MainActor
    private func assertEvilShown(_ app: XCUIApplication, _ how: String, file: StaticString = #filePath, line: UInt = #line) {
        let shown = element(app, "evilHeadline").waitForExistence(timeout: 5)
        if !shown {
            print("UITREE-BEGIN \(how)\n\(app.debugDescription)\nUITREE-END")
            add(XCTAttachment(screenshot: app.screenshot()))
        }
        XCTAssertTrue(shown, "\(how): no Evil empty state", file: file, line: line)
        XCTAssertTrue(element(app, "evil.frame").exists, "\(how): no Evil frame", file: file, line: line)
        XCTAssertTrue(element(app, "evil.badge").exists, "\(how): no Evil badge", file: file, line: line)
    }

    @MainActor
    private func sendNormalTurn(_ app: XCUIApplication) {
        let input = window(app).descendants(matching: .any).matching(identifier: "composerText").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.click()
        input.typeText("Tell me about a quiet harbour town")
        input.typeKey(.return, modifierFlags: [])
        let stop = window(app).descendants(matching: .any).matching(identifier: "stop").firstMatch
        _ = stop.waitForExistence(timeout: 10)
        let end = Date().addingTimeInterval(60)
        while stop.exists, Date() < end { usleep(100_000) }
    }

    @MainActor
    private func fileMenuNewEvilChat(_ app: XCUIApplication) {
        app.menuBarItems["File"].click()
        let item = app.menuBarItems["File"].menuItems["New Evil Chat"]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "File › New Evil Chat missing")
        XCTAssertTrue(item.isEnabled, "File › New Evil Chat disabled")
        item.click()
    }

    @MainActor
    private func composerEvilSegment(_ app: XCUIApplication) {
        let segment = window(app).descendants(matching: .any).matching(identifier: "modeSwitch")
            .descendants(matching: .radioButton).matching(NSPredicate(format: "label == 'Evil'")).firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 5), "the composer's Evil segment")
        segment.click()
    }

    // MARK: right after launch

    @MainActor func testShortcutAtLaunch() {
        let app = launch()
        app.typeKey("e", modifierFlags: [.command, .shift])
        assertEvilShown(app, "⇧⌘E at launch")
    }

    @MainActor func testFileMenuAtLaunch() {
        let app = launch()
        fileMenuNewEvilChat(app)
        assertEvilShown(app, "File menu at launch")
    }

    @MainActor func testComposerSwitchAtLaunch() {
        let app = launch()
        composerEvilSegment(app)
        assertEvilShown(app, "composer switch at launch")
    }

    // MARK: after a Normal turn (PR1 journey order: ⌘N, send, then the Evil chat)

    @MainActor func testShortcutAfterNormalTurn() {
        let app = launch()
        app.typeKey("n", modifierFlags: .command)
        sendNormalTurn(app)
        app.typeKey("e", modifierFlags: [.command, .shift])
        assertEvilShown(app, "⇧⌘E after a turn")
    }

    @MainActor func testFileMenuAfterNormalTurn() {
        let app = launch()
        app.typeKey("n", modifierFlags: .command)
        sendNormalTurn(app)
        fileMenuNewEvilChat(app)
        assertEvilShown(app, "File menu after a turn")
    }

    @MainActor func testComposerSwitchAfterNewChat() {
        let app = launch()
        app.typeKey("n", modifierFlags: .command)
        sendNormalTurn(app)
        app.typeKey("n", modifierFlags: .command)
        composerEvilSegment(app)
        assertEvilShown(app, "composer switch in a new chat after a turn")
    }
}
