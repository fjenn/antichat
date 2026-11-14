// Journey 02 (M1.T06 AT-004; M1.T19 extends it): send → stream → Stop. ScriptedEngine `stream-600w.jsonl`
// (600 words, ~15 s) and `crash-mid-stream.jsonl` (40 words, then the engine dies → `engine.restarted`).
// The NFR-U6 latency gate itself is `make perf METRIC=U6` (M1.T26); the stop→idle times here are smoke numbers.
// M1.T19 (AT-003): the loading status line under `slow-load.jsonl` and the completion transition (ActionBar, Send,
// sidebar spinner together) under `tool-call.jsonl` + `-FixedClock`; not run on this Mac (Q-015, `-TurnProbe`).
import XCTest

final class J02SendStreamStopTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Send acknowledgement + Stop: the user bubble, pending node and Stop appear at once; after Stop the UI is
    /// idle, the partial text is kept and equals the persisted `message_part` text.
    @MainActor
    func testStopKeepsPartial() throws {
        let t = TurnApp(script: "stream-600w.jsonl")
        t.launch()
        t.send("Tell me about the harbour town.")
        XCTAssertTrue(t.app.descendants(matching: .any)["userBubble"].waitForExistence(timeout: 2))
        XCTAssertTrue(t.stopButton.waitForExistence(timeout: 2), "Send did not flip to Stop")
        t.waitForText(atLeast: 120)
        let t0 = Date()
        t.stopButton.click()
        XCTAssertTrue(t.sendButton.waitForExistence(timeout: 2), "UI not idle after Stop")
        let idle = Date().timeIntervalSince(t0)
        XCTAssertTrue(t.notice.waitForExistence(timeout: 2))
        let shown = t.currentText()
        XCTAssertGreaterThan(shown.count, 0)
        // Nothing more streams in after the stop.
        sleep(1)
        XCTAssertEqual(t.currentText(), shown)
        let row = t.lastAssistantRow()
        XCTAssertEqual(row.status, "interrupted")
        XCTAssertEqual(row.text, shown, "partial text on screen ≠ persisted message_part text")
        add(XCTAttachment(screenshot: t.window.screenshot()))
        TurnApp.evidence("AT-004", [
            "case": "testStopKeepsPartial", "stopToIdleSeconds": idle, "partialChars": shown.count,
            "persistedChars": row.text.count, "status": row.status,
        ])
    }

    /// The notice: copy `msg.interrupted` with [Edit prompt] [Retry]; Retry makes version 2/2; Edit prompt opens
    /// the inline editor on the user message.
    @MainActor
    func testInterruptedNoticeActions() throws {
        let t = TurnApp(script: "stream-600w.jsonl")
        t.launch()
        t.send("Tell me about the harbour town.")
        t.waitForText(atLeast: 60)
        t.stopButton.click()
        XCTAssertTrue(t.notice.waitForExistence(timeout: 2))
        let message = t.app.staticTexts["interruptedMessage"]
        XCTAssertEqual(message.displayText, "Response interrupted.")
        let edit = t.app.buttons["interruptedEdit"]
        let retry = t.app.buttons["interruptedRetry"]
        XCTAssertEqual(edit.displayText, "Edit prompt")
        XCTAssertEqual(retry.displayText, "Retry")

        retry.click()
        let version = t.app.staticTexts["assistantVersion"]
        XCTAssertTrue(version.waitForExistence(timeout: 3), "Retry did not create a version")
        XCTAssertEqual(version.displayText, "2 / 2")
        XCTAssertTrue(t.stopButton.waitForExistence(timeout: 2))
        t.waitForText(atLeast: 60)
        t.stopButton.click()
        XCTAssertTrue(t.notice.waitForExistence(timeout: 2))
        XCTAssertEqual(t.sql("SELECT COUNT(*) FROM message WHERE role = 'assistant'"), "2")

        t.app.buttons["interruptedEdit"].click()
        let editor = t.app.descendants(matching: .any).matching(identifier: "inlineEditor").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 2), "Edit prompt did not open the inline editor")
        XCTAssertEqual(editor.value as? String, "Tell me about the harbour town.")
        XCTAssertTrue(t.app.buttons["inlineEditorSend"].exists)
        XCTAssertTrue(t.app.buttons["inlineEditorCancel"].exists)
        add(XCTAttachment(screenshot: t.window.screenshot()))
        TurnApp.evidence("AT-004", ["case": "testInterruptedNoticeActions", "version": version.displayText, "editor": true])
    }

    /// An engine failure mid-stream shows the identical notice plus the `engine.restarted` line.
    @MainActor
    func testEngineErrorShowsSameNotice() throws {
        let t = TurnApp(script: "crash-mid-stream.jsonl")
        t.launch()
        t.send("Tell me about the harbour town.")
        XCTAssertTrue(t.notice.waitForExistence(timeout: 10))
        XCTAssertEqual(t.app.staticTexts["interruptedMessage"].displayText, "Response interrupted.")
        XCTAssertEqual(t.app.staticTexts["interruptedReason"].displayText, "The AI engine restarted.")
        XCTAssertEqual(t.app.buttons["interruptedEdit"].displayText, "Edit prompt")
        XCTAssertEqual(t.app.buttons["interruptedRetry"].displayText, "Retry")
        XCTAssertTrue(t.sendButton.waitForExistence(timeout: 2))
        let shown = t.currentText()
        XCTAssertEqual(shown.split(separator: " ").count, 40)
        let row = t.lastAssistantRow()
        XCTAssertEqual(row.status, "interrupted")
        XCTAssertEqual(row.error, "engine.restarted")
        XCTAssertEqual(row.text, shown)
        add(XCTAttachment(screenshot: t.window.screenshot()))
        TurnApp.evidence("AT-004", ["case": "testEngineErrorShowsSameNotice", "errorCode": row.error, "words": 40])
    }

    /// AT-003 (2): during a model load the reply area shows `status.loadingModel` at once and is never empty.
    @MainActor
    func testLoadingStatusNeverEmpty() throws {
        let t = TurnApp(script: "slow-load.jsonl")
        t.app.launchArguments += ["-FixedClock", "2026-11-15T09:30:00+01:00"]
        t.launch()
        t.send("Hello while loading")
        let status = t.app.staticTexts["statusVerb"]
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        XCTAssertEqual(status.displayText, "Loading model…")
        let dot = t.app.descendants(matching: .any)["pendingDot"]
        let deadline = Date().addingTimeInterval(12)
        var empty = 0
        while Date() < deadline, t.currentText().isEmpty {
            if !dot.exists, !status.exists { empty += 1 }
            usleep(100_000)
        }
        XCTAssertEqual(empty, 0, "the assistant area was empty of both dot and text")
        t.waitForText(atLeast: 5)
        TurnApp.evidence("AT-003", ["case": "testLoadingStatusNeverEmpty", "emptySamples": empty])
    }

    /// AT-003 (4): the tool script shows an activity line; on done the ActionBar, Send and the sidebar spinner
    /// change together.
    @MainActor
    func testToolActivityThenCompletion() throws {
        let t = TurnApp(script: "tool-call.jsonl")
        t.app.launchArguments += ["-UseScriptedTools", "YES", "-ChatModel", "chat-9b-q4"]  // starter is chat-only (D-023)
        t.launch()
        t.send("Echo hello through the tool please")
        XCTAssertTrue(t.app.descendants(matching: .any)["activityLine"].waitForExistence(timeout: 5))
        let bar = t.app.descendants(matching: .any)["actionBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        XCTAssertTrue(t.sendButton.exists)
        XCTAssertFalse(t.app.descendants(matching: .any)["chatRow.streaming"].exists)
        add(XCTAttachment(screenshot: t.window.screenshot()))
    }
}
