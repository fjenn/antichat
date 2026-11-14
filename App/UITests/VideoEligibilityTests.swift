// AT-046 AC1 UI leg (M5.T08; R-046 AC1, R-040 AC4): on `-FakeHardware T0` and `T1` Video is dimmed with its reason
// ("Needs 24 GB memory") on every surface — the onboarding Video card, the + menu's Create video row (disabled, the
// reason as tooltip / grey line) and Settings → Capabilities' Video row — and never absent; a video request on such a
// Mac gets the explanation card (`video.notEligible` + "You can still make images.") with no button and no retry.
// Video ships since M5.T14 (ModelPack.shipped), so the onboarding card and the Capabilities row show the hardware reason.
// Committed, not run on this Mac (Q-015: XCUITest cannot start); VideoEligibilityTests (AntiChatUIModuleTests) cover
// the same states in-process.
import XCTest

final class VideoEligibilityTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ tier: String, onboarding: Bool, script: String = "YES") -> XCUIApplication {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-uitest-video-elig-\(UUID().uuidString)")
        let app = XCUIApplication.foreground()
        app.launchArguments = ["-ANTICHAT_DEV_CONTAINER", container.path, "-ApplePersistenceIgnoreState", "YES",
                               "-FakeHardware", tier, "-UseScriptedEngine", script] + (onboarding ? ["-ResetOnboarding", "YES"] : ["-SkipOnboarding", "YES"])  // test launches skip onboarding unless reset
        app.launch()
        app.activate()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    func testDimmedEverywhereT0T1() {
        for tier in ["T0", "T1"] {
            // 1. Onboarding step 2: the Video card is there, dimmed, with the reason.
            let onb = launch(tier, onboarding: true)
            onb.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Get started' OR label BEGINSWITH[c] 'Continue'")).firstMatch.click()
            let card = element(onb, "onb.pack.video")
            XCTAssertTrue(card.waitForExistence(timeout: 15), "\(tier): Video card absent")
            // The card is one button whose label reads its lines ("Video, Make clips, Needs 24 GB memory"); the size
            // line has no element of its own (Q-015 r2).
            let size = element(onb, "onb.pack.video.size")
            let cardText = size.exists ? size.displayText : card.label
            XCTAssertTrue(cardText.contains("Needs 24 GB memory"), "\(tier) onboarding: \(cardText)")
            add(XCTAttachment(screenshot: onb.windows.firstMatch.screenshot()))
            onb.terminate()

            // 2. + menu: Create video listed, disabled, tooltip/grey line = reason.
            let app = launch(tier, onboarding: false)
            XCTAssertTrue(element(app, "composerText").waitForExistence(timeout: 15))
            element(app, "composerAdd").click()
            let row = element(app, "addRow.video")
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(tier): Create video absent")
            XCTAssertTrue(row.value as? String == "Needs 24 GB memory", "\(tier) + menu: \(String(describing: row.value))")
            row.click()
            XCTAssertTrue(row.exists, "a disabled row does nothing")
            add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
            app.typeKey(.escape, modifierFlags: [])

            // 3. Settings → Capabilities: the Video row, dimmed, with the reason.
            app.typeKey(",", modifierFlags: .command)
            element(app, "settings.nav.capabilities").click()
            let video = element(app, "settings.pack.video")
            XCTAssertTrue(video.waitForExistence(timeout: 10), "\(tier): Capabilities Video row absent")
            XCTAssertTrue(element(app, "settings.pack.video.state").displayText.contains("Needs 24 GB memory"), "\(tier) Capabilities")
            add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
            app.terminate()
        }
    }

    @MainActor
    func testIneligibleRequestExplains() {
        // The chat model asks for the clip (`create_video`, as T1's tool-capable model does); the turn answers with
        // the explanation card. The basic script only said hello: the router's own video cue needs the embedding
        // model, which a test container does not have (Q-015 r2).
        let turn = AntiChatUIApp.turnScript(#"{"t":"toolCallDone","id":"call_1","name":"create_video","args":"{\"prompt\":\"waves rolling onto a beach\"}","delayMs":1}"#)
        let app = launch("T1", onboarding: false, script: turn)
        let input = element(app, "composerText")
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.click()
        input.typeText("Make a short video of waves rolling onto a beach")
        input.typeKey(.return, modifierFlags: [])
        let text = element(app, "installCardText")
        XCTAssertTrue(text.waitForExistence(timeout: 20))
        XCTAssertTrue(text.displayText.hasPrefix("Video needs 24 GB memory. This Mac has"), text.displayText)
        XCTAssertEqual(element(app, "installCardSecondary").displayText, "You can still make images.")
        XCTAssertFalse(element(app, "installCardInstall").exists, "no button")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Retry'")).firstMatch.exists, "no retry")
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }
}
