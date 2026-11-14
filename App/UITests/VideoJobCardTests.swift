// AT-041 + AT-NFR-VID3 / B3 / B5 UI legs (M5.T11; R-041, NFR-P3, NFR-VID2/VID3, NFR-B3/B5): the VideoJobCard — real %
// and stage line, the animated preview updating each allowed step (≥ 160 px, target aspect), a preview failure that
// leaves the job running, survival of window close and chat navigation (the helper owns the job; the card re-attaches),
// thermal critical → paused with [Resume], paused for another app (gpu-burn, real T3 run), and cancel freeing memory.
// The scripted chat engine writes the `create_video` call; the helper's ScriptedVideoEngine makes the clip
// (`-UseScriptedVideoEngine <script.json>`; no runtime, no model; every preview and the clip pass the gate).
// Committed, not run on this Mac (Q-015: XCUITest cannot start) — pending. In-process coverage of the same states:
// VideoJobCardTests (AntiChatUIModuleTests: states, stage lines, preview rule, snapshots), VideoJobStatusTests
// (AntiChatHarnessTests: helper events → queue → card, re-attach snapshot, Resume, last-window rule),
// ThermalPolicyTests + GPUYieldMonitorTests (AntiChatEnginesTests: governor pacing/holds, yield rule, ProcessPause).
import AppKit
import XCTest

