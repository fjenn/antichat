// AT-271 check 2 (R-271 AC2; M6.T04 steps 4–5) — XCUITest leg. XCUITest can't start on the build Mac (Q-015):
// recorded `pending (Q-015)`; the same path runs in-process in DocumentContextAssemblerTests
// .aScanCanBeSentBeforeOCRFinishes (tile "page n of 60" from 0, monotonic; a send at page ≥ 3 is accepted and the
// reply records files.stillReading) and ScanDetectorTests / VisionOCRTests (checks 1, 3a, 3b).
// Path: ⌘V of scan-60p-contract.pdf → the tile reads "Reading scan · page n of 60" with n rising; at n ≥ 3 the send is
// enabled; the reply shows "Still reading — answering from pages 1–n so far".
import AppKit
import XCTest

final class FilesScanTests: XCTestCase {
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

    /// The page of "Reading scan · page n of N", anywhere in the text (the tile is one element whose label is
    /// "<name>, PDF, Reading scan · page n of N", Q-015 r3).
    private static func page(_ label: String) -> Int? {
        guard let r = label.range(of: "Reading scan · page "), let n = label[r.upperBound...]
            .split(separator: " ").first else { return nil }
        return Int(n)
    }

    @MainActor
    func testScanTileCountsPagesAndSendsEarly() {
        turn = TurnApp(script: "basic.jsonl")
        turn.launch()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([Self.fixtures.appendingPathComponent("docs/pdf/scan-60p-contract.pdf") as NSURL])
        turn.input.click()
        app.typeKey("v", modifierFlags: .command)
        // In the chat window only: the whole app's tree (menus included) timed out under a CONTAINS query.
        // The scan line is the file tile's state line (`status.readingScan`, in the tile's label): the tile by id, then
        // its label. A CONTAINS on label/value over every element type timed out with the app idle (Q-015 r2/r5).
        let status = app.mainWindow.descendants(matching: .any).matching(identifier: "fileTile")
            .matching(NSPredicate(format: "label CONTAINS 'Reading scan · page '")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        var pages: [Int] = []
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if status.exists, let n = Self.page(status.displayText) { if pages.last != n { pages.append(n) } }
            if (pages.last ?? 0) >= 3 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(pages, pages.sorted(), "page n only rises")
        XCTAssertGreaterThanOrEqual(pages.last ?? 0, 3)
        XCTAssertTrue(status.displayText.hasSuffix(" of 60"), status.displayText)
        turn.send("What does clause 2 say?")
        let notice = app.descendants(matching: .any)["stillReading"]
        XCTAssertTrue(notice.waitForExistence(timeout: 30))
        XCTAssertTrue(notice.displayText.hasPrefix("Still reading — answering from pages 1–"), notice.displayText)
    }
}
