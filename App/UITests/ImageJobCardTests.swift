// AT-031 (R-031) + AT-NFR-P3 UI legs (M4.T08): the ImageJobCard under a create_image call with ScriptedImageEngine
// (8 steps; `-FakeHardware T3` for live previews, the default T1 for progress only). Committed, not run on this Mac
// (Q-015: XCUITest cannot start). In-process legs that run today: JobProgressModelTests (monotonic %, 100 only with
// the result), ImageJobCardTests (state machine, reloaded chat, snapshots of every state), MediaJobRunnerTests.
import AppKit
import XCTest

final class ImageJobCardTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor static func percent(_ app: XCUIApplication) -> Int? {
        // shownText, not displayText: the pill leaves the tree when the result replaces it, between the loop's
        // `result.exists` check and this read; a label read then fails the test ("No matches found").
        guard let label = MediaUIApp.element(app, "imageJobCard.progress").shownText else { return nil }
        return label.split(separator: "%").first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    @MainActor
    func testRealPercentMonotonic() {
        let app = MediaUIApp.launch(imageScript: #"{"steps":8,"delayMs":400}"#)
        MediaUIApp.send(app, "Draw me a lighthouse at dusk")
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard.progress").waitForExistence(timeout: 30))
        var seen: [Int] = []
        while !MediaUIApp.element(app, "imageJobCard.result").exists {
            if let p = Self.percent(app) { seen.append(p) }
            if seen.count > 400 { break }
            usleep(50_000)
        }
        XCTAssertEqual(seen, seen.sorted(), "never decreases")
        XCTAssertFalse(seen.contains(100), "100 % only with the result")
    }

    @MainActor
    func testPreviewEveryTwoSteps() {
        // AT-031 AC2 as amended (A-M4-R1b, after A-M4-R1 / D-006): a preview the ChildSafetyCheck cannot check (the
        // scripted 64-px previews, like sd-server's 128-px `proj` ones) is withheld; the card shows progress instead,
        // and its % only rises until the result.
        let app = MediaUIApp.launch(imageScript: #"{"steps":8,"delayMs":500}"#, ["-FakeHardware", "T3"])
        MediaUIApp.send(app, "Draw me a lighthouse at dusk")
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard.progress").waitForExistence(timeout: 30))
        var seen: [Int] = []
        var previewShown = false
        while !MediaUIApp.element(app, "imageJobCard.result").exists, seen.count < 400 {
            if MediaUIApp.element(app, "imageJobCard.preview").exists { previewShown = true }
            if let p = Self.percent(app) { seen.append(p) }
            usleep(50_000)
        }
        XCTAssertFalse(previewShown, "an uncheckable preview is never shown (A-M4-R1)")
        XCTAssertEqual(seen, seen.sorted(), "the % never decreases")
        XCTAssertGreaterThan(Set(seen).count, 1, "the % moved while previews were withheld: \(seen)")
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard.result").waitForExistence(timeout: 30))
    }

    @MainActor
    func testNeverStaleThreeSeconds() {
        let app = MediaUIApp.launch(imageScript: #"{"steps":4,"delayMs":4000}"#)
        MediaUIApp.send(app, "Draw me a lighthouse at dusk")
        let card = MediaUIApp.element(app, "imageJobCard")
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        var last = card.screenshot().pngRepresentation, lastChange = Date()
        for _ in 0..<40 {
            usleep(250_000)
            let now = card.screenshot().pngRepresentation
            if now != last { last = now; lastChange = Date() }
            XCTAssertLessThan(Date().timeIntervalSince(lastChange), 3)
        }
    }

    @MainActor
    func testNavigateAwayAndBack() {
        let app = MediaUIApp.launch(imageScript: #"{"steps":8,"delayMs":600}"#)
        MediaUIApp.send(app, "Draw me a lighthouse at dusk")
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard.progress").waitForExistence(timeout: 30))
        app.typeKey("n", modifierFlags: .command)
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard").waitForExistence(timeout: 10))
        XCTAssertTrue(MediaUIApp.element(app, "imageJobCard.result").waitForExistence(timeout: 30))
    }

    @MainActor
    func testStopWithinOneSecond() throws {
        let app = MediaUIApp.launch(imageScript: #"{"steps":20,"delayMs":500}"#)
        MediaUIApp.send(app, "Draw me a lighthouse at dusk")
        let stop = MediaUIApp.element(app, "imageJobCard.cancel")
        XCTAssertTrue(stop.waitForExistence(timeout: 30))
        // The 1 s bar runs from the press landing. XCUITest's click spends about 0.5 s finding the button and moving the
        // pointer before it presses, then waits for the app to go idle; that wait is bounded too, so a busy main thread
        // cannot hide inside the click.
        let clickStart = Date()
        stop.click()
        let t0 = Date()
        XCTAssertLessThan(t0.timeIntervalSince(clickStart), 1.0, "the click itself (pointer move, press, app idle)")
        // A static text's words are its AXValue on macOS (`displayText`), and the status is polled in a tight loop: a
        // predicate expectation re-evaluates about once a second, too coarse for a 1 s bar.
        let status = MediaUIApp.element(app, "imageJobCard.status")
        var cancelledAt: Date?
        while cancelledAt == nil, Date().timeIntervalSince(t0) < 5 {
            if status.exists, status.displayText == "Cancelled" { cancelledAt = Date() } else { usleep(20_000) }
        }
        let at = try XCTUnwrap(cancelledAt, "the card never showed Cancelled")
        XCTAssertLessThanOrEqual(at.timeIntervalSince(t0), 1.0)
    }
}
