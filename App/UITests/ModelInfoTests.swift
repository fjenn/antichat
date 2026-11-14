// AT-234 (M1.T25, R-234 both criteria), XCUITest form: the real starter `chat-0.8b` (`-UseScriptedEngine NO`,
// `make models-dev TIER=min`). Not run in the agent session (Q-015 automation mode; Q-023/Q-024/Q-025); the in-process
// forms are `ProvenanceRecorderTests` (leg 1, Harness), `ModelInfoHostTests` (leg 2, window stack) and the
// `-ModelInfoProbe` real-model probe (tools/at/at-234-probe.sh). The serial UI-test run (M1.T27 step 8) runs this class.
import XCTest

final class ModelInfoTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func realModelApp(showModelInfo: Bool, container: URL? = nil) -> TurnApp {
        let t = TurnApp(script: "basic.jsonl", container: container)
        var args = t.app.launchArguments
        if let i = args.firstIndex(of: "-UseScriptedEngine") { args[i + 1] = "NO" }
        args += ["-ChatModel", "chat-0.8b", "-showModelInfo", showModelInfo ? "YES" : "NO"]
        t.app.launchArguments = args
        return t
    }

    @MainActor private func openMore(_ t: TurnApp) {
        let more = t.app.descendants(matching: .any).matching(identifier: "action.more")
        let last = more.element(boundBy: max(0, more.count - 1))
        XCTAssertTrue(last.waitForExistence(timeout: 10))
        last.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()  // r5: hover() needs a hittable element (M9.T03)
        last.click()
    }

    /// (1) 10 turns incl. a regenerate and an interrupted one: every assistant row has model_id, model_sha, mode,
    /// sampling and tok_per_s (interrupted: of the partial). (2) Toggle on: ⋯ → Model info shows the same values.
    @MainActor
    func testTenTurnsCarryProvenanceAndModelInfoShowsThem() throws {
        let t = realModelApp(showModelInfo: true)
        t.launch()
        for i in 0..<9 {
            t.send(i == 4 ? "Write a long story about a lighthouse keeper." : "Say one short sentence about the number \(i).")
            if i == 4 {
                t.waitForText(atLeast: 40, timeout: 60)
                t.stopButton.click()
            }
            XCTAssertTrue(t.sendButton.waitForExistence(timeout: 120), "turn \(i) did not finish")
        }
        // Q-015 r4: the Send button is back the moment a reply ends, a beat before its action bar is drawn, so the
        // regenerate button list was read empty and nothing was clicked. Wait for the last reply's bar.
        let regenerate = t.app.buttons.matching(identifier: "action.regenerate")
        XCTAssertTrue(regenerate.firstMatch.waitForExistence(timeout: 10), "the last reply's action bar")
        let last = regenerate.element(boundBy: max(0, regenerate.count - 1))
        last.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()  // r5: hover() needs a hittable element (M9.T03)
        // Regenerate stays disabled while the chat is busy after the reply (the real model's title turn): a click in
        // that second did nothing and no popover opened. Wait until it is enabled.
        XCTAssertTrue(last.wait(30) { $0.isEnabled }, "regenerate enabled once the chat is idle")
        last.clickReliably()  // transcript controls report "Not hittable" to XCUITest (M9.T03); a real click at its centre
        let tryAgain = t.app.buttons["regenerate.tryAgain"]
        XCTAssertTrue(tryAgain.waitForExistence(timeout: 5), "the regenerate popover")
        tryAgain.clickReliably()
        XCTAssertTrue(t.sendButton.waitForExistence(timeout: 120))
        XCTAssertEqual(t.sql("SELECT COUNT(*) FROM message WHERE role = 'assistant'"), "10")
        let missing = t.sql("""
            SELECT COUNT(*) FROM message WHERE role = 'assistant' AND (model_id IS NULL
              OR json_extract(provenance_json, '$.model_sha') IS NULL OR json_extract(provenance_json, '$.mode') IS NULL
              OR json_extract(provenance_json, '$.sampling_json') IS NULL OR json_extract(provenance_json, '$.tok_per_s') IS NULL)
            """)
        XCTAssertEqual(missing, "0")
        XCTAssertEqual(t.sql("SELECT COUNT(*) FROM message WHERE role = 'assistant' AND status = 'interrupted'"), "1")

        let id = t.sql("SELECT id FROM message WHERE role = 'assistant' ORDER BY created_at DESC, id DESC LIMIT 1")
        let model = t.sql("SELECT model_id FROM message WHERE id = '\(id)'")
        let sha = t.sql("SELECT substr(json_extract(provenance_json, '$.model_sha'), 1, 12) FROM message WHERE id = '\(id)'")
        let rate = t.sql("SELECT printf('%.1f', json_extract(provenance_json, '$.tok_per_s')) FROM message WHERE id = '\(id)'")
        openMore(t)
        t.app.menuItems["Model info"].click()
        let popover = t.app.descendants(matching: .any)["modelInfoPopover"]
        XCTAssertTrue(popover.waitForExistence(timeout: 5))
        XCTAssertEqual(t.app.staticTexts["modelInfo.model"].displayText, model)
        XCTAssertEqual(t.app.staticTexts["modelInfo.sha"].displayText, sha)
        XCTAssertEqual(t.app.staticTexts["modelInfo.mode"].displayText, "Normal")
        XCTAssertTrue(t.app.staticTexts["modelInfo.sampling"].displayText.contains("temperature"))
        XCTAssertTrue(t.app.staticTexts["modelInfo.speed"].displayText.hasPrefix("\(rate) tok/s"))
        add(XCTAttachment(screenshot: t.window.screenshot()))
        TurnApp.evidence("AT-234", ["case": "testTenTurnsCarryProvenanceAndModelInfoShowsThem", "model": model, "sha": sha])
    }

    /// (2) Toggle off (the default): the ⋯ menu has no Model info item.
    @MainActor
    func testModelInfoAbsentWhenOff() throws {
        let t = realModelApp(showModelInfo: false)
        t.launch()
        t.send("Say hello.")
        XCTAssertTrue(t.sendButton.waitForExistence(timeout: 120))
        openMore(t)
        XCTAssertTrue(t.app.menuItems["Branch in new chat"].waitForExistence(timeout: 3))
        XCTAssertFalse(t.app.menuItems["Model info"].exists)
        t.app.typeKey(.escape, modifierFlags: [])
    }
}
