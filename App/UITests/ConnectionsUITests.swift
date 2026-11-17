// M7.T06 AT-081 c1 (R-081 AC1; S-21 §7): a fresh container shows no connections and makes no `.mcp` request; adding a
// server with a key through the add sheet (form, then the consent step) puts it under "Connected".
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
        app.descendants(matching: .any).matching(identifier: "settings.nav.connections").firstMatch.click()
        return app
    }

    @MainActor func testNothingConnectsUntilAdded() throws {
        let app = launch()
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'connectionRow.'")).firstMatch.waitForExistence(timeout: 2))
    }

    @MainActor func testAddRemoteWithTokenListsTools() throws {
        let app = launch()
        app.buttons["connections.add"].click()
        let url = app.textFields["connections.url"]
        url.click(); url.typeText("https://chat.example/mcp")
        app.descendants(matching: .any).matching(identifier: "connections.auth.show").firstMatch.click()  // "This tool needs a sign-in"
        app.descendants(matching: .any).matching(identifier: "connections.auth.key").firstMatch.click()  // Paste a key
        let token = app.secureTextFields["connections.token"]
        token.click(); token.typeText("tok-ui")
        app.buttons["connections.check"].click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "mcpConsent").firstMatch.waitForExistence(timeout: 10))
        app.buttons["mcpConsent.allow"].click()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'connectionRow.'")).firstMatch.waitForExistence(timeout: 10))
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
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'connectionRow.'")).firstMatch.waitForExistence(timeout: 2))
    }
}