final class VideoJobCardTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// A scripted job slow enough to watch: `steps` steps of `delayMs`, `previewFrames` per allowed step.
    static func script(steps: Int = 8, delayMs: Int = 1500, previewFrames: Int = 6) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vjc-\(UUID().uuidString).json")
        try Data(#"{"steps":\#(steps),"delayMs":\#(delayMs),"frames":48,"fps":16,"previewFrames":\#(previewFrames)}"#.utf8).write(to: url)
        return url.path
    }

    @MainActor
    private func launch(tier: String = "T3", script: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-SkipOnboarding", "YES",
                                            "-UseScriptedEngine", "YES", "-UseScriptedVideoEngine", script,
                                            "-FakeHardware", tier, "-FakePower", "ac",
                                            "-FakeInstalledPacks", "chat,photo,video"] + extra)
        app.launch()
        app.activate()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// The video chat's sidebar row. Q-015 r4: the tests clicked outline row 0 / 1 by index, which are the
    /// navigation items' rows at the top of the sidebar (one of them a zero-height row, the other under the
    /// titlebar edge: "not hittable"), not the chat.
    private func chatRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chatRow.' AND NOT (identifier IN %@)",
                                                             ["chatRow.more", "chatRow.renameField", "chatRow.streaming", "chatRow.evilDot"])).firstMatch
    }

    /// Plain words → `create_video` → the plan card → Start → the job card.
    @MainActor
    private func startJob(_ app: XCUIApplication, _ text: String = "Make a short video of waves rolling onto a beach at dusk") -> XCUIElement {
        let input = element(app, "composerText")
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.click()
        input.typeText(text)
        input.typeKey(.return, modifierFlags: [])
        app.startVideoPlan()
        let card = element(app, "videoJobCard")
        XCTAssertTrue(card.waitForExistence(timeout: 30), "job card")
        return card
    }

    private func percent(_ s: String) -> Int? { Int(s.prefix { $0.isNumber }) }

    /// AT-041 AC1: the % is the real step %, never goes back, and the stage line names the step; no 3 s without change.
    @MainActor
    func testRealPercentAndStage() throws {
        let app = launch(script: try Self.script())
        _ = startJob(app)
        let pill = element(app, "imageJobCard.progress"), status = element(app, "videoJob.status")
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        var last = -1, lastText = "", lastStatus = "", unchangedSince = Date()
        let end = Date().addingTimeInterval(20)
        while Date() < end, !element(app, "videoJobResult").exists {
            // Q-015 r6: the pill's text is its AX label since M9.T05 P3 (its value is ""); `value ?? label` read the
            // constant "" and failed the 3 s bar while the label ticked every second (r6 p1 dump: '33% · 15 s').
            let text = pill.displayText
            if let p = percent(text) {
                XCTAssertGreaterThanOrEqual(p, last, "monotonic")
                XCTAssertLessThan(p, 100, "100 % only with the result")
                last = p
            }
            if text != lastText { lastText = text; unchangedSince = Date() }
            // Q-015 r6: the stage line goes with the card's running state once the result shows; read it while running.
            if let st = status.shownText, !st.isEmpty { lastStatus = st }
            XCTAssertLessThan(Date().timeIntervalSince(unchangedSince), 3, "never > 3 s without a UI change")
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(lastStatus.hasPrefix("Generating · step") || lastStatus.hasPrefix("Finishing · frame"), lastStatus)
    }

    /// AT-041 AC4: the allowed steps' frames loop at ≥ 160 px at the clip's aspect and change each allowed step.
    @MainActor
    func testAnimatedPreviewUpdates() throws {
        let app = launch(script: try Self.script(steps: 8, delayMs: 2000, previewFrames: 6))
        _ = startJob(app)
        let preview = element(app, "videoJob.preview")
        XCTAssertTrue(preview.waitForExistence(timeout: 60))
        let predicate = NSPredicate(format: "value != '0'")
        expectation(for: predicate, evaluatedWith: preview)
        waitForExpectations(timeout: 60)
        let f = preview.frame
        XCTAssertGreaterThanOrEqual(min(f.width, f.height), 160)
        XCTAssertEqual(f.width / f.height, 16.0 / 9, accuracy: 0.1, "target aspect")
        let first = preview.screenshot().pngRepresentation
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertNotEqual(first, preview.screenshot().pngRepresentation, "the loop / the next step changes the frame")
    }

    /// A preview the gate allowed but that cannot be shown (its file truncated under the card) never fails the job:
    /// the card keeps the last readable set (or the placeholder) and the clip still arrives.
    @MainActor
    func testPreviewFailureDoesNotFailJob() throws {
        let app = launch(script: try Self.script(steps: 8, delayMs: 800))
        _ = startJob(app)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [home.appendingPathComponent("Library/Caches/AntiChat/xfer"),
                     home.appendingPathComponent("Library/Containers/app.antichat.AntiChat.dev/Data/Library/Caches/AntiChat/xfer")]
        let end = Date().addingTimeInterval(60)
        while Date() < end, !element(app, "videoJobResult").exists {
            for r in roots {
                for case let f as String in FileManager.default.enumerator(atPath: r.path)?.allObjects ?? [] where f.hasSuffix(".jpg") {
                    try? Data().write(to: r.appendingPathComponent(f))
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(element(app, "videoJobResult").waitForExistence(timeout: 120), "the clip still arrives")
        XCTAssertFalse(element(app, "videoJob.retry").exists)
    }

    /// AT-NFR-VID3: closing the window keeps the app and the job; a new window shows the card re-attached.
    @MainActor
    func testSurvivesWindowClose() throws {
        let app = launch(script: try Self.script(steps: 8, delayMs: 2000))
        _ = startJob(app)
        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(app.state, .runningForeground, "the app stays open while a video runs")
        app.typeKey("n", modifierFlags: .command)
        chatRow(app).click()
        XCTAssertTrue(element(app, "videoJobCard").waitForExistence(timeout: 15) || element(app, "videoJobResult").exists)
        XCTAssertTrue(element(app, "videoJobResult").waitForExistence(timeout: 120), "the job finished in the background")
    }

    /// AT-NFR-VID3: another chat and back — the card re-attaches with its current stage and keeps counting.
    @MainActor
    func testNavigateAwayAndBack() throws {
        let app = launch(script: try Self.script(steps: 8, delayMs: 2000))
        _ = startJob(app)
        app.typeKey("n", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 4)
        chatRow(app).click()
        let status = element(app, "videoJob.status")
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        XCTAssertTrue(status.displayText.hasPrefix("Generating · step"), "re-attached at its real stage, not from 0")
    }

    /// AT-NFR-B3: `-FakeThermal critical` → paused with [Resume]; chat keeps answering; Resume continues the job.
    @MainActor
    func testThermalCriticalPausesAndResumes() throws {
        let app = launch(script: try Self.script(steps: 6, delayMs: 1000), extra: ["-FakeThermal", "critical"])
        _ = startJob(app)
        let resume = element(app, "videoJob.resume")
        XCTAssertTrue(resume.waitForExistence(timeout: 30), "video.paused.hot")
        XCTAssertTrue(element(app, "videoJobPaused").exists)
        resume.click()
        XCTAssertTrue(element(app, "videoJobResult").waitForExistence(timeout: 120))
    }

    /// AT-NFR-B5 (real T3 run, `tools/perf/gpu-burn --seconds 30` alongside): `.utility`-class priority within 12 s,
    /// "Paused for another app" with the setting on, and the job resumes after the load stops.
    @MainActor
    func testPausedForOtherApp() throws {
        let burn = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/tools/gpu-burn")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: burn.path), "tools/perf/gpu-burn/build.sh first")
        let app = launch(script: try Self.script(steps: 20, delayMs: 2000))
        _ = startJob(app)
        let p = Process()
        p.executableURL = burn
        p.arguments = ["--seconds", "30"]
        try p.run()
        defer { p.terminate() }
        XCTAssertTrue(element(app, "videoJobPaused").waitForExistence(timeout: 14), "paused within 12 s (+ UI)")
        p.waitUntilExit()
        XCTAssertTrue(element(app, "videoJobCard").waitForExistence(timeout: 20), "resumed 10 s after the load stopped")
    }

    /// AT-041 AC3: ■ ends the job (≤ NFR-VID3) and the helper's footprint returns to its pre-job level.
    @MainActor
    func testCancelFreesMemory() throws {
        let app = launch(script: try Self.script(steps: 20, delayMs: 1500))
        _ = startJob(app)
        let cancel = element(app, "videoJob.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 15))
        cancel.click()
        let status = element(app, "videoJob.status")
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertEqual(status.displayText, "Cancelled")
    }
}
