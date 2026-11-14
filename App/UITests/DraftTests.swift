// AT-302 (M1.T21, R-302), XCUITest form: switch chats, quit (⌘Q), crash (`kill -9` 1.2 s after the last keystroke)
// and incognito. Not run in the agent session (Q-015 automation mode; Q-023/Q-024/Q-025); the in-process forms are
// `DraftStoreTests` (virtual clock, incognito seam, cascade), `DraftBindingHostTests` (window stack: switch, send,
// termination flush, relaunch, incognito composer) and the `-DraftProbe` app probe (tools/at/at-302-probe.sh: real
// app, quit and SIGKILL legs). The serial UI-test run (M1.T27 step 8) runs this class. The incognito case needs
// M1.T20's ⇧⌘N entry; it skips until that lands.
import XCTest

final class DraftTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func typeInComposer(_ t: TurnApp, _ text: String) {
        XCTAssertTrue(t.input.waitForExistence(timeout: 10))
        t.input.click()
        t.input.typeText(text)
    }

    @MainActor private func composerValue(_ t: TurnApp) -> String { (t.input.value as? String) ?? "" }

    @MainActor private func chatRows(_ t: TurnApp) -> [XCUIElement] {
        t.window.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'chatRow.' AND identifier != 'chatRow.streaming'"))
            .allElementsBoundByIndex
    }

    /// Text and the paste card are restored after switching chats; `draft.updated_at` is ≤ 1 s after the last keystroke.
    @MainActor
    func testSwitchChatsRestoresDraft() throws {
        let t = TurnApp(script: "basic.jsonl")
        t.launch()
        t.send("First chat")
        XCTAssertTrue(t.sendButton.waitForExistence(timeout: 15))
        t.app.typeKey("n", modifierFlags: .command)
        t.send("Second chat")
        XCTAssertTrue(t.sendButton.waitForExistence(timeout: 15))
        let rows = chatRows(t)
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        rows[1].click()  // the first chat
        typeInComposer(t, "unsent words")
        let lastKey = Date().timeIntervalSince1970
        rows[0].click()
        XCTAssertEqual(composerValue(t), "")
        rows[1].click()
        XCTAssertEqual(composerValue(t), "unsent words")
        let updated = Double(t.sql("SELECT updated_at FROM draft WHERE text = 'unsent words'")) ?? 0
        XCTAssertLessThanOrEqual(updated - lastKey, 1.0)
        TurnApp.evidence("AT-302", ["case": "testSwitchChatsRestoresDraft", "lagSeconds": updated - lastKey])
    }

    /// ⌘Q right after typing: the pending debounce is flushed; the relaunch shows the draft.
    @MainActor
    func testQuitRestoresDraft() throws {
        let t = TurnApp(script: "basic.jsonl")
        t.launch()
        typeInComposer(t, "before quitting")
        t.app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(t.app.wait(for: .notRunning, timeout: 10))
        XCTAssertEqual(t.sql("SELECT text FROM draft WHERE chat_id = 'new'"), "before quitting")
        t.launch()
        XCTAssertEqual(composerValue(t), "before quitting")
    }

    /// `kill -9` 1.2 s after the last keystroke: the row was already written; the relaunch shows the draft.
    @MainActor
    func testCrashRestoresDraft() throws {
        let t = TurnApp(script: "basic.jsonl")
        t.launch()
        typeInComposer(t, "before the crash")
        usleep(1_200_000)
        // This test's app only (other worktrees run AntiChat too), by its pid (Q-015 r3: pkill cannot list processes
        // from the sandboxed runner).
        XCTAssertTrue(TestProcesses.kill9(t.app.processID.map { [$0] } ?? []), "no pid for the app under test")
        XCTAssertTrue(t.app.wait(for: .notRunning, timeout: 10))
        XCTAssertEqual(t.sql("SELECT text FROM draft WHERE chat_id = 'new'"), "before the crash")
        t.launch()
        XCTAssertEqual(composerValue(t), "before the crash")
    }

    /// Incognito (⇧⌘N, M1.T20): no `draft` row (the disk diff of AT-090 wraps the run).
    @MainActor
    func testIncognitoDraftNotPersisted() throws {
        let t = TurnApp(script: "basic.jsonl")
        t.launch()
        t.app.typeKey("n", modifierFlags: [.command, .shift])
        guard t.app.descendants(matching: .any)["incognitoFrame"].waitForExistence(timeout: 3) else {
            throw XCTSkip("Incognito entry point (M1.T20) not in this build")
        }
        typeInComposer(t, "incognito draft phrase")
        usleep(1_500_000)
        XCTAssertEqual(t.sql("SELECT COUNT(*) FROM draft"), "0")
    }
}
