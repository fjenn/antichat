// AT-291 + AT-285 UI legs (M4.T04, the runner-dependent checks written for M4.T03): JobQueueTests (one at a time with
// positions, Interrupted · Restart after a force-quit, a helper crash marks the job lost, the quit prompt, closing the
// window keeps the job), BlockedMediaTests (`-ScriptedSafetyVerdict block`: the neutral tile with `media.imageBlocked`
// verbatim, nothing on disk, counter +1; Normal and Evil, offline) and SafetyMissingTests (no detectors: Create image
// shows `safety.missing` with the repair size; no job submitted).
// Committed, not run on this Mac (Q-015: XCUITest cannot start). The forced verdict needs the AntiChat-UITests build
// configuration (A-M4-T03a b), and the chat → create_image → queue path lands with M4.T06; the card identifiers
// (`imageJobCard`, `imageJobWaiting`, `imageJobInterrupted`) with ImageJobCard (M4.T08). In-process legs that run
// today: MediaJobQueueTests, MediaJobRunnerTests, R241PathTraceTests (tools/at/at-285-runner.sh), MediaJobQueueXPCTests.
import AppKit
import XCTest

enum MediaUIApp {
    static func script(_ name: String, _ json: String) -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).json")
        try? Data(json.utf8).write(to: url)
        return url.path
    }

    static let createImageTurn = #"{"t":"toolCallDone","id":"call_1","name":"create_image","args":"{\"prompt\":\"a lighthouse at dusk\",\"aspect\":\"3:2\"}","delayMs":1}"#

    @MainActor
    static func launch(container: URL? = nil, imageScript: String = #"{"steps":4,"delayMs":200}"#, chatScript: String? = nil,
                       env: [String: String] = [:], _ extra: [String] = []) -> XCUIApplication {
        let dir = container ?? FileManager.default.temporaryDirectory.appendingPathComponent("antichat-uitest-media-\(UUID().uuidString)")
        let turn = FileManager.default.temporaryDirectory.appendingPathComponent("create-image-\(UUID().uuidString).jsonl")
        try? Data(((chatScript ?? createImageTurn) + "\n").utf8).write(to: turn)
        let app = XCUIApplication.foreground()
        app.launchArguments = ["-ANTICHAT_DEV_CONTAINER", dir.path, "-ApplePersistenceIgnoreState", "YES", "-SkipOnboarding", "YES",
                               "-UseScriptedEngine", turn.path, "-UseScriptedImageEngine", script("image", imageScript),
                               "-FakePackState", "photo=ready",
                               // A tool-capable chat slot: a fresh container's default is the chat-only starter, which is
                               // offered no tools (D-023 a), so the scripted create_image call would never run (M4.T16).
                               "-ChatModel", "chat-9b-q4"] + extra
            // The Mac's own power state must not change the result: on battery / Low Power Mode the picture steps down
            // to 640² (16:9 → 832 × 512, 1.63; RC e8fe19986 ImageEntryTests). AC unless the leg names its power.
            + (extra.contains("-FakePower") ? [] : ["-FakePower", "ac"])
        for (k, v) in env { app.launchEnvironment[k] = v }
        // The DEBUG A/B switch of the accessibility hit-test workaround (AntiChatApplication), from the runner's
        // environment (`TEST_RUNNER_ANTICHAT_AX_HIT_REFINE=0`): diagnosis runs only.
        if let ab = ProcessInfo.processInfo.environment["ANTICHAT_AX_HIT_REFINE"] { app.launchEnvironment["ANTICHAT_AX_HIT_REFINE"] = ab }
        app.launch()
        app.activate()
        return app
    }

    @MainActor
    static func send(_ app: XCUIApplication, _ text: String) {
        let input = app.descendants(matching: .any).matching(identifier: "composerText").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.clickReliably()  // r5: with jobs in the transcript XCUITest finds no hit point for the composer ("Unable to find hit point", M9.T03); a real click at its centre
        input.typeText(text)
        input.typeKey(.return, modifierFlags: [])
    }

    @MainActor
    static func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
}

