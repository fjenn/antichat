// AT-007 (M1.T15, R-007): Think harder and the reasoning display, XCUITest form. ScriptedEngine `reasoning.jsonl`
// (≈ 6 s of reasoning, then the answer) and `no-reasoning.jsonl` (caps `reasoning=false`).
// Not run in the agent session (Q-015 automation mode; Q-023/Q-024/Q-025 shared desktop / worktree sandbox); the
// in-process form is `ThinkHarderHostTests` (AntiChatUIModuleTests) on the same window stack. The serial UI-test run
// (M1.T27 step 8) runs this class.
import XCTest

final class ThinkHarderTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// (1) the toggle is there; no catalog model id or family name anywhere in the window.
    @MainActor
    func testToggleAndNoModelNames() throws {
        let t = TurnApp(script: "reasoning.jsonl")
        t.launch()
        XCTAssertTrue(t.app.buttons["thinkHarder"].waitForExistence(timeout: 5))
        let labels = t.window.descendants(matching: .any).allElementsBoundByIndex.map { "\($0.displayText) \($0.identifier)" }
            .joined(separator: "\n").lowercased()
        for name in ["chat-0.8b", "chat-2b", "chat-9b-q4", "chat-35b-q4", "chat-g26", "evil-9b", "qwen", "gemma",
                     "mlx-community"] {
            XCTAssertFalse(labels.contains(name), "model name in the UI: \(name)")
        }
    }

    /// (2) no line at 1.5 s; "Thinking… N s" at 2.5 s, ticking; collapses to "Thought for N s" (N ≈ 6) and expands.
    @MainActor
    func testThinkingLineTimingAndCollapse() throws {
        let t = TurnApp(script: "reasoning.jsonl")
        t.launch()
        t.app.buttons["thinkHarder"].click()
        // Q-015 r4: the clock starts when Return lands. Started before `send`, it also counted the ~1.5 s XCUITest spends
        // clicking and typing, so at "2.5 s" the reply was under a second old and still showed its pending dot.
        t.send("What is the answer?")
        let sent = Date()
        let line = t.app.buttons["reasoningLine"]
        while Date().timeIntervalSince(sent) < 1.5 { usleep(20_000) }
        XCTAssertFalse(line.exists, "thinking line before 2 s")
        while Date().timeIntervalSince(sent) < 2.5 { usleep(20_000) }
        XCTAssertTrue(line.waitForExistence(timeout: 0.5))
        let first = line.displayText
        XCTAssertTrue(first.hasPrefix("Thinking…"), first)
        sleep(1)
        XCTAssertNotEqual(line.displayText, first, "counter did not tick")
        XCTAssertTrue(t.sendButton.waitForExistence(timeout: 15))
        let done = line.displayText
        let n = Int(done.replacingOccurrences(of: "Thought for ", with: "").replacingOccurrences(of: " s", with: "")) ?? -1
        XCTAssertTrue((5...7).contains(n), "collapsed label: \(done)")
        line.click()
        XCTAssertTrue(element(t.app, "reasoningText").waitForExistence(timeout: 2))
        add(XCTAttachment(screenshot: t.window.screenshot()))
        TurnApp.evidence("AT-007", ["case": "testThinkingLineTimingAndCollapse", "thoughtSeconds": n])
    }

    /// (3) a model without a thinking mode: the tooltip is `think.tip.preset`.
    @MainActor
    func testPresetTooltipWithoutReasoning() throws {
        let t = TurnApp(script: "no-reasoning.jsonl")
        let log = AXRead.enable(t.app, ids: ["thinkHarder"])
        t.launch()
        let toggle = t.app.buttons["thinkHarder"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        t.send("Hello")
        XCTAssertTrue(t.sendButton.waitForExistence(timeout: 10))
        toggle.hover()
        let tip = "This model doesn't have a thinking mode. Think harder uses a slower, more careful setting."
        // Q-015 r5: the `.help` tooltip is the toggle's AXHelp (what VoiceOver reads as the hint and the hover shows);
        // XCUITest exposes neither, so the app's DEBUG probe logs it (AXRead).
        let help = AXRead.wait(log, identifier: "thinkHarder", .help, equals: tip)
        XCTAssertTrue(help == tip || t.app.staticTexts[tip].exists || toggle.title == tip || (toggle.value as? String) == tip,
                      "tooltip: AXHelp = \(help ?? "nil")")
    }

    /// (4) on in chat A, off in chat B; switching chats and relaunching restores both.
    @MainActor
    func testPerChatPersistence() throws {
        let t = TurnApp(script: "no-reasoning.jsonl")
        t.launch()
        let toggle = t.app.buttons["thinkHarder"]
        toggle.click()
        t.send("Chat A")
        XCTAssertTrue(t.sendButton.waitForExistence(timeout: 10))
        t.app.typeKey("n", modifierFlags: .command)
        XCTAssertFalse(toggle.isSelected, "a new chat starts with Think harder off")
        t.send("Chat B")
        XCTAssertTrue(t.sendButton.waitForExistence(timeout: 10))
        XCTAssertEqual(t.sql("SELECT GROUP_CONCAT(think_harder, ',') FROM (SELECT think_harder FROM chat ORDER BY created_at)"), "1,0")
        t.app.terminate()
        let again = TurnApp(script: "no-reasoning.jsonl", container: t.container)
        again.launch()
        again.openMostRecentChat()  // B
        XCTAssertFalse(again.app.buttons["thinkHarder"].isSelected)
        let rows = again.window.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'chatRow.' AND identifier != 'chatRow.streaming'"))
        rows.element(boundBy: 1).click()  // A
        XCTAssertTrue(again.wait(3) { again.app.buttons["thinkHarder"].isSelected })
    }
}
