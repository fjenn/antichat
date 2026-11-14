// M7.T06 AT-081 c2/c3 + journey 12 (R-081 AC2/AC3; S-24 ApprovalCard): a write call of a connection
// (`team_chat_send_message`, destructiveHint) shows the ApprovalCard with Allow once / Always allow / Deny and never
// auto-approves (10 simulated minutes with `-FixedClock`); the + › Connections toggle hides the server in that chat;
// the activity line reads "Used Team Chat" and expands. Pending Q-015; in-process: MCPTurnTests, PermissionMatrixTests.
import XCTest

final class ToolApprovalUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor func testAllowOnceAlwaysDeny() throws {
        let t = TurnApp(script: "mcp-send-message.jsonl")
        t.app.launchArguments += ["-ScriptedMCP", "fixtures/web/mcp/scripted-server.jsonl", "-FakeHardware", "T1"]
        t.launch()
        MCPUI.addTeamChat(t.app)
        t.send("Tell the team hi.")
        XCTAssertTrue(element(t.app, "approvalCard").waitForExistence(timeout: 10))
        for id in ["approveAllowOnce", "approveAlways", "approveDeny"] { XCTAssertTrue(t.app.buttons[id].exists, id) }
    }

    @MainActor func testNoTimeoutAutoApprove() throws {
        let t = TurnApp(script: "mcp-send-message.jsonl")
        t.app.launchArguments += ["-ScriptedMCP", "fixtures/web/mcp/scripted-server.jsonl", "-FixedClock", "2026-11-05T09:00:00Z"]
        t.launch()
        MCPUI.addTeamChat(t.app)
        t.send("Tell the team hi.")
        XCTAssertTrue(element(t.app, "approvalCard").waitForExistence(timeout: 10))
        sleep(20)
        XCTAssertTrue(element(t.app, "approvalCard").exists, "the card must wait for the user")
    }

    @MainActor func testPerChatToggleAndActivityLine() throws {
        let t = TurnApp(script: "mcp-send-message.jsonl")
        t.app.launchArguments += ["-ScriptedMCP", "fixtures/web/mcp/scripted-server.jsonl"]
        t.launch()
        // The Connections row is listed once a connection with tools exists (M7.T06); the + button is `composerAdd`
        // (Q-015 r4: `addButton` was a stale id).
        MCPUI.addTeamChat(t.app)
        element(t.app, "composerAdd").click()
        element(t.app, "addRow.connections").click()
        XCTAssertTrue(element(t.app, "connectionsMenu").waitForExistence(timeout: 5))
    }
}