final class JobQueueTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testOneAtATimeWithPositions() {
        // r6: one chat's turn waits for its picture (ImageTools awaits `queue.finished`), so sends 2 and 3 in the same
        // chat were queued follow-ups and their jobs never overlapped (r3: three finished cards, no waiting one). Jobs
        // wait in line when they come from different chats: one window per picture (⌥⌘N; the new window's composer
        // has the focus), all within the first job's run.
        let app = MediaUIApp.launch(imageScript: #"{"steps":40,"delayMs":300}"#)
        MediaUIApp.send(app, "Picture 1: a lighthouse")
        let windows = app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'main-'"))
        for i in 2...3 {
            app.typeKey("n", modifierFlags: [.command, .option])
            let opened = Date().addingTimeInterval(5)
            while windows.count < i, Date() < opened { Thread.sleep(forTimeInterval: 0.1) }
            XCTAssertEqual(windows.count, i, "⌥⌘N opened window \(i)")
            app.typeText("Picture \(i): a lighthouse")
            app.typeKey(.return, modifierFlags: [])
        }
        let waiting = app.descendants(matching: .any).matching(identifier: "imageJobWaiting")
        XCTAssertTrue(waiting.firstMatch.waitForExistence(timeout: 20))
        let lineBy = Date().addingTimeInterval(10)
        while waiting.count < 2, Date() < lineBy { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(waiting.count, 2, "two jobs wait while one runs")
        // The card (a `.contain` group) has no text of its own: its status line is a child. Position 1 reads
        // `img.waiting` ("Waiting for the current job"), position 2 `job.waitingPosition` ("… · 2 in line", M4 copy).
        let lines = waiting.allElementsBoundByIndex.map { card in
            card.staticTexts.allElementsBoundByIndex.map(\.displayText).joined(separator: " | ")
        }
        XCTAssertTrue(lines.contains { $0.contains("Waiting for the current job") && !$0.contains("in line") }
                      && lines.contains { $0.contains("2 in line") }, "\(lines)")
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }

    @MainActor
    func testInterruptedRestartAfterForceQuit() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-uitest-media-\(UUID().uuidString)")
        let app = MediaUIApp.launch(container: dir, imageScript: #"{"steps":60,"delayMs":500}"#)
        MediaUIApp.send(app, "A lighthouse at dusk")
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard").waitForExistence(timeout: 20))
        if let pid = app.processID { kill(pid, SIGKILL) }  // this app only: other worktrees run the same bundle id
        _ = app.wait(for: .notRunning, timeout: 15)
        let again = MediaUIApp.launch(container: dir, imageScript: #"{"steps":4,"delayMs":50}"#)
        // Q-015 r5: a relaunch opens a new chat (`-ApplePersistenceIgnoreState YES`, no window restoration); the job's
        // chat is the sidebar row, as the user would open it.
        let row = again.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chatRow.' AND label BEGINSWITH 'A lighthouse at dusk'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the chat of the interrupted job")
        row.clickReliably()
        let interrupted = MediaUIApp.element(again, "imageJobInterrupted")
        XCTAssertTrue(interrupted.waitForExistence(timeout: 20))
        XCTAssertTrue(interrupted.displayText.contains("Interrupted"), interrupted.displayText)
        MediaUIApp.element(again, "imageJobRestart").click()
        XCTAssertTrue(MediaUIApp.element(again, "imageJobCard.result").waitForExistence(timeout: 60))
    }

    @MainActor
    func testHelperCrashMarksLost() {
        let app = MediaUIApp.launch(imageScript: #"{"steps":6,"delayMs":200,"crashAtStep":2}"#)
        MediaUIApp.send(app, "A lighthouse at dusk")
        XCTAssertTrue(MediaUIApp.element(app, "imageJobInterrupted").waitForExistence(timeout: 30))
    }

    @MainActor
    func testQuitPrompt() {
        let app = MediaUIApp.launch(imageScript: #"{"steps":60,"delayMs":500}"#)
        MediaUIApp.send(app, "A lighthouse at dusk")
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard").waitForExistence(timeout: 20))
        app.typeKey("q", modifierFlags: .command)
        let sheet = app.dialogs.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts["A picture or video is still being made."].exists)
        sheet.buttons["Keep making it"].click()
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard").exists, "Keep making it keeps the app and the job")
        app.typeKey("q", modifierFlags: .command)
        app.dialogs.firstMatch.buttons["Quit anyway"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    }

    @MainActor
    func testWindowCloseKeepsJob() {
        let app = MediaUIApp.launch(imageScript: #"{"steps":20,"delayMs":200}"#)
        MediaUIApp.send(app, "A lighthouse at dusk")
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard").waitForExistence(timeout: 20))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertNotEqual(app.state, .notRunning, "closing the window does not quit or stop the job")
        app.typeKey("n", modifierFlags: .command)
        // Q-015 r5: ⌘N opens a window on a NEW chat; the job's chat is its sidebar row (the result is drawn there).
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chatRow.' AND label BEGINSWITH 'A lighthouse at dusk'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the job's chat in the new window's sidebar")
        row.clickReliably()
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard.result").waitForExistence(timeout: 60), "the job finished with no window")
    }
}

final class BlockedMediaTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func blocked(evil: Bool) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-uitest-blocked-\(UUID().uuidString)")
        let app = MediaUIApp.launch(container: dir, ["-ScriptedSafetyVerdict", "block", "-OfflineOnly", "YES", "-FakeEvilEnabled", "YES"])
        if evil { app.typeKey("e", modifierFlags: [.command, .shift]) }  // ⇧⌘E → Evil chat (J07)
        MediaUIApp.send(app, "A lighthouse at dusk")
        let tile = MediaUIApp.element(app, "media.blocked")
        XCTAssertTrue(tile.waitForExistence(timeout: 30))
        XCTAssertEqual(tile.displayText, "This image can't be shown.", "the copy key verbatim, no detail")
        XCTAssertFalse(MediaUIApp.element(app, "imageJobRestart").exists, "no retry")
        let media = dir.appendingPathComponent("Media")
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: media.path)) ?? []).isEmpty, "nothing on disk")
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }

    /// `-ScriptedSafetyVerdict` exists only in a `-DANTICHAT_UI_TESTING` build (MediaOutputGate: never in Debug or
    /// Release); the project has no such configuration yet (A-M4-T03a b), so a Debug run cannot force the verdict.
    private func requireUITestingBuild() throws {
        guard ProcessInfo.processInfo.environment["ANTICHAT_UI_TESTING_BUILD"] == "1" else {
            throw XCTSkip("needs the -DANTICHAT_UI_TESTING app build (no such Xcode configuration yet); tools/at/at-285-runner.sh covers the gate in-process")
        }
    }

    @MainActor func testBlockedNormalOffline() throws { try requireUITestingBuild(); blocked(evil: false) }
    @MainActor func testBlockedEvilOffline() throws { try requireUITestingBuild(); blocked(evil: true) }
}

final class SafetyMissingTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testMissingDetectorsShowRepairAndRunNoJob() {
        // Q-015 r4: `-FakePackState csc=absent` is no pack and replaced `photo=ready` (one value per option), so the
        // card asked to install Photo. Detectors are made "not installed" the DEBUG way (ANTICHAT_NO_DETECTORS=1).
        let app = MediaUIApp.launch(env: ["ANTICHAT_NO_DETECTORS": "1"])
        MediaUIApp.send(app, "A lighthouse at dusk")
        let card = MediaUIApp.element(app, "safety.missing")
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertTrue(MediaUIApp.element(app, "safety.missing.repair").displayText.contains(" — repair ("), "the copy key with the repair size")
        XCTAssertFalse(MediaUIApp.element(app, "imageJobCard").exists, "no job is submitted")
    }
}
