// M1.T19 AT-010 (XCUITest form; not run on this Mac, Q-015 — the in-process `-TurnProbe` runs the same legs:
// tools/at/t19-probe.sh). Titles and live sidebar status: temporary title at once, auto title after the reply
// starts, no row for an empty chat, spinner while generating, unread dot for a background reply.
import XCTest

final class SidebarStatusTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func rows(_ t: TurnApp) -> XCUIElementQuery {
        t.window.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'chatRow.' AND identifier != 'chatRow.streaming' AND identifier != 'chatRow.renameField'"))
    }

    /// AT-010 (1): the prompt is the title at once; the 2–6 word title replaces it (script `title` line).
    @MainActor
    func testTemporaryThenAutoTitle() throws {
        // Q-015 r4: basic.jsonl's title arrives after 0.4 s, before the first look at the row, so the temporary title
        // was already replaced. The same script with the title after 2.5 s keeps both states observable.
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("slow-title-\(UUID().uuidString).jsonl")
        try Data((#"{"t":"title","v":"Harbour town weekend plan","delayMs":2500}"# + "\n"
                  + #"{"t":"textDelta","v":"Hello! How can I help you today?","delayMs":20}"# + "\n").utf8).write(to: script)
        let t = TurnApp(script: script.path)
        t.launch()
        let prompt = "Plan a quiet weekend in the harbour town with the ferry, the market and the lighthouse"
        t.send(prompt)
        XCTAssertTrue(rows(t).firstMatch.waitForExistence(timeout: 1))
        XCTAssertTrue(rows(t).firstMatch.displayText.hasPrefix(String(prompt.prefix(40))), rows(t).firstMatch.displayText)
        XCTAssertTrue(rows(t).firstMatch.wait(8) { $0.displayText.hasPrefix("Harbour town weekend plan") })
        XCTAssertEqual(t.sql("SELECT title_state FROM chat"), "auto")
        TurnApp.evidence("AT-010", ["case": "testTemporaryThenAutoTitle", "title": rows(t).firstMatch.displayText])
    }

    /// AT-010 (2): opening and closing an empty new chat leaves no row.
    @MainActor
    func testEmptyChatLeavesNoRow() throws {
        let t = TurnApp(script: "basic.jsonl")
        t.launch()
        t.app.typeKey("n", modifierFlags: .command)
        t.app.typeKey("n", modifierFlags: .command)
        XCTAssertEqual(rows(t).count, 0)
        XCTAssertEqual(t.sql("SELECT COUNT(*) FROM chat"), "0")
    }

    /// AT-010 (3): spinner while generating; a reply finishing in a background chat shows the unread dot, cleared
    /// when the chat is opened.
    @MainActor
    func testSpinnerAndUnreadDot() throws {
        let t = TurnApp(script: "stream-600w.jsonl")
        t.launch()
        t.send("First chat")
        XCTAssertTrue(t.app.descendants(matching: .any)["chatRow.streaming"].waitForExistence(timeout: 1))
        t.stopButton.click()
        t.app.typeKey("n", modifierFlags: .command)
        t.send("Second chat, answered in the background")
        XCTAssertTrue(t.app.descendants(matching: .any)["chatRow.streaming"].waitForExistence(timeout: 1))
        rows(t).element(boundBy: 1).click()  // back to the first chat while the second replies
        // The row is one button; its dot is spoken as ", Unread" in the row's label (Q-015 r4: the dot is not its own element).
        let unread = rows(t).matching(NSPredicate(format: "label ENDSWITH ', Unread'")).firstMatch
        XCTAssertTrue(unread.waitForExistence(timeout: 30))
        XCTAssertEqual(t.sql("SELECT COUNT(*) FROM chat WHERE unread = 1"), "1")
        rows(t).firstMatch.click()
        XCTAssertFalse(unread.waitForExistence(timeout: 1))
        XCTAssertEqual(t.sql("SELECT COUNT(*) FROM chat WHERE unread = 1"), "0")
        add(XCTAttachment(screenshot: t.window.screenshot()))
    }
}
