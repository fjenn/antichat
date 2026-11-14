// M7.T14 AT-267 / AT-268 (R-267 AC1, R-268 AC1–AC3; S-21 §7, S-25 offline): the Tools page lists every tool with a
// switch, connector tools carry Always allow / Ask / Block, "+" → Tools › switches a tool for this chat only, Tool
// access warns on T0–T2, and offline the web chip shows "Offline" while no online schema reaches the prompt.
// Pending Q-015 (XCUITest automation mode is blocked on this Mac); the same behaviour runs in process in
// ToolsPageModelTests (UI module), OnlineToolGateTests and ToolSelectorTests (Harness).
import XCTest

final class ToolsPageUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.foreground()
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("tools-ui-\(UUID().uuidString)").path
        app.launchArguments += ["-ANTICHAT_DEV_CONTAINER", container, "-SkipOnboarding", "YES", "-DefaultsSuite", "com.antichat.uitest.toolspage", "-FreshDefaultsSuite", "YES",
                                "-ScriptedMCP", repo.appendingPathComponent("fixtures/web/mcp/scripted-server.jsonl").path,
                                // "+" → Tools / Web search are offered only to a model that takes tools (D-023 a); a
                                // fresh container's starter is chat-only, so the rows were never listed (Q-015 r4).
                                "-ChatModel", "chat-9b-q4"] + extra
        app.launch()
        return app
    }

    @MainActor private func openToolsSettings(_ app: XCUIApplication, toConnections: Bool = true) {
        app.typeKey(",", modifierFlags: .command)
        app.descendants(matching: .any).matching(identifier: "settings.nav.tools").firstMatch.click()
        // Connections sit below the fold of Tools & Connections; bring them on screen (Q-015 catch-up). The built-in
        // rows (Tool access and its warning) are above it: scrolled away, the form leaves rows off screen out of the tree.
        if toConnections { app.scrollViews.matching(identifier: "settings.detail.tools").firstMatch.scroll(byDeltaX: 0, deltaY: -700) }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// AT-268 c1: Web search, Create image, Create video, Create files, Run code, Memory, each with a switch.
    @MainActor func testEveryToolListedWithSwitch() throws {
        let app = launch()
        openToolsSettings(app)
        for id in ["webSearch", "toolImage", "toolVideo", "createFiles", "runCode", "toolMemory"] {  // M6 rows keep their ids (createFiles; Run code is a picker)
            XCTAssertTrue(element(app, "settings.control.\(id)").waitForExistence(timeout: 5), id)
        }
        XCTAssertTrue(element(app, "settings.control.toolAccess").exists)
    }

    /// AT-268 c1: a connection expands to its tools, each with on/off and Always allow / Ask / Block.
    @MainActor func testConnectorToolPermissions() throws {
        let app = launch()
        openToolsSettings(app)
        app.buttons["connections.add"].click()
        let url = app.textFields["connections.url"]
        url.click(); url.typeText("https://chat.example/mcp")
        app.buttons["connections.check"].click()
        XCTAssertTrue(element(app, "mcpConsent").waitForExistence(timeout: 10))
        app.buttons["mcpConsent.allow"].click()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'connectionRow.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let perm = element(app, "connection.perm.send_message")
        XCTAssertTrue(perm.waitForExistence(timeout: 5))
        perm.click()
        for title in ["Always allow", "Ask", "Block"] { XCTAssertTrue(app.menuItems[title].exists, title) }
    }

    /// AT-268 c2: "+" → Tools lists the same tools; turning Create image off in chat A leaves Settings and chat B on.
    @MainActor func testPlusMenuPerChatDoesNotChangeGlobal() throws {
        let app = launch(["-FakeInstalledPacks", "photo,video", "-UseScriptedEngine", "basic"])
        element(app, "composerAdd").click()
        element(app, "addRow.tools").click()
        for g in ["web", "image", "video", "files", "code", "memory"] {
            XCTAssertTrue(element(app, "toolsMenu.\(g)").waitForExistence(timeout: 5), g)
        }
        element(app, "toolsMenu.image").click()
        app.typeKey(.escape, modifierFlags: [])
        // Q-015 r4: chat A must exist before ⌘N. An unsent new chat is not a chat yet (its chips are saved on the first
        // send), so ⌘N stayed on the same composer and "chat B" still had A's switch off.
        let input = element(app, "composerText")
        input.click()
        input.typeText("Hello\r")
        XCTAssertTrue(element(app, "assistantText").waitForExistence(timeout: 20))
        app.typeKey("n", modifierFlags: .command)  // chat B
        element(app, "composerAdd").click()
        element(app, "addRow.tools").click()
        XCTAssertEqual(element(app, "toolsMenu.image").value as? Int, 1)
        app.typeKey(.escape, modifierFlags: [])
        openToolsSettings(app)
        XCTAssertEqual(element(app, "settings.control.toolImage").value as? Int, 1)
    }

    /// AT-268 c3: default "Load tools when needed"; "Always offer all" warns on T1, not on T3.
    @MainActor func testToolAccessWarnsOnT0toT2() throws {
        for (tier, warns) in [("T1", true), ("T3", false)] {
            let app = launch(["-FakeHardware", tier])
            openToolsSettings(app, toConnections: false)
            let picker = element(app, "settings.control.toolAccess")
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            XCTAssertFalse(element(app, "settings.toolAccess.warning").exists)
            picker.click()
            app.menuItems["Always offer all enabled tools"].click()
            XCTAssertEqual(element(app, "settings.toolAccess.warning").waitForExistence(timeout: 3), warns, tier)
            app.terminate()
        }
    }

    /// AT-267: Offline only → the Web search chip shows "Offline" and "+" → Tools has web search off and disabled.
    @MainActor func testOfflineChipsAndNoSchemas() throws {
        let dump = FileManager.default.temporaryDirectory.appendingPathComponent("at267-ui-\(UUID().uuidString)").path
        let app = launch(["-OfflineOnly", "YES", "-DumpPrompts", dump, "-UseScriptedEngine", "YES"])
        element(app, "composerAdd").click()
        element(app, "addRow.web").click()
        // Q-015 r5: the chip's suffix is the text "· Offline" (net.offlineShort) with its own id; a static text's words
        // are its AX value on macOS, so `staticTexts["Offline"]` (label / id match) could never find it.
        let offline = element(app, "toolChipOffline.web")
        XCTAssertTrue(offline.waitForExistence(timeout: 5), "the Web search chip, offline")
        XCTAssertTrue(offline.displayText.contains("Offline"), offline.displayText)
        element(app, "composerAdd").click()
        element(app, "addRow.tools").click()
        XCTAssertFalse(element(app, "toolsMenu.web").isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        let field = element(app, "composerText")
        field.click(); field.typeText("what's new today?\r")
        sleep(3)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dump)) ?? []
        XCTAssertFalse(files.isEmpty)
        for f in files {
            let text = (try? String(contentsOfFile: dump + "/" + f, encoding: .utf8)) ?? ""
            for name in ["web_search", "read_url", "team_chat_", "composio_"] { XCTAssertFalse(text.contains("\"name\":\"\(name)"), name) }
        }
    }
}
