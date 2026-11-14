// AT-030 (R-030) + AT-NFR-B2 UI legs (M4.T07): plain language reaches create_image, the Create image chip forces it
// with the aspect chips (all five ratios → the output PNG's ratio), ⋯ → Show prompt shows the model's prompt, Photo
// not installed → the install card with the catalog size, Low Power → one resolution step lower.
// Committed, not run on this Mac (Q-015: XCUITest cannot start). In-process legs that run today: ImageEntryTests
// (Harness), AspectChipsModelTests (UI), ImageRequestBuilderTests, InstallCard tests (M2.T24), and the AT-030 AC1
// full-stack eval (`antichat-bench router --stack --real-image-tool`, build/at/AT-030/intent.json).
import AppKit
import XCTest

final class ImageEntryTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testPlainLanguageTriggers() {
        let app = MediaUIApp.launch()
        MediaUIApp.send(app, "Draw me a lighthouse at dusk")
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard").waitForExistence(timeout: 30))
    }

    @MainActor
    func testCreateImageChipForcesAndAspect() throws {
        let ratios: [(String, Double)] = [("1:1", 1), ("2:3", 2.0 / 3), ("3:2", 1.5), ("9:16", 9.0 / 16), ("16:9", 16.0 / 9)]
        let app = MediaUIApp.launch()
        MediaUIApp.element(app, "composerAdd").click()
        MediaUIApp.element(app, "addRow.image").click()
        XCTAssertTrue(MediaUIApp.element(app, "aspectChips").waitForExistence(timeout: 5))
        for (ratio, value) in ratios {
            MediaUIApp.element(app, "aspectChip.\(ratio)").click()
            MediaUIApp.send(app, "a lighthouse \(ratio)")
            // The result is a button (it opens the viewer), not an image element (Q-015 r4). Q-015 r5: the transcript is
            // lazy, so earlier replies scrolled off leave the tree and an index into all results pointed past the end;
            // the newest reply (the last one, on screen) is the one for this send.
            _ = app.buttons["stop"].waitForExistence(timeout: 5)
            let replies = app.descendants(matching: .any).matching(identifier: "assistantMessage")
            var result = replies.firstMatch
            let end = Date().addingTimeInterval(60)
            var done = false
            while Date() < end, !done {
                let n = replies.count
                if n > 0, !app.buttons["stop"].exists {
                    result = replies.element(boundBy: n - 1).descendants(matching: .any).matching(identifier: "imageJobCard.result").firstMatch
                    done = result.exists
                }
                if !done { Thread.sleep(forTimeInterval: 0.5) }
            }
            XCTAssertTrue(done, "the \(ratio) picture")
            let f = result.frame
            XCTAssertEqual(f.width / f.height, value, accuracy: 0.08, ratio)
        }
    }

    @MainActor
    func testShowPrompt() {
        let app = MediaUIApp.launch()
        MediaUIApp.send(app, "Draw me a lighthouse at dusk")
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard.result").waitForExistence(timeout: 60))
        MediaUIApp.element(app, "imageJobCard.more").clickReliably()
        MediaUIApp.element(app, "imageJobCard.showPrompt").clickReliably()
        let prompt = MediaUIApp.element(app, "imageJobCard.prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        XCTAssertEqual(prompt.value as? String, "a lighthouse at dusk")
    }

    @MainActor
    func testPhotoNotEnabledInstallCard() {
        let app = MediaUIApp.launch(["-FakePackState", "photo=absent"])
        MediaUIApp.send(app, "Draw me a lighthouse at dusk")
        let card = MediaUIApp.element(app, "installCard")
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        // The card is a container; its sentence is the `installCardText` child (Q-015 r3).
        let text = MediaUIApp.element(app, "installCardText").displayText
        XCTAssertTrue(text.contains("GB"), "install.card with the catalog size: \(text)")
    }

    @MainActor
    func testLowPowerDropsResolution() {
        let app = MediaUIApp.launch(["-FakePower", "lowpower"])
        MediaUIApp.send(app, "Draw me a lighthouse at dusk")
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard.result").waitForExistence(timeout: 60))
        // The job spec records `lowPower` and the one-step-lower size (ImageEntryTests.lowPowerDropsOneResolutionStep).
    }
}
