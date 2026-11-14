// AT-040 AC1/AC2/AC4 + AT-043 AC1 UI legs (M5.T10; R-040, R-043): video starts from plain words, the `+ → Create video`
// chip, an attached image (I2V), Animate on an image card and on an image tile; a finished job posts the completion
// event; an ineligible Mac explains itself (no error). The scripted chat engine writes the `create_video` call and the
// helper's ScriptedVideoEngine makes the clip (`-UseScriptedVideoEngine`; no runtime, no model, outputs gated).
// Committed, not run on this Mac (Q-015: XCUITest cannot start) — pending. In-process coverage of the same states:
// VideoIntentTests / VideoToolsTests (AntiChatHarnessTests), VideoEntryModelTests (AntiChatUIModuleTests),
// VideoQueueRoundTripTests (AntiChatEngineHostTests), MediaCompletionEventsTests (AntiChatPlatformTests).
import AppKit
import XCTest

final class VideoEntryTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Default Mac: T3 M4 Max 64 GB (S3, B 51.5). Since the runtime-0.3.5 table (b61b95b45 / e8fe19986) the M4 Pro 48 GB
    /// T3 fixture (S2) estimates 720p Short at about 8 min (no countdown) and no longer offers i2v-480p-short; the M4 Max
    /// keeps chat resident, counts down an explicit 720p request (270 s, under 5 min) and offers image-to-video.
    @MainActor
    private func launch(tier: String = "t3-m4max-64", script: String = "YES", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-SkipOnboarding", "YES",
                                            "-UseScriptedEngine", script, "-UseScriptedVideoEngine", "YES",
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

    @MainActor
    private func send(_ app: XCUIApplication, _ text: String) {
        let input = element(app, "composerText")
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.click()
        input.typeText(text)
        input.typeKey(.return, modifierFlags: [])
    }

    /// Q-015 r5: Open (`videoJob.open`) is an item of the card's ⋯ menu (`videoJob.more`, M5.T12), so it exists only
    /// while that menu is open.
    @MainActor
    static func offersOpen(_ app: XCUIApplication) -> Bool {
        let more = app.descendants(matching: .any).matching(identifier: "videoJob.more").firstMatch
        guard more.waitForExistence(timeout: 5) else { return false }
        more.clickReliably()
        // A SwiftUI menu's items are NSMenuItems: the id may not reach them, the title ("Open", `file.open`) does.
        let open = app.descendants(matching: .any).matching(identifier: "videoJob.open").firstMatch
        let shown = open.waitForExistence(timeout: 3) || app.menuItems["Open"].exists
        app.typeKey(.escape, modifierFlags: [])
        return shown
    }

    @MainActor
    private func planCard(_ app: XCUIApplication) -> XCUIElement {
        let c = element(app, "videoPlanCard")
        XCTAssertTrue(c.waitForExistence(timeout: 30), "plan card")
        return c
    }

    static var fixtures: URL {
        if let env = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !env.isEmpty { return URL(fileURLWithPath: env) }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent("fixtures")
    }

    /// Pastes a CC0 landscape photo (no people, Q-012) into the composer: an image tile in the tray.
    @MainActor
    private func attachImage(_ app: XCUIApplication) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([Self.fixtures.appendingPathComponent("images/photos-cc0/019.jpg") as NSURL])
        element(app, "composerText").click()
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "fileTile").firstMatch.waitForExistence(timeout: 10), "image tile")
    }

    /// Plain words → the video route → `create_video` → the plan card (T2V), then the job and its result.
    @MainActor
    func testPlainLanguageVideo() {
        let app = launch()
        send(app, "Make a short video of waves rolling onto a beach at dusk")
        let card = planCard(app)
        XCTAssertTrue(element(app, "videoPlan.prompt").exists)
        _ = card
        app.startVideoPlan()
        XCTAssertTrue(element(app, "videoJobResult").waitForExistence(timeout: 120), "the scripted clip's poster + Open")
        XCTAssertTrue(Self.offersOpen(app), "the finished job offers Open")
    }

    /// `+ → Create video` sets a sticky chip forcing video mode; the plan card counts down (explicit intent, AC, ≤ 5 min).
    @MainActor
    func testCreateVideoChip() {
        let app = launch()
        element(app, "composerAdd").click()
        let row = element(app, "addRow.video")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        XCTAssertTrue(element(app, "toolChip.video").waitForExistence(timeout: 5), "sticky Create video chip")
        send(app, "a paper airplane gliding through a classroom")
        _ = planCard(app)
        XCTAssertTrue(element(app, "videoPlan.countdown").waitForExistence(timeout: 5), "explicit intent counts down")
        XCTAssertTrue(element(app, "toolChip.video").exists, "the chip stays for the next message")
    }

    /// A video request with an attached image starts image-to-video (R-040 AC1).
    @MainActor
    func testImageAttachmentStartsI2V() {
        let app = launch()
        attachImage(app)
        send(app, "make this photo into a short clip")
        _ = planCard(app)
        XCTAssertTrue(element(app, "videoPlan.prompt").exists)
        app.startVideoPlan()
        XCTAssertTrue(element(app, "videoJobResult").waitForExistence(timeout: 120))
    }

    /// Animate on an image result card (⋯ and hover) → the plan card with the picture as source (R-043 AC1).
    @MainActor
    func testAnimateOnImageCard() {
        // The chat model makes the picture first (`create_image`; "YES" would script `create_video`, Q-015 r2).
        // Q-015 r5: then a text segment. A request plays segment k = its assistant messages and past the last one the last
        // repeats, so with the image call alone the "Animate" turn replayed create_image (skipped as a repeat); a text
        // segment is where the forced tool (Animate forces Create video) is called instead, as constrained decoding does.
        let app = launch(script: AntiChatUIApp.turnScript(MediaUIApp.createImageTurn + "\n" + #"{"t":"turn"}"# + "\n"
                                                          + #"{"t":"textDelta","v":"Here is your picture.","delayMs":1}"#),
                         extra: ["-UseScriptedImageEngine", MediaUIApp.script("image", #"{"steps":4,"delayMs":200}"#),
                                 "-FakePackState", "photo=ready"])
        send(app, "draw a lighthouse on a cliff at sunset")
        let result = element(app, "imageJobCard.result")
        XCTAssertTrue(result.waitForExistence(timeout: 60))
        result.hover()
        XCTAssertTrue(element(app, "imageJobCard.animateHover").waitForExistence(timeout: 5), "hover action")
        element(app, "imageJobCard.more").clickReliably()
        XCTAssertTrue(element(app, "imageJobCard.animate").waitForExistence(timeout: 5), "⋯ → Animate")
        element(app, "imageJobCard.animate").clickReliably()
        _ = planCard(app)
        // R-290 AC2 (lead decision, Q-015 r6): an explicit intent counts down only when the estimate is ≤ 5 min.
        // Image-to-video (`i2v-480p-short`, 20 steps) is over 5 min in every speed class of video-speed.json (T3 M4 Max
        // here: about 40 min), so the explicit Animate card waits for [Start] — no countdown — and Start runs the job.
        let estimate = element(app, "videoPlan.estimate")
        XCTAssertTrue(estimate.waitForExistence(timeout: 5), "the plan's estimate")
        let start = element(app, "videoPlan.start")
        XCTAssertTrue(start.waitForExistence(timeout: 5), "over 5 min: the card waits for Start (\(estimate.label))")
        XCTAssertFalse(element(app, "videoPlan.countdown").waitForExistence(timeout: 3),
                       "over 5 min: no countdown, even for an explicit intent (R-290 AC2)")
        start.clickReliably()
        let ran = element(app, "videoJobResult").waitForExistence(timeout: 120)
        if !ran { print("UITREE-BEGIN -[VideoEntryTests testAnimateOnImageCard]\n\(app.debugDescription)") }
        XCTAssertTrue(ran, "Start runs the Animate job")
    }

    /// Animate on an image tile in the composer tray → sends now with that picture as the I2V source.
    @MainActor
    func testAnimateOnAttachment() {
        let app = launch()
        attachImage(app)
        element(app, "fileTile").hover()
        let animate = element(app, "fileTileAnimate")
        XCTAssertTrue(animate.waitForExistence(timeout: 5))
        animate.click()
        _ = planCard(app)
    }

    /// The job's result posts MediaJobCompleted{kind: video, chatID} (the system notification is M8, AT-042).
    @MainActor
    func testCompletionEventPosted() {
        let app = launch()
        send(app, "Make a short clip of fireworks over a lake")
        app.startVideoPlan()
        XCTAssertTrue(element(app, "videoJobResult").waitForExistence(timeout: 120))
        // M8 replaced the logging NotificationService with the real one (AT-042, NotificationsUITests): the posted
        // event is what MediaCompletionEventsTests records through its sink; here the finished job's card is the
        // UI-visible part (the old check read a log file M8 no longer writes; Q-015 r2).
        XCTAssertTrue(Self.offersOpen(app), "the finished job offers Open")
    }

    /// An ineligible Mac (T1) gets the explanation card for a video request — no error, no job; the + row is dimmed.
    @MainActor
    func testIneligibleExplains() {
        let app = launch(tier: "T1")
        element(app, "composerAdd").click()
        let row = element(app, "addRow.video")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(row.isEnabled, "dimmed with the reason (M5.T08)")
        app.typeKey(.escape, modifierFlags: [])
        send(app, "Make a short video of a koala eating leaves")
        XCTAssertTrue(element(app, "installCard").waitForExistence(timeout: 20), "the explanation card")
        XCTAssertFalse(element(app, "videoPlanCard").exists)
        XCTAssertFalse(element(app, "messageError").exists, "no error")
    }
}
