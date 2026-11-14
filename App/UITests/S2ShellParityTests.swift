// AT-M1-S2 XCUITest form (M1.T01 "Files / modules"; D-012 S-2 gate): the S-2 scope journeys 2, 3 and 9 on
// `fixtures/scripts/s2.jsonl` (one Markdown reply per turn), the renderer case on `mixed-3k.jsonl`, and the real-model
// streaming-rate case on `chat-9b-q4` (`-FakeHardware T1`, `ANTICHAT_S2_REAL=1`, model from `make models-dev TIER=T1`).
// Written at the gate; not run in the agent session (Q-015 automation mode, Q-023/Q-024/Q-025 shared desktop and
// worktree sandbox). The in-process stand-ins the verdict used are listed in docs/research/07-spikes/S-2-shell-parity.md
// (S2GateProbeTests for the rate and idle-footprint legs; the T06–T11 unit/probe ATs for the functional legs). The
// serial UI-test run (M1.T27 step 8) runs this class:
//   xcodebuild test -workspace AntiChat.xcworkspace -scheme AntiChat-UITests -destination 'platform=macOS,arch=arm64' \
//     ENABLE_HARDENED_RUNTIME=NO -only-testing:AntiChatUITests/S2ShellParityTests
import AppKit
import XCTest

final class S2ShellParityTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor private func replied(_ t: TurnApp, _ prompt: String) {
        t.send(prompt)
        XCTAssertTrue(element(t.app, "actionBar").waitForExistence(timeout: 20), "no finished reply")
    }

    /// R-002/R-004: send → pending + Stop at once → stream → Stop keeps the partial = persisted, notice shown.
    @MainActor
    func testSendStreamStop() throws {
        let t = TurnApp(script: "stream-600w.jsonl")
        t.launch()
        t.send("Tell me about the harbour town.")
        XCTAssertTrue(t.stopButton.waitForExistence(timeout: 2), "Send did not flip to Stop")
        t.waitForText(atLeast: 120)
        t.stopButton.click()
        XCTAssertTrue(t.sendButton.waitForExistence(timeout: 2))
        XCTAssertTrue(t.notice.waitForExistence(timeout: 2))
        let shown = t.currentText()
        let row = t.lastAssistantRow()
        XCTAssertEqual(row.status, "interrupted")
        XCTAssertEqual(row.text, shown)
        TurnApp.evidence("AT-M1-S2", ["case": "testSendStreamStop", "partialChars": shown.count])
    }

    /// R-006: Edit → version 2/2 → ‹ back to 1/2 restores the original reply.
    @MainActor
    func testEditVersionSwitch() throws {
        let t = TurnApp(script: "s2.jsonl")
        t.launch()
        replied(t, "Plan a weekend in Lisbon.")
        let original = t.currentText()
        element(t.app, "userBubble").hover()
        XCTAssertTrue(t.app.buttons["userAction.edit"].waitForExistence(timeout: 2))
        t.app.buttons["userAction.edit"].click()
        let editor = element(t.app, "inlineEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 2))
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("Plan a weekend in Porto.")
        t.app.buttons["inlineEditorSend"].click()
        XCTAssertTrue(element(t.app, "actionBar").waitForExistence(timeout: 20))
        XCTAssertEqual(t.app.staticTexts["userVersion"].displayText, "2 / 2")
        t.app.buttons["userVersion.previous"].click()
        XCTAssertTrue(t.wait(3) { t.app.staticTexts["userVersion"].displayText == "1 / 2" })
        XCTAssertEqual(t.currentText(), original)
        TurnApp.evidence("AT-M1-S2", ["case": "testEditVersionSwitch"])
    }

    /// R-005: Regenerate popover (Try again / Ask to change response / Think harder) and ‹ n/N ›.
    @MainActor
    func testRegenerateVersions() throws {
        let t = TurnApp(script: "s2.jsonl")
        t.launch()
        replied(t, "Plan a weekend in Lisbon.")
        for _ in 0..<2 {
            t.app.buttons["action.regenerate"].click()
            XCTAssertTrue(element(t.app, "regeneratePopover").waitForExistence(timeout: 2))
            XCTAssertTrue(t.app.buttons["regenerate.thinkHarder"].exists)
            t.app.buttons["regenerate.tryAgain"].clickReliably()
            XCTAssertTrue(element(t.app, "actionBar").waitForExistence(timeout: 20))
        }
        XCTAssertEqual(t.app.staticTexts["assistantVersion"].displayText, "3 / 3")
        t.app.buttons["assistantVersion.previous"].click()
        XCTAssertTrue(t.wait(3) { t.app.staticTexts["assistantVersion"].displayText == "2 / 3" })
        TurnApp.evidence("AT-M1-S2", ["case": "testRegenerateVersions", "versions": 3])
    }

    /// R-008: code block (language, Copy), table (Copy as CSV) and math render, while streaming and when done.
    @MainActor
    func testRenderCodeTableMath() throws {
        let t = TurnApp(script: "mixed-3k.jsonl")
        t.launch()
        t.send("Walk me through a market day in numbers, with code and a table.")
        t.waitForText(atLeast: 13_000, timeout: 60)
        let any = t.app.descendants(matching: .any)
        XCTAssertTrue(any.matching(identifier: "codeLanguage").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(any.matching(identifier: "codeCopy").firstMatch.exists)
        XCTAssertTrue(any.matching(identifier: "tableCopyCSV").firstMatch.exists)
        add(XCTAttachment(screenshot: t.window.screenshot()))
        TurnApp.evidence("AT-M1-S2", ["case": "testRenderCodeTableMath"])
    }

    /// R-012: ⌘K finds a chat by a word that is only in a message body.
    @MainActor
    func testPaletteFindsBody() throws {
        let t = TurnApp(script: "s2.jsonl")
        t.launch()
        replied(t, "Remember the word zebracorn for me.")
        t.app.typeKey("n", modifierFlags: .command)
        t.app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(element(t.app, "palette").waitForExistence(timeout: 2))
        t.app.typeText("zebracorn")
        let rows = t.app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'palette.row.chat.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 2))
        TurnApp.evidence("AT-M1-S2", ["case": "testPaletteFindsBody", "rows": rows.count])
    }

    /// Streaming at engine speed (step 4.4): 20 replies of ~600 words on the real `chat-9b-q4` at the T1 cap; per reply
    /// the engine decode rate (`usage.tokPerSec`, provenance `tok_per_s`) and the renderer rate (`-RendererProbe`
    /// output `renderer.json`) → `build/at/AT-M1-S2/bench.json`. Skipped unless ANTICHAT_S2_REAL=1.
    @MainActor
    func testRealModelStreamingRate() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ANTICHAT_S2_REAL"] == "1", "real-model leg: ANTICHAT_S2_REAL=1")
        var rows: [[String: Double]] = []
        for i in 0..<20 {
            let dir = TurnApp.repoRoot.appendingPathComponent("build/at/AT-M1-S2/real-\(i)", isDirectory: true)
            let app = XCUIApplication.foreground()
            let box = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-s2-\(UUID().uuidString)")
            app.launchArguments = ["-ANTICHAT_DEV_CONTAINER", box.path, "-FakeHardware", "T1", "-RendererProbe", dir.path,
                                   "-ApplePersistenceIgnoreState", "YES"]
            app.launch()
            let out = dir.appendingPathComponent("renderer.json")
            let deadline = Date().addingTimeInterval(240)
            while Date() < deadline, !FileManager.default.fileExists(atPath: out.path) { usleep(500_000) }
            guard let data = try? Data(contentsOf: out),
                let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { XCTFail("run \(i): no renderer.json"); continue }
            let revealS = r["revealSeconds"] as? Double ?? 0
            let chars = r["replyChars"] as? Double ?? 0
            let engineTokS = r["engineTokPerSec"] as? Double ?? 0
            let tokens = r["completionTokens"] as? Double ?? chars / 4
            rows.append(["engine_tok_s": engineTokS, "renderer_tok_s": revealS > 0 ? tokens / revealS : 0])
            app.terminate()
        }
        let ratios = rows.compactMap { $0["engine_tok_s"]! > 0 ? $0["renderer_tok_s"]! / $0["engine_tok_s"]! : nil }.sorted()
        let median = ratios.isEmpty ? 0 : ratios[ratios.count / 2]
        TurnApp.evidence("AT-M1-S2", ["case": "testRealModelStreamingRate", "medianRatio": median, "runs": rows.count])
        XCTAssertGreaterThanOrEqual(median, 0.97)
    }
}
