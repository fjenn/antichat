// Journey 13: crash recovery (M1.T06 creates it with `testKillMidStream`, AT-NFR-S2; M1.T12 adds the helper-
// crash cases). `kill -9` the app 3 s into `stream-600w.jsonl`, relaunch on the same container: the chat reopens
// with the partial reply marked interrupted + Retry, and the persisted text is ≥ the text visible 1 s before
// the kill. The visible text is read from the accessibility tree (exactly what is drawn) and a screenshot is
// attached for the visual record. Helper-crash cases (AT-208 J13-UI, A-M1-T12c): `crash-mid-stream.jsonl` ends
// the stream with `engine.restarted` (what EngineSupervisorClient yields when the helper dies); the app survives,
// ConversationView hosts EngineRestartedNotice, and the state survives an app relaunch. Pending the serial
// XCUITest run (Q-015/Q-023/Q-024); the in-process form is `EngineRestartedHostTests` (AntiChatUIModuleTests).
import XCTest

final class J13CrashRecoveryTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testKillMidStream() throws {
        let t = TurnApp(script: "stream-600w.jsonl")
        t.launch()
        t.send("Tell me about the harbour town.")
        t.waitForText(atLeast: 1, timeout: 5)
        let firstText = Date()
        // 1 s before the kill: what the user sees.
        Thread.sleep(until: firstText.addingTimeInterval(2))
        let visibleBefore = t.currentText()
        let shot = XCTAttachment(screenshot: t.window.screenshot())
        shot.name = "visible-1s-before-kill"
        add(shot)
        Thread.sleep(until: firstText.addingTimeInterval(3))
        // kill -9 of this test's app by its pid (Q-015 r3: pkill exits 3 in the sandboxed runner).
        XCTAssertTrue(TestProcesses.kill9(t.app.processID.map { [$0] } ?? []), "no AntiChat process to kill")
        XCTAssertTrue(t.app.wait(for: .notRunning, timeout: 5))
        let onDisk = t.lastAssistantRow()
        XCTAssertEqual(onDisk.status, "streaming", "row should still be streaming on disk right after the kill")

        // Relaunch on the same container.
        let again = TurnApp(script: "stream-600w.jsonl", container: t.container)
        again.launch()
        again.openMostRecentChat()
        XCTAssertTrue(again.notice.waitForExistence(timeout: 10), "no interrupted notice after relaunch")
        XCTAssertTrue(again.app.buttons["interruptedRetry"].exists)
        let after = again.currentText()
        let row = again.lastAssistantRow()
        XCTAssertEqual(row.status, "interrupted")
        XCTAssertEqual(row.text, after)
        XCTAssertTrue(after.hasPrefix(visibleBefore), "persisted text does not contain the text visible 1 s before the kill")
        XCTAssertGreaterThanOrEqual(after.count, visibleBefore.count)
        let shot2 = XCTAttachment(screenshot: again.window.screenshot())
        shot2.name = "after-relaunch"
        add(shot2)
        TurnApp.evidence("AT-NFR-S2", [
            "case": "testKillMidStream", "visibleCharsAt2s": visibleBefore.count, "persistedChars": after.count,
            "statusAfterKill": onDisk.status, "statusAfterRelaunch": row.status,
        ])
    }

    @MainActor
    func testHelperCrashShowsEngineRestartedNotice() throws {
        let t = TurnApp(script: "crash-mid-stream.jsonl")
        t.launch()
        t.send("Tell me about the harbour town.")
        let hosted = t.app.descendants(matching: .any).matching(identifier: "engineRestartedNotice").firstMatch
        XCTAssertTrue(hosted.waitForExistence(timeout: 10), "EngineRestartedNotice not shown after the helper crash")
        XCTAssertEqual(t.app.staticTexts["interruptedReason"].displayText, "The AI engine restarted.")
        XCTAssertTrue(t.app.buttons["interruptedRetry"].exists)
        XCTAssertEqual(t.app.state, .runningForeground, "the app process must survive a helper crash")
        XCTAssertTrue(t.sendButton.waitForExistence(timeout: 2), "composer idle again")
        let shown = t.currentText()
        add(XCTAttachment(screenshot: t.window.screenshot()))
        t.app.terminate()

        // Relaunch: the reply stays interrupted with its engine reason and partial text.
        let again = TurnApp(script: "crash-mid-stream.jsonl", container: t.container)
        again.launch()
        again.openMostRecentChat()
        let after = again.app.descendants(matching: .any).matching(identifier: "engineRestartedNotice").firstMatch
        XCTAssertTrue(after.waitForExistence(timeout: 10))
        XCTAssertEqual(again.currentText(), shown)
        let row = again.lastAssistantRow()
        XCTAssertEqual(row.status, "interrupted")
        XCTAssertEqual(row.error, "engine.restarted")
        TurnApp.evidence("AT-208", ["case": "testHelperCrashShowsEngineRestartedNotice", "chars": shown.count])
    }
}
