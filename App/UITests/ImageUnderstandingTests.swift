// AT-021 check 1, UI leg (R-021 AC1; M6.T05 step 3) — XCUITest. XCUITest can't start on the build Mac (Q-015):
// recorded `pending (Q-015)`; the same path runs in-process in VisionInputTests (a text-only model gets no image and the
// reply records `vision: unavailable`; a vision model gets the prepared path). The ScriptedEngine's slot is text-only
// and no helper VLM exists in this run, which is the `-FakeHardware t0-novision` state (A-M6-T05a).
// Path: ⌘V of an image + a question → the reply shows "Image understanding needs a larger model" with
// [Packs & Models], which opens Settings → Capabilities.
import AppKit
import XCTest

final class ImageUnderstandingTests: XCTestCase {
    private var turn: TurnApp!
    private var app: XCUIApplication { turn.app }

    override func setUp() { continueAfterFailure = false }

    override func tearDown() {
        if let turn {
            let shot = XCTAttachment(screenshot: turn.app.windows.firstMatch.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
            turn.app.terminate()
        }
    }

    static var fixtures: URL {
        if let env = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !env.isEmpty { return URL(fileURLWithPath: env) }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent("fixtures")
    }

    @MainActor
    func testTextOnlyModelShowsNeedsLargerModelWithCapabilitiesLink() {
        turn = TurnApp(script: "basic.jsonl")
        turn.app.launchArguments += ["-FakeHardware", "T0"]
        // Q-015 r5: the AT's precondition is a text-only model with NO helper VLM; this Mac's dev store has the starter
        // (the helper), so the reply was captioned/OCR'd and no card could show. The DEBUG seam removes the helper.
        turn.app.launchEnvironment["ANTICHAT_NO_VISION_HELPER"] = "1"
        // r6: …and the chat model is text-only (the dev store's starter-family chat models have a vision tower, so the
        // chat model saw the image itself and no card showed).
        turn.app.launchEnvironment["ANTICHAT_TEXT_ONLY_CHAT"] = "1"
        turn.launch()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([Self.fixtures.appendingPathComponent("images/ocr/doc-00.png") as NSURL])
        turn.input.click()
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "fileTile").firstMatch.waitForExistence(timeout: 10))
        turn.send("What is the reference code?")
        let card = app.descendants(matching: .any)["imgNeedsLargerModel"]
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Image understanding needs a larger model"].exists)
        // A link-style Button: AppKit exposes it as a Link (the [Packs & Models] link of R-021 AC1), not a Button.
        let cta = app.links["imgNeedsLargerModelCTA"]
        XCTAssertEqual(cta.displayText, "Packs & Models")
        cta.click()
        XCTAssertTrue(app.windows.matching(NSPredicate(format: "title CONTAINS 'Capabilities'")).firstMatch.waitForExistence(timeout: 10))
    }
}
