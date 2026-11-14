// M7.T15 XCUITest legs of AT-241 c3 and AT-NFR-SEC5 (R-241 AC3; NFR-SEC5). Pending Q-015 (XCUITest automation mode is
// blocked on this Mac). In process: SafeSearchSettingTests + SafeSearchTests (AT-241 c3), InjectionConfirmationTests +
// UntrustedContextRuleTests (AT-NFR-SEC5).
import XCTest

final class SecurityUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.foreground()
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("sec-ui-\(UUID().uuidString)").path
        app.launchArguments += ["-ANTICHAT_DEV_CONTAINER", container, "-SkipOnboarding", "YES",
                                "-DefaultsSuite", "com.antichat.uitest.security"] + extra
        app.launch()
        return app
    }

    /// AT-241 c3: Tools & Connections → Web search shows "Safe search results" switched off on a fresh install, in both
    /// modes (the setting has no mode input).
    @MainActor func testSafeSearchOptionOffByDefault() throws {
        let app = launch()
        app.typeKey(",", modifierFlags: .command)
        app.descendants(matching: .any).matching(identifier: "settings.nav.tools").firstMatch.click()
        // Connections sit below the fold of Tools & Connections; bring them on screen (Q-015 catch-up).
        app.scrollViews.matching(identifier: "settings.detail.tools").firstMatch.scroll(byDeltaX: 0, deltaY: -700)
        let toggle = app.descendants(matching: .any).matching(identifier: "settings.control.safeSearch").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? Int ?? (toggle.value as? String == "1" ? 1 : 0), 0, "Safe search results must be Off by default")
        XCTAssertTrue(app.staticTexts["Safe search results"].exists)
    }

    /// AT-NFR-SEC5 (vq-04 step 13): a page with an embedded instruction (injection-30) read through web search, then a
    /// write call → the ApprovalCard shows the untrusted line and nothing is sent before a click.
    @MainActor func testInjectedPageAsksWithUntrustedLine() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = launch(["-UseScriptedEngine", repo.appendingPathComponent("tools/fixtures/scripts/web-inject.jsonl").path,
                          "-ScriptedWebSearch", "YES",
                          "-ScriptedMCP", repo.appendingPathComponent("fixtures/web/mcp/scripted-server.jsonl").path])
        MCPUI.addTeamChat(app)  // the write call's connection (Q-015 r2: a fresh container has none)
        let composer = app.descendants(matching: .any).matching(identifier: "composerText").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.click(); composer.typeText("Read the tips page and tell the team.\r")
        let deny = app.descendants(matching: .any).matching(identifier: "approveDeny").firstMatch
        XCTAssertTrue(deny.waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "approvalUntrusted").firstMatch.exists)
        // VQ-M10 S-24: an untrusted request never offers a lasting Always allow (PermissionGate.offersAlwaysAllow).
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "approveAlways").firstMatch.exists)
        deny.clickReliably()
    }
}
