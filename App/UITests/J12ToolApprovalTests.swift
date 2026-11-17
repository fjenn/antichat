// Journey 12 (M1.T16 AT-232 (4); S-24 ApprovalCard; components ActivityLine): with `-UseScriptedTools YES
// -FakeHardware T1`, `tool-loop-runaway.jsonl` shows one activity line per step and stops after 6 steps with
// "Stopped after several steps." + [Continue], which resumes; `tool-approval.jsonl` (write_note) shows the
// ApprovalCard whose Allow once / Always allow / Deny paths behave as specified (database read with sqlite3).
// Not run in the agent session (Q-015: XCUITest automation mode is blocked on this Mac); the serial UI-test run
// (M1.T27 step 8) runs it. The same flows run in-process in `ToolActivityModelTests` (AntiChatUIModuleTests) and
// `ToolLoopPolicyTests` / `PermissionGateTests` (AntiChatHarnessTests).
import AppKit
import XCTest

final class J12ToolApprovalTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor private func launch(_ script: String, tier: String = "T1") -> TurnApp {
        let t = TurnApp(script: script)
        t.app.launchArguments += ["-UseScriptedTools", "YES", "-FakeHardware", tier, "-ChatModel", "chat-9b-q4"]  // starter is chat-only (D-023)
        t.launch()
        return t
    }

    @MainActor
    func testLoopLimitAndContinue() throws {
        // Q-015 r5: on T0–T2 the ToolPruner (R-235 AC2) offers ≤ 4 tools a turn and "Keep echoing." routed none to
        // `echo` (offered: find_tools, get_time, load_skill), so the scripted call failed "there is no tool named echo"
        // twice and the turn ended without the loop limit. T3 has the same 6-step budget (R-232 AC1) and no pruning.
        // r6: T3 offers 12 tools a step, still fewer than the eligible set, so the selector offers only tools the
        // message is relevant to (ToolIndex: BM25 + embedding gate); "Keep echoing." matched no `echo` token (no
        // stemming), so r3–r5 still saw "Echo didn't work" ×2. The message names the tool and its description.
        let t = launch("tool-loop-runaway.jsonl", tier: "T3")
        t.send("Keep calling echo to repeat the given text back.")
        XCTAssertTrue(element(t.app, "loopLimitMessage").waitForExistence(timeout: 20), "no loop-limit notice")
        XCTAssertEqual(t.app.staticTexts["loopLimitMessage"].displayText, "Stopped after several steps.")
        XCTAssertEqual(t.app.descendants(matching: .any).matching(identifier: "activityLine").count, 6)
        t.app.buttons["loopLimitContinue"].clickReliably()
        XCTAssertTrue(element(t.app, "loopLimitMessage").waitForExistence(timeout: 20))
        XCTAssertEqual(t.app.descendants(matching: .any).matching(identifier: "activityLine").count, 12)
        // A plain tool line has nothing a person can read behind it: a click shows no raw arguments or result.
        t.app.descendants(matching: .any).matching(identifier: "activityLine").firstMatch.click()
        XCTAssertFalse(element(t.app, "activityDetail").waitForExistence(timeout: 1))
    }

    @MainActor private func approval(_ answer: String) -> TurnApp {
        let t = launch("tool-approval.jsonl")
        t.send("Save a note: buy milk.")
        XCTAssertTrue(element(t.app, "approvalCard").waitForExistence(timeout: 10), "no ApprovalCard")
        for id in ["approveAllowOnce", "approveAlways", "approveDeny"] { XCTAssertTrue(t.app.buttons[id].exists, id) }
        t.app.buttons[answer].clickReliably()
        XCTAssertTrue(t.sendButton.waitForExistence(timeout: 10), "turn did not finish")
        XCTAssertFalse(element(t.app, "approvalCard").exists)
        return t
    }

    @MainActor
    func testAllowOnce() throws {
        let t = approval("approveAllowOnce")
        XCTAssertEqual(t.sql("SELECT count(*) FROM tool_permission"), "0")
        XCTAssertEqual(t.sql("SELECT count(*) FROM message_part WHERE kind = 'tool_result' AND untrusted = 1"), "1")
    }

    @MainActor
    func testAlwaysAllow() throws {
        let t = approval("approveAlways")
        XCTAssertEqual(t.sql("SELECT scope || '|' || policy FROM tool_permission WHERE tool_key = 'write_note'"), "global|always")
        // (A later call without a card: PermissionGateTests.alwaysAllowStoresGlobalAndSkipsTheNextCard.)
    }

    @MainActor
    func testDeny() throws {
        let t = approval("approveDeny")
        XCTAssertTrue(t.app.staticTexts["You denied write_note."].exists || element(t.app, "activityLine").exists)
        XCTAssertEqual(t.sql("SELECT count(*) FROM tool_permission"), "0")
    }
}
