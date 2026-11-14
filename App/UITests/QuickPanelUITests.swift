// AT-106 UI leg (M8.T13; R-106 AC1, XCUITest journey 15 part): the global quick panel opened through the DEBUG hook
// (`-QuickPanelHotkeyHook YES`: the distributed notification `app.antichat.test.quickPanelHotkey` calls the hotkey's
// handler) above TextEdit: on screen, floating, focused; type + Return streams the reply in the panel; Esc behaviour;
// Open in AntiChat (⌘O) shows the same chat with the full reply in the main window; the recorder sets ⌃⌥Q and Off.
// Committed, not run on this Mac (Q-015). In-process legs that run today: QuickPanelViewModelTests and
// tools/at/at-105-probe.sh (MacIntegrationProbe mode `quickpanel`); NFR-U9: `make perf METRIC=U9`.
import XCTest

final class QuickPanelUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func launch() -> XCUIApplication {
        let stream = FileManager.default.temporaryDirectory.appendingPathComponent("qp-\(UUID().uuidString).jsonl")
        let words = (0..<40).map { #"{"t":"textDelta","v":" word\#($0)","delayMs":60}"# }.joined(separator: "\n")
        try? Data((words + "\n").utf8).write(to: stream)
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-SkipOnboarding", "YES", "-OfflineOnly", "YES",
                                            "-UseScriptedEngine", stream.path, "-QuickPanelHotkeyHook", "YES",
                                            "-DefaultsSuite", "com.antichat.uitest.quickpanel", "-FreshDefaultsSuite", "YES"])
        app.launch()
        return app
    }

    func hotkey(_ action: String = "toggle") {
        // Q-015 r5: the runner is sandboxed, and macOS drops a sandboxed process's distributed notification that carries
        // a userInfo dictionary, so the panel never opened. A toggle is the hook's default without userInfo (its time is
        // taken on arrival); `hide` / `show` keep the dictionary.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("app.antichat.test.quickPanelHotkey"), object: nil,
            userInfo: action == "toggle" ? nil : ["action": action, "uptime": String(ProcessInfo.processInfo.systemUptime)],
            deliverImmediately: true)
    }

    @MainActor
    /// The panel is an NSPanel, which macOS 26 exposes as an AX dialog, not a window (Q-015 r4).
    func panel(_ app: XCUIApplication) -> XCUIElement { app.dialogs.matching(identifier: "quickPanel").firstMatch }

    @MainActor
    func testOpensAboveOtherAppsStreamsAndOpensInApp() {
        let app = launch()
        app.typeKey("h", modifierFlags: .command)  // hide AntiChat: unfocused without launching another app (Q-015 catch-up)
        sleep(2)  // the panel is built at first paint + 1 s
        hotkey()
        let p = panel(app)
        XCTAssertTrue(p.waitForExistence(timeout: 3))
        XCTAssertTrue(p.isHittable, "on screen above TextEdit")
        let field = p.textFields["quickPanel.field"]
        XCTAssertEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true)
        field.typeText("What's 2+2?\r")
        let reply = p.descendants(matching: .any).matching(identifier: "quickPanel.reply").firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        p.typeKey("o", modifierFlags: .command)
        XCTAssertFalse(p.exists && p.isHittable, "the panel hides")
        let main = app.windows.element(boundBy: 0)
        XCTAssertTrue(main.staticTexts.matching(NSPredicate(format: "label CONTAINS 'word39' OR value CONTAINS 'word39'")).firstMatch.waitForExistence(timeout: 15),
                      "the main window finishes the same reply")
    }

    @MainActor
    func testEscapeBehaviour() {
        let app = launch()
        sleep(2)
        hotkey()
        let p = panel(app)
        XCTAssertTrue(p.waitForExistence(timeout: 3))
        p.textFields["quickPanel.field"].typeText("Hello\r")
        p.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(p.isHittable, "Esc while streaming hides the panel")
        sleep(4)
        hotkey()
        XCTAssertTrue(p.waitForExistence(timeout: 3))
        p.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(p.isHittable, "an empty panel hides on Esc")
    }

    @MainActor
    func testRecorderChangesAndOff() {
        let app = launch()
        app.typeKey(",", modifierFlags: .command)
        let recorder = app.descendants(matching: .any).matching(identifier: "settings.control.quickPanelHotkey").firstMatch
        XCTAssertTrue(recorder.waitForExistence(timeout: 5))
        recorder.click()
        recorder.typeKey("q", modifierFlags: [.control, .option])
        XCTAssertTrue((recorder.value as? String ?? "").contains("Q"))
        // × = Off. Q-015 r4: the recorder is a search field whose clear button macOS 26 does not expose to accessibility;
        // Delete while recording clears it the same way (KeyboardShortcuts.Recorder).
        let clear = recorder.buttons.firstMatch
        if clear.exists { clear.click() } else { recorder.click(); recorder.typeKey(.delete, modifierFlags: []) }
        XCTAssertFalse((recorder.value as? String ?? "").contains("Q"), "the hotkey is off")
        hotkey()
        XCTAssertFalse(panel(app).waitForExistence(timeout: 1) && panel(app).isHittable == false)
    }
}
