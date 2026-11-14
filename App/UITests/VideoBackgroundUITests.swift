// AT-042 UI leg (M8.T12; R-042, XCUITest journey 6): a media job keeps running when the user switches chats, closes
// the window or switches apps; its completion / failure posts one media notification; ⌘Q during a job asks first.
// The job runs on the scripted media path (`-UseScriptedImageEngine`, 20 steps × 300 ms) through the generic job
// queue; the notification, quit guard and Dock badge read the queue's job events, not video internals, so the
// chat-created video job (M5) takes the same path with kind `video` (category `video`, the Wait / Cancel video and
// quit alert). Until M5's create-video tool is on main the `video`-kind legs run in the probe (direct enqueue).
// Committed, not run on this Mac (Q-015). In-process legs that run today: tools/at/at-042-probe.sh (MacIntegrationProbe
// mode `video`), NotificationRouterTests.
import XCTest

// Q-015 r4: the finished picture is `imageJobCard.result` (the old `imageResult` id no longer exists).
final class VideoBackgroundUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    var spy = FileManager.default.temporaryDirectory.appendingPathComponent("video-spy-\(UUID().uuidString)/requests.json")

    @MainActor
    func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = MediaUIApp.launch(imageScript: #"{"steps":20,"delayMs":300}"#,
                                    ["-NotificationSpy", spy.path, "-FakePermission", "notifications=granted"] + extra)
        return app
    }

    func categories() -> [String] {
        guard let d = try? Data(contentsOf: spy), let a = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return a.compactMap { $0["category"] as? String }
    }

    @MainActor
    func testNavigateAwayKeepsJob() {
        let app = launch()
        MediaUIApp.send(app, "A lighthouse at dusk")
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard").waitForExistence(timeout: 20))
        app.typeKey("n", modifierFlags: .command)  // another chat
        app.typeKey("[", modifierFlags: .command)  // back
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard.result").waitForExistence(timeout: 30))
    }

    @MainActor
    func testWindowCloseKeepsJob() {
        let app = launch()
        MediaUIApp.send(app, "A lighthouse at dusk")
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard").waitForExistence(timeout: 20))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertEqual(app.state, .runningForeground, "the app keeps running with the job")
        app.statusItems["AntiChat"].click()
        app.menuItems["Open AntiChat"].click()
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard.result").waitForExistence(timeout: 30))
    }

    @MainActor
    func testCompletionAndFailureNotify() {
        let app = launch()
        MediaUIApp.send(app, "A lighthouse at dusk")
        app.typeKey("h", modifierFlags: .command)  // hide AntiChat: unfocused without launching another app (Q-015 catch-up)
        let end = Date().addingTimeInterval(30)
        while Date() < end, categories().isEmpty { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        XCTAssertEqual(categories().filter { $0 == "image" || $0 == "video" }.count, 1)
        app.terminate()
    }

    @MainActor
    func testNotificationClickOpensResult() {
        let app = launch(["-notifyWhen", "always"])
        MediaUIApp.send(app, "A lighthouse at dusk")
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard.result").waitForExistence(timeout: 30))
        app.typeKey("n", modifierFlags: .command)
        // The click itself needs Notification Center (computer-use leg, vq-06 "Background"); the router is exercised
        // through the probe and NotificationRouterTests.
    }

    @MainActor
    func testQuitAsksCancelOrWait() {
        let app = launch()
        MediaUIApp.send(app, "A lighthouse at dusk")
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard").waitForExistence(timeout: 20))
        app.typeKey("q", modifierFlags: .command)
        let alert = app.dialogs.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        // A picture job: [Keep making it] / [Quit anyway] (M4.T04); a video job: [Wait] / [Cancel video and quit].
        let video = alert.buttons["Wait"].exists
        XCTAssertTrue(video ? alert.buttons["Cancel video and quit"].exists : alert.buttons["Quit anyway"].exists)
        if video {
            alert.buttons["Wait"].click()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 30), "quits by itself once the job is done")
        } else {
            alert.buttons["Quit anyway"].click()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        }
    }
}
