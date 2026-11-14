// M0.T04 step 10 (NFR-S4, AT-M0-04 check 3): while the spike chat streams, the engine helper is killed
// with SIGKILL; the UI must stay responsive (every keystroke visible ≤ 100 ms) and show the
// `engine.restarted` copy. Kill timestamps and HelloAck times are measured by the bench `restart` mode;
// this test proves the UI side.
import XCTest

final class SpikeRestartTests: XCTestCase {
    @MainActor
    func testUIStaysAliveWhenEngineIsKilled() throws {
        let app = XCUIApplication.foreground()
        let model = ProcessInfo.processInfo.environment["SPIKE_MODEL"] ?? "chat-0.8b"
        app.launchArguments = ["-SpikeUI", "YES", "-SpikeModel", model]
        app.launch()
        let field = app.textFields["spike.input"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        let status = app.staticTexts["spike.status"]
        let ready = NSPredicate(format: "value BEGINSWITH 'Engine ready'")
        expectation(for: ready, evaluatedWith: status)
        waitForExpectations(timeout: 30)

        field.click()
        field.typeText("Write 300 words about tides.\r")
        // Wait until text streams (the assistant bubble is no longer the placeholder).
        sleep(4)

        // Kill the helper (the same as `pkill -9 -f AntiChatEngine`), only the one this app is connected to (other
        // worktrees run their own). Q-015 r5: the sandboxed runner can neither pkill (exit 3, r3) nor see other
        // processes through libproc (r5: "no running helper"), so the app's DEBUG spike hook SIGKILLs its own helper.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("app.antichat.test.spikeKillEngine"), object: nil, userInfo: nil, deliverImmediately: true)

        // Type every 100 ms; each keystroke must be in the field within 100 ms.
        field.click()
        var worst: TimeInterval = 0
        var typed = ""
        for ch in "still here" {
            let t0 = Date()
            field.typeText(String(ch))
            typed.append(ch)
            let deadline = Date().addingTimeInterval(1)
            while (field.value as? String) != typed, Date() < deadline { usleep(5_000) }
            let dt = Date().timeIntervalSince(t0)
            worst = max(worst, dt)
            if dt < 0.1 { usleep(useconds_t((0.1 - dt) * 1e6)) }
        }
        XCTAssertEqual(field.value as? String, "still here")
        // r5: on macOS a static text's words are its AXValue; the notice is the `spike.restarted` container.
        let restarted = app.descendants(matching: .any).matching(identifier: "spike.restarted").firstMatch
        XCTAssertTrue(restarted.waitForExistence(timeout: 5), "engine.restarted copy not shown")
        XCTAssertTrue(restarted.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "The AI engine restarted.",
                                                                 "The AI engine restarted.")).firstMatch.exists, "the engine.restarted copy")
        XCTAssertTrue(app.buttons["spike.retry"].exists)
        let line = String(format: "worst_keystroke_s=%.4f\n", worst)
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spike-restart-uitest.txt")
        try? line.write(to: out, atomically: true, encoding: .utf8)
        print("SPIKE " + line)
        // XCUITest's typeText is synchronous with the app's event handling; the measured time includes the
        // synthesis overhead, so it is an upper bound on the UI's own latency [INFERENCE].
        XCTAssertLessThanOrEqual(worst, 0.1, "a keystroke took \(worst) s to appear")
    }
}
