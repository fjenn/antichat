// AT-290 / AT-044 / AT-NFR-B2 / AT-NFR-B4 (video parts) UI legs (M5.T09; R-290 AC1–AC3, R-044 AC1/AC2): the plan card
// before any video job — rewritten prompt, length / shape presets, estimate, [Start] [Change] [Cancel]; the 10 s
// countdown only for an explicit request on AC power, no Low Power, estimate ≤ 5 min and chat not paused; the battery
// (< 20 %) and Low Power asks; Change edits the presets inline and re-estimates; Cancel removes the card; steps and
// resolution only in Settings → Capabilities → Advanced.
// The card reaches the chat with M5.T10 (video route, Create video chip, Animate): until then these legs fail at the
// first `videoPlanCard` wait. Committed, not run on this Mac (Q-015: XCUITest cannot start); VideoPlanCardTests
// (AntiChatUIModuleTests) and VideoPlanPolicyTests / VideoPresetsTests (AntiChatHarnessTests) cover the same states
// in-process. Hardware: `-FakeHardware T3` (chat stays resident) unless the leg says otherwise; the scripted engine
// writes the `create_video` call.
import XCTest

final class VideoPlanTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Default Mac: T3 M4 Max 64 GB (S3, B 51.5). Since the runtime-0.3.5 table (b61b95b45 / e8fe19986) the M4 Pro 48 GB
    /// T3 fixture (S2) estimates 720p Short at about 8 min (no countdown) and no longer offers i2v-480p-short; the M4 Max
    /// keeps chat resident, counts down an explicit 720p request (270 s, under 5 min) and offers image-to-video.
    @MainActor
    private func launch(power: String = "ac", tier: String = "t3-m4max-64", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-SkipOnboarding", "YES",
                                            "-UseScriptedEngine", "YES", "-UseScriptedVideoEngine", "YES",
                                            "-FakeHardware", tier, "-FakePower", power,
                                            "-FakeInstalledPacks", "chat,video"] + extra)
        app.launch()
        app.activate()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// An explicit request: `+ → Create video` chip, then the prompt.
    @MainActor
    private func requestWithChip(_ app: XCUIApplication, _ text: String = "waves rolling onto a beach at dusk") {
        let input = element(app, "composerText")
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        element(app, "composerAdd").click()
        let row = element(app, "addRow.video")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        input.click()
        input.typeText(text)
        input.typeKey(.return, modifierFlags: [])
    }

    /// An inferred request (no chip, no video word): the router infers video.
    @MainActor
    private func requestInferred(_ app: XCUIApplication) {
        let input = element(app, "composerText")
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.click()
        input.typeText("show me the ocean moving at sunset")
        input.typeKey(.return, modifierFlags: [])
    }

    @MainActor
    private func card(_ app: XCUIApplication) -> XCUIElement {
        let c = element(app, "videoPlanCard")
        XCTAssertTrue(c.waitForExistence(timeout: 30), "plan card")
        return c
    }

    @MainActor
    private func assertWaits(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        _ = card(app)
        XCTAssertFalse(element(app, "videoPlan.countdown").exists, "no countdown", file: file, line: line)
        XCTAssertTrue(element(app, "videoPlan.start").isEnabled, file: file, line: line)
        sleep(11)
        XCTAssertTrue(element(app, "videoPlanCard").exists, "still waiting for Start", file: file, line: line)
        XCTAssertFalse(element(app, "videoJobCard").exists, "no job started", file: file, line: line)
    }

    @MainActor
    func testPlanCardContents() {
        let app = launch()
        requestWithChip(app)
        _ = card(app)
        XCTAssertFalse((element(app, "videoPlan.prompt").value as? String ?? "").isEmpty, "rewritten prompt")
        XCTAssertTrue(element(app, "videoPlan.presets").displayText.contains("Short"))
        XCTAssertTrue(element(app, "videoPlan.presets").displayText.contains("Landscape"))
        XCTAssertTrue(element(app, "videoPlan.estimate").displayText.hasPrefix("About "))
        XCTAssertTrue(element(app, "videoPlan.estimate").displayText.contains("720p"))
        for id in ["videoPlan.start", "videoPlan.change", "videoPlan.cancel"] { XCTAssertTrue(element(app, id).exists, id) }
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }

    @MainActor
    func testCountdownAutoStartsWhenAllowed() {
        let app = launch(power: "ac")
        requestWithChip(app)
        _ = card(app)
        let countdown = element(app, "videoPlan.countdown")
        XCTAssertTrue(countdown.exists)
        XCTAssertTrue(countdown.displayText.hasPrefix("Starting in "), countdown.displayText)
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
        XCTAssertTrue(element(app, "videoJobCard").waitForExistence(timeout: 15), "started by itself after 10 s")
        XCTAssertFalse(element(app, "videoPlanCard").exists)
    }

    @MainActor
    func testWaitsForStartOnInferredIntent() {
        let app = launch(power: "ac")
        requestInferred(app)
        assertWaits(app)
    }

    @MainActor
    func testWaitsOnBattery() {
        let app = launch(power: "battery:60")
        requestWithChip(app)
        assertWaits(app)
        XCTAssertFalse(element(app, "videoPlan.ask").exists, "60 %: no battery ask")
    }

    @MainActor
    func testBatteryAskBelow20() {
        let app = launch(power: "battery:15")
        requestWithChip(app)
        _ = card(app)
        XCTAssertEqual(element(app, "videoPlan.ask").displayText, "You're on battery (15%). Start anyway?")
        XCTAssertEqual(element(app, "videoPlan.cancel").displayText, "Later")
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
        element(app, "videoPlan.start").clickReliably()
        XCTAssertTrue(element(app, "videoJobCard").waitForExistence(timeout: 10), "Start anyway")
    }

    @MainActor
    func testLowPowerAsks() {
        let app = launch(power: "lowpower")
        requestWithChip(app)
        _ = card(app)
        XCTAssertEqual(element(app, "videoPlan.ask").displayText, "Low Power Mode is on. Start anyway?")
        XCTAssertFalse(element(app, "videoPlan.countdown").exists)
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
        element(app, "videoPlan.cancel").clickReliably()
        XCTAssertFalse(element(app, "videoPlanCard").exists, "Later removes the card")
    }

    @MainActor
    func testWaitsWhenEstimateOver5Min() {
        // T3 M4 Pro (S2) with Advanced → Video length 5 s: 720p, 121 frames ≈ 7 min on the scaled S2 row
        // (catalog/video-speed.yaml) — no countdown even on AC with the chip.
        let app = launch(power: "ac", tier: "t3-m4pro-48", extra: ["-videoAdvancedSeconds", "5"])
        requestWithChip(app)
        assertWaits(app)
    }

    @MainActor
    func testWaitsWhenChatWouldPause() {
        // T2 unloads chat for the job (cross-task contract 2): never auto-start.
        let app = launch(power: "ac", tier: "T2")
        requestWithChip(app)
        assertWaits(app)
    }

    @MainActor
    func testChangeEditsPresets() throws {
        let app = launch(power: "battery:60")
        requestWithChip(app)
        _ = card(app)
        let before = element(app, "videoPlan.estimate").displayText
        element(app, "videoPlan.change").clickReliably()
        XCTAssertTrue(element(app, "videoPresetPicker").waitForExistence(timeout: 5))
        element(app, "videoPlan.shape.portrait").click()
        XCTAssertTrue(element(app, "videoPlan.shape.portrait").isSelected)
        // Q-015 r4: a shape pick keeps the pixel count (720p either way), so its estimate line can be the same words;
        // the re-estimate is checked on a length pick, which changes the clip's seconds.
        let lengths = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'videoPlan.length.'"))
        // Where the tier offers one length only, the length row is hidden (VideoPresetPicker): the shape pick then
        // re-plans to the same pixels and seconds, and the estimate stays the same words.
        XCTAssertTrue(element(app, "videoPlan.estimate").displayText.contains("on this Mac"), "the re-planned card keeps its estimate")
        if let length = lengths.allElementsBoundByIndex.first(where: { !$0.isSelected }) {
            length.click()
            XCTAssertTrue(length.wait(5) { $0.isSelected })
            XCTAssertTrue(element(app, "videoPlan.estimate").wait(5) { $0.displayText != before }, "re-estimated")
        }
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }

    @MainActor
    func testCancelRemovesCard() {
        let app = launch(power: "ac")
        requestWithChip(app)
        _ = card(app)
        element(app, "videoPlan.cancel").clickReliably()
        XCTAssertFalse(element(app, "videoPlanCard").exists)
        sleep(11)
        XCTAssertFalse(element(app, "videoJobCard").exists, "no job written")
    }

    @MainActor
    func testEstimateShownBeforeStart() {
        let app = launch(power: "battery:60")
        requestWithChip(app)
        _ = card(app)
        XCTAssertTrue(element(app, "videoPlan.estimate").displayText.contains("on this Mac"))
        XCTAssertFalse(element(app, "videoJobCard").exists, "nothing runs before Start")
    }

    @MainActor
    func testAdvancedOnlyInSettings() {
        let app = launch(power: "battery:60")
        requestWithChip(app)
        let c = card(app)
        XCTAssertFalse(c.descendants(matching: .any).matching(NSPredicate(format: "identifier CONTAINS[c] 'steps' OR identifier CONTAINS[c] 'resolution'")).firstMatch.exists,
                       "no step / resolution control on the plan card")
        app.typeKey(",", modifierFlags: .command)
        element(app, "settings.nav.capabilities").click()
        element(app, "settings.row.capabilities.advanced").clickDisclosure()
        // Q-015 r5: the group opens at the bottom of the Form, which builds rows below the fold lazily.
        let detail = app.scrollViews.matching(identifier: "settings.detail.capabilities").firstMatch
        for id in ["settings.row.videoAdvancedSteps", "settings.row.videoAdvancedResolution", "settings.row.videoAdvancedSeconds"] {
            detail.scrollUntilVisible(element(app, id))
            XCTAssertTrue(element(app, id).waitForExistence(timeout: 10), id)
        }
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }
}
