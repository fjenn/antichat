// AT-108 UI leg (M8.T12; R-108 AC1–AC2): with the notification spy (`-NotificationSpy <file>` records every request
// instead of delivering it) and `-FakePermission notifications=<state>` (no TCC): an answer while another app is in
// front notifies once (category answer); none while AntiChat's window shows the chat; Always / Never; a category
// toggle off; the chosen sound is on the request; macOS notifications off → the Settings banner whose button opens
// the Notifications pane (URL recorded in `opened-urls.txt` beside the spy file, nothing opened).
// Committed, not run on this Mac (Q-015: XCUITest cannot start). The in-process legs that run today:
// NotificationPolicyTests / NotificationRouterTests / NotificationServiceTests and tools/at/at-108-probe.sh.
import XCTest

final class NotificationsUITests: XCTestCase {
    var spy: URL!

    override func setUp() {
        continueAfterFailure = false
        spy = FileManager.default.temporaryDirectory.appendingPathComponent("notif-spy-\(UUID().uuidString)/requests.json")
    }

    struct Request: Decodable { let category: String; let title: String; let body: String; let sound: String? }

    func requests() -> [Request] {
        guard let d = try? Data(contentsOf: spy) else { return [] }
        return (try? JSONDecoder().decode([Request].self, from: d)) ?? []
    }

    func waitForRequests(_ n: Int, timeout: TimeInterval = 15) -> [Request] {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if requests().count >= n { break }; RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        return requests()
    }

    @MainActor
    func launch(_ extra: [String] = [], permission: String = "granted") -> XCUIApplication {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("slow-\(UUID().uuidString).jsonl")
        // A 3 s scripted answer (30 tokens × 100 ms).
        // Q-015 r4: the steps were `"t":"token"`, not a script step (EngineScript: textDelta / v), so the script did not
        // parse and the reply came from a real model, never containing "word 29".
        let tokens = (0..<30).map { #"{"t":"textDelta","v":"word \#($0) ","delayMs":100}"# }.joined(separator: "\n")
        try? Data((tokens + "\n" + #"{"t":"done"}"# + "\n").utf8).write(to: script)
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-SkipOnboarding", "YES", "-OfflineOnly", "YES",
                                            "-UseScriptedEngine", script.path, "-NotificationSpy", spy.path,
                                            "-FakePermission", "notifications=\(permission)", "-DefaultsSuite", "com.antichat.uitest.notifications", "-FreshDefaultsSuite", "YES"]
                                           + extra)
        app.launch()
        app.activate()
        return app
    }

    @MainActor
    func send(_ app: XCUIApplication, _ text: String) {
        let input = app.descendants(matching: .any).matching(identifier: "composerText").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.click()
        input.typeText(text)
        input.typeKey(.return, modifierFlags: [])
    }

    @MainActor
    func testAnswerWhileUnfocused() {
        let app = launch()
        send(app, "Tell me a long story")
        app.typeKey("h", modifierFlags: .command)  // hide AntiChat: unfocused without launching another app (Q-015 catch-up)
        let r = waitForRequests(1)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.category, "answer")
        XCTAssertTrue(r.first?.body.hasSuffix(": reply ready") == true, r.first?.body ?? "")
    }

    @MainActor
    func testNoNotificationWhenFocused() {
        let app = launch()
        send(app, "Tell me a long story")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'word 29' OR value CONTAINS 'word 29'")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(waitForRequests(1, timeout: 2).count, 0)
    }

    @MainActor
    func testAlwaysAndNever() {
        var app = launch(["-notifyWhen", "always"])
        send(app, "Tell me a long story")
        XCTAssertEqual(waitForRequests(1).count, 1, "Always: also while looking at the chat")
        app.terminate()
        try? FileManager.default.removeItem(at: spy)
        app = launch(["-notifyWhen", "never"])
        send(app, "Tell me a long story")
        app.typeKey("h", modifierFlags: .command)  // hide AntiChat: unfocused without launching another app (Q-015 catch-up)
        XCTAssertEqual(waitForRequests(1, timeout: 6).count, 0, "Never")
    }

    @MainActor
    func testCategoryToggleOff() {
        let app = launch(["-notifyResponses", "NO"])
        send(app, "Tell me a long story")
        app.typeKey("h", modifierFlags: .command)  // hide AntiChat: unfocused without launching another app (Q-015 catch-up)
        XCTAssertEqual(waitForRequests(1, timeout: 6).count, 0)
    }

    @MainActor
    func testSoundSelection() {
        let app = launch()
        app.typeKey(",", modifierFlags: .command)
        let picker = app.descendants(matching: .any).matching(identifier: "settings.control.notificationSound").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()
        app.menuItems["Submarine"].click()
        app.typeKey("w", modifierFlags: .command)
        send(app, "Tell me a long story")
        app.typeKey("h", modifierFlags: .command)  // hide AntiChat: unfocused without launching another app (Q-015 catch-up)
        XCTAssertEqual(waitForRequests(1).first?.sound, "Submarine.aiff")
    }

    @MainActor
    func testDeniedBanner() {
        let app = launch(permission: "denied")
        app.typeKey(",", modifierFlags: .command)
        let banner = app.descendants(matching: .any).matching(identifier: "notificationsDeniedBanner").firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertTrue(banner.staticTexts["Notifications are off."].exists)
        banner.buttons["Open System Settings"].click()
        let opened = spy.deletingLastPathComponent().appendingPathComponent("opened-urls.txt")
        let end = Date().addingTimeInterval(5)
        while Date() < end, (try? String(contentsOf: opened, encoding: .utf8)) == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertEqual((try? String(contentsOf: opened, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=app.antichat.AntiChat")
    }
}
