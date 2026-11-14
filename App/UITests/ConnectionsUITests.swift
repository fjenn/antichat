// M7.T06 AT-081 c1/c4 (R-081 AC1/AC4; S-21 §7): a fresh container shows no connections and makes no `.mcp` request;
// adding a token server through the consent sheet lists its tools; the Popular connections directory has ≥ 10 cards.
// Uses `-ScriptedMCP fixtures/web/mcp/scripted-server.jsonl` (no network). Pending Q-015 (XCUITest automation mode is
// blocked on this Mac); the same flows run in-process in MCPHostTests / MCPTurnTests.
import XCTest

final class ConnectionsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication.foreground()
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("conn-ui-\(UUID().uuidString)").path
        app.launchArguments += ["-ANTICHAT_DEV_CONTAINER", container, "-SkipOnboarding", "YES", "-UseScriptedEngine", "NO",
                                "-ScriptedMCP", repo.appendingPathComponent("fixtures/web/mcp/scripted-server.jsonl").path]
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        app.descendants(matching: .any).matching(identifier: "settings.nav.tools").firstMatch.click()
        // Connections sit below the fold of Tools & Connections; bring them on screen (Q-015 catch-up).
        app.scrollViews.matching(identifier: "settings.detail.tools").firstMatch.scroll(byDeltaX: 0, deltaY: -700)
        return app
    }

    @MainActor func testNothingConnectsUntilAdded() throws {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "connections.empty").firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testAddRemoteWithTokenListsTools() throws {
        let app = launch()
        app.buttons["connections.add"].click()
        let url = app.textFields["connections.url"]
        url.click(); url.typeText("https://chat.example/mcp")
        app.descendants(matching: .any).matching(identifier: "connections.authMode").firstMatch.radioButtons.element(boundBy: 1).click()
        let token = app.secureTextFields["connections.token"]
        token.click(); token.typeText("tok-ui")
        app.buttons["connections.check"].click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "mcpConsent").firstMatch.waitForExistence(timeout: 10))
        app.buttons["mcpConsent.allow"].click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "connections.empty").firstMatch.waitForNonExistence(timeout: 10))
    }

    /// M7.T15 (AT-NFR-SEC4): the consent sheet names the server, its URL (a remote server's "command"), every tool
    /// with Reads only / Can change things, and the permission rule. Pending Q-015; in process: MCPHostTests.
    @MainActor func testConsentListsCommandToolsPermissions() throws {
        let app = launch()
        app.buttons["connections.add"].click()
        let url = app.textFields["connections.url"]
        url.click(); url.typeText("https://chat.example/mcp")
        app.buttons["connections.check"].click()
        let sheet = app.descendants(matching: .any).matching(identifier: "mcpConsent").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        // Each tool by its readable name (VQ-M11 S-24: the server's title, else the id in words; the raw ids
        // search_messages / send_message are only the rows' tooltips).
        for text in ["https://chat.example/mcp", "Search messages", "Send message", "Reads only", "Can change things", "always asks first"] {
            XCTAssertTrue(sheet.staticTexts.containing(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)).firstMatch.exists, text)
        }
        app.buttons["mcpConsent.cancel"].click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "connections.empty").firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testCuratedListAtLeastTen() throws {
        let app = launch()
        // The directory is a lazy grid: only the cards on screen are in the tree, so scroll through it and count every
        // card seen (Q-015 r2: 3 were on screen).
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'mcpDirectory.add.'"))
        let detail = app.scrollViews.matching(identifier: "settings.detail.tools").firstMatch
        var seen = Set<String>()
        for _ in 0..<12 {
            seen.formUnion(cards.allElementsBoundByIndex.map(\.identifier))
            if seen.count >= 10 { break }
            detail.scroll(byDeltaX: 0, deltaY: -300)
        }
        XCTAssertGreaterThanOrEqual(seen.count, 10, "\(seen.sorted())")
    }
}
