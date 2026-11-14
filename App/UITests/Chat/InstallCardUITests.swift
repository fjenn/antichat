// AT-238 UI legs (M2.T24; R-238 AC2/AC3): Photo not installed → a Create image request shows the InstallCard instead
// of an answer → [Install] → progress → the original request re-runs automatically in the same chat and the
// ScriptedImageEngine result appears; `-FakeHardware t1-m2-16` → a video request shows `install.unavailable` with
// "needs 24 GB memory" and no button.
// Committed, not run on this Mac (Q-015: XCUITest cannot start); InstallCardTests (ConversationModel + view, in-process)
// and InstallCardPolicyTests (TurnController) cover the same flow.
import XCTest

final class InstallCardUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    /// The scripted model calls `tool` (create_image / create_video) on a tool-capable chat model: the basic script
    /// only answered "Hello!", so no media tool and no card ever came (Q-015 catch-up).
    private func launch(tool: String, _ extra: [String]) -> XCUIApplication {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-uitest-install-\(UUID().uuidString)")
        let turn = FileManager.default.temporaryDirectory.appendingPathComponent("install-\(UUID().uuidString).jsonl")
        let line = #"{"t":"toolCallDone","id":"call_1","name":"TOOL","args":"{\"prompt\":\"a watercolor fox\"}","delayMs":1}"#
        try? Data((line.replacingOccurrences(of: "TOOL", with: tool) + "\n").utf8).write(to: turn)
        let app = XCUIApplication.foreground()
        app.launchArguments = ["-ANTICHAT_DEV_CONTAINER", container.path, "-ApplePersistenceIgnoreState", "YES",
                               "-SkipOnboarding", "YES", "-UseScriptedEngine", turn.path, "-ChatModel", "chat-9b-q4"] + extra
        app.launch()
        app.activate()
        return app
    }

    @MainActor
    private func send(_ app: XCUIApplication, _ text: String) {
        let input = app.descendants(matching: .any).matching(identifier: "composerText").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.click()
        input.typeText(text)
        input.typeKey(.return, modifierFlags: [])
    }

    @MainActor
    func testInstallThenOriginalRequestReruns() throws {
        let app = launch(tool: "create_image", ["-FakePackState", "photo=absent"])
        send(app, "Draw me a watercolor fox in the snow")
        let card = app.descendants(matching: .any).matching(identifier: "installCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "installCardInstall").firstMatch.exists)
        // [Install] downloads the real Photo pack (6.3 GB) from the release catalog: opt in on a machine meant for it.
        guard ProcessInfo.processInfo.environment["ANTICHAT_UITEST_REAL_INSTALL"] == "1" else {
            throw XCTSkip("install leg downloads the real Photo pack; set TEST_RUNNER_ANTICHAT_UITEST_REAL_INSTALL=1 (InstallCardTests covers the re-run in-process)")
        }
        app.descendants(matching: .any).matching(identifier: "installCardInstall").firstMatch.clickReliably()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "installCardProgress").firstMatch.waitForExistence(timeout: 20))
        let activity = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'activity' AND label CONTAINS[c] 'create_image'")).firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 600), "the original request re-ran with the image tool")
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }

    @MainActor
    func testIneligibleMacShowsReasonWithoutButton() {
        let app = launch(tool: "create_video", ["-FakeHardware", "t1-m2-16"])
        send(app, "Make a short video of waves rolling onto a beach")
        let text = app.descendants(matching: .any).matching(identifier: "installCardText").firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 20))
        XCTAssertTrue(text.displayText.contains("needs 24 GB memory"), text.displayText)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "installCardInstall").firstMatch.exists)
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }
}
