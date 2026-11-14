// M1.T19 AT-014 + AT-299 (XCUITest form; not run on this Mac, Q-015 — the in-process `-TurnProbe` runs the same
// legs: tools/at/t19-probe.sh). Follow-ups while generating (`stream-600w.jsonl`, ~15 s replies) and type before
// the model is ready (`slow-load.jsonl`, load 0→100 % over 8 s).
import XCTest

final class QueueTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func queued(_ t: TurnApp, _ i: Int) -> XCUIElement {
        t.app.descendants(matching: .any)["queuedFollowUp.\(i)"]
    }

    /// AT-014 (1): two messages sent during generation appear as pending bubbles in order, are editable and
    /// removable, and are sent one after another when the turn ends; the removed one is never sent.
    @MainActor
    func testFollowUpQueued() throws {
        let t = TurnApp(script: "stream-600w.jsonl")
        t.launch()
        t.send("Tell me a long story about the harbour town.")
        XCTAssertTrue(t.stopButton.waitForExistence(timeout: 2))
        t.waitForText(atLeast: 40)
        for text in ["Follow-up one", "Follow-up two", "Follow-up three"] { t.send(text) }
        XCTAssertTrue(queued(t, 2).waitForExistence(timeout: 2), "three queued bubbles")
        XCTAssertTrue(t.stopButton.exists, "the reply keeps running while follow-ups queue")
        // Edit the second, remove the third.
        t.app.buttons["queuedFollowUp.1.edit"].click()
        let field = t.app.textFields["queuedFollowUp.1.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.typeText(", edited")
        t.app.buttons["queuedFollowUp.1.save"].click()
        t.app.buttons["queuedFollowUp.2.remove"].click()
        XCTAssertFalse(queued(t, 2).waitForExistence(timeout: 1))
        // The running reply ends; both follow-ups go out in order (each ~15 s).
        let drained = t.window.wait(60) { _ in
            t.sql("SELECT COUNT(*) FROM message WHERE role = 'user'") == "3" && t.sendButton.exists
        }
        XCTAssertTrue(drained)
        let users = t.sql("SELECT group_concat(body, '|') FROM (SELECT p.body FROM message m JOIN message_part p ON p.message_id = m.id WHERE m.role = 'user' AND p.kind = 'text' ORDER BY m.created_at)")
        XCTAssertEqual(users, "Tell me a long story about the harbour town.|Follow-up one|Follow-up two, edited")
        add(XCTAttachment(screenshot: t.window.screenshot()))
        TurnApp.evidence("AT-014", ["case": "testFollowUpQueued", "users": users])
    }

    /// AT-014 (2): ⌘Return during generation stops the current reply (interrupted notice) and sends at once.
    @MainActor
    func testCommandEnterSendsNow() throws {
        let t = TurnApp(script: "stream-600w.jsonl")
        t.launch()
        t.send("Tell me a long story about the harbour town.")
        t.waitForText(atLeast: 60)
        t.input.click()
        t.input.typeText("Stop and answer this instead")
        t.input.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(t.notice.waitForExistence(timeout: 2), "the running reply was not interrupted")
        XCTAssertTrue(t.stopButton.waitForExistence(timeout: 2), "the new message did not start a reply")
        let last = t.sql("SELECT p.body FROM message m JOIN message_part p ON p.message_id = m.id WHERE m.role = 'user' ORDER BY m.created_at DESC LIMIT 1")
        XCTAssertEqual(last, "Stop and answer this instead")
        add(XCTAttachment(screenshot: t.window.screenshot()))
        TurnApp.evidence("AT-014", ["case": "testCommandEnterSendsNow"])
    }

    /// AT-299: accepted at once, "Sending when Chat is ready (NN%)" with NN rising, sent automatically on ready;
    /// a cancelled one is never sent (no row).
    @MainActor
    func testTypeBeforeReady() throws {
        let t = TurnApp(script: "slow-load-12s.jsonl")
        t.launch()
        t.send("Hello before the model is ready")
        let caption = t.app.staticTexts["queuedBubble.caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 1))
        let first = caption.displayText
        sleep(1)
        XCTAssertTrue(caption.displayText.hasPrefix("Sending when Chat is ready ("), caption.displayText)
        XCTAssertNotEqual(caption.displayText, first, "the percentage rises")
        t.app.buttons["queuedBubble.remove"].click()
        XCTAssertFalse(caption.waitForExistence(timeout: 1))
        XCTAssertEqual(t.sql("SELECT COUNT(*) FROM message"), "0")
        XCTAssertEqual(t.sql("SELECT COUNT(*) FROM chat"), "0")
        t.send("Hello again, still loading")
        XCTAssertTrue(caption.waitForExistence(timeout: 1))
        XCTAssertTrue(t.window.wait(12) { _ in !caption.exists })
        t.waitForText(atLeast: 5)
        add(XCTAttachment(screenshot: t.window.screenshot()))
        TurnApp.evidence("AT-299", ["case": "testTypeBeforeReady", "firstCaption": first])
    }
}
