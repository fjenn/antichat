// AT-NFR-P3 / R-031 AC1 text leg: the image job card's progress text ("{percent}% · {seconds} s") advances while the
// job runs — the percent with every helper step (jobProgress) and the seconds every second — whether or not the step
// carried a preview (T1: none). ScriptedImageEngine, 4 steps × 3 s. Self-contained launch helpers.
import AppKit
import XCTest

final class ImageProgressTextTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private static func file(_ name: String, _ body: String) -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try? Data(body.utf8).write(to: url)
        return url.path
    }

    private static let createImageTurn = #"{"t":"toolCallDone","id":"call_1","name":"create_image","args":"{\"prompt\":\"a lighthouse at dusk\",\"aspect\":\"3:2\"}","delayMs":1}"#

    @MainActor
    private func launch(_ imageScript: String) -> XCUIApplication {
        let app = XCUIApplication()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("antichat-uitest-p3text-\(UUID().uuidString)", isDirectory: true)
        app.launchArguments = ["-ANTICHAT_DEV_CONTAINER", container.path, "-ApplePersistenceIgnoreState", "YES",
                               "-SkipOnboarding", "YES", "-OfflineOnly", "YES",
                               "-UseScriptedEngine", Self.file("create-image.jsonl", Self.createImageTurn + "\n"),
                               "-UseScriptedImageEngine", Self.file("image.json", imageScript), "-FakePackState", "photo=ready",
                               "-ChatModel", "chat-9b-q4"]  // a tool-capable chat slot (the starter is offered no tools)
        app.launchEnvironment["ANTICHAT_BACKGROUND"] = "0"
        app.launch()
        app.activate()
        return app
    }


    @MainActor
    func testProgressTextAdvancesEveryStep() {
        let app = launch(#"{"steps":4,"delayMs":3000}"#)
        let input = app.descendants(matching: .any).matching(identifier: "composerText").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 30))
        input.click()
        input.typeText("Draw me a lighthouse at dusk")
        input.typeKey(.return, modifierFlags: [])
        let progress = app.descendants(matching: .any).matching(identifier: "imageJobCard.progress").firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 30), "progress pill")
        let result = app.descendants(matching: .any).matching(identifier: "imageJobCard.result").firstMatch
        var texts: [String] = [], percents: [Int] = []
        var lastChange = Date(), maxStale = 0.0
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 40, !result.exists, progress.exists {
            // One snapshot (shownText): the pill leaves the tree when the result replaces it, between `exists` and a
            // label read, which then failed the test ("No matches found"); gone = the job finished.
            guard let t = progress.shownText else { break }
            if t != texts.last { texts.append(t); lastChange = Date() }
            if let p = t.split(separator: "%").first.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), p != percents.last {
                percents.append(p)
            }
            maxStale = max(maxStale, Date().timeIntervalSince(lastChange))
            usleep(250_000)
        }
        print("P3-TEXT texts=\(texts) percents=\(percents) maxStale=\(maxStale)")
        XCTAssertFalse(texts.isEmpty || texts.allSatisfy(\.isEmpty), "the pill has text: \(texts)")
        XCTAssertLessThanOrEqual(maxStale, 2.0, "the progress text ticks (seconds) at least every second: \(texts)")
        XCTAssertGreaterThanOrEqual(Set(percents).count, 3, "the percent follows the helper's steps: \(percents)")
        XCTAssertEqual(percents, percents.sorted(), "never decreases")
    }
}
