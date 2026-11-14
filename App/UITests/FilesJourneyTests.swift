// Journey 4 (test-strategy §4.1; M6.T21 step 4) — XCUITest. XCUITest can't start on the build Mac (Q-015): recorded
// `pending (Q-015)`; the same journey runs in-process in FilesJourneyHostTests (AntiChatUIModuleTests).
// Attach `text-10p.pdf` (⌘V of the file URL) → the tile reads and shows "10 pages" → ask → the status line reads
// "Reading text-10p.pdf · N%" during the 4 s scripted prefill (NFR-C5) → the answer's "(p. 3)" is a page pill that opens
// the document at page 3 → a corrupt PDF ends as an error tile with its toast (IS-10).
// Script: tools/fixtures/scripts/files-journey.jsonl (ScriptedEngine, PR); nightly with `min` models.
import AppKit
import XCTest

final class FilesJourneyTests: XCTestCase {
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

    @MainActor private func paste(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        turn.input.click()
        app.typeKey("v", modifierFlags: .command)
    }

    @MainActor
    func testJourney4() {
        turn = TurnApp(script: "files-journey.jsonl")
        // Q-015 r5: journey 4 asks about a document that goes in WHOLE (the host leg's `inline` slot). Without a fixed
        // context and tier the scripted slot's budget sent the 10 pages as excerpts, so no "Reading … %" could show.
        // A T3 Mac with a 32k context: R-270 AC1 puts them inline (≤ 0.5 × free context and ≤ 20 s of prefill).
        turn.app.launchArguments += ["-FakeHardware", "T3", "-FakeContextWindow", "32768"]
        turn.launch()
        let docs = FilesExcerptTests.fixtures.appendingPathComponent("docs/pdf")
        paste(docs.appendingPathComponent("text-10p.pdf"))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "fileTile").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "fileTile").firstMatch.wait(30) { $0.label.contains("10 pages") }, "extraction finished")
        turn.send("What does chapter 3 say?")
        let verb = app.staticTexts.matching(identifier: "statusVerb").firstMatch
        XCTAssertTrue(verb.waitForExistence(timeout: 20))
        // The line opens as "Thinking…" and turns into "Reading … · n%" at the first prefill progress (Q-015 r4: read
        // once at appearance, it raced the first progress event).
        var seen: [String] = []
        XCTAssertTrue(verb.wait(20) {
            guard let t = $0.shownText else { return false }
            if seen.last != t { seen.append(t) }
            return t.hasPrefix("Reading text-10p.pdf · ") && t.hasSuffix("%")
        }, "status lines seen: \(seen)")
        // Round 65 (f5326cb5d, S-14): "(p. N)" renders as an inline pill (PageCitePillView), a button identified
        // `pageCite` whose label is the file name and the page ("text-10p.pdf, p. 3"), not a Markdown link.
        let pill = app.buttons.matching(NSPredicate(format: "identifier == 'pageCite' AND label ENDSWITH 'p. 3'")).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "the page citation is a pill")
        pill.clickReliably()  // a real click at its centre: links in the transcript report "Not hittable" (M9.T03)
        // Q-015 r5: in a chat window the pill opens the side panel at the page (M6.T13, R-277 AC1); the sheet is the
        // fallback where there is no panel. The panel's PDF view says its page ("p. 3").
        let panelPDF = app.descendants(matching: .any)["panelPDF"], sheet = app.descendants(matching: .any)["pdfPageSheet"]
        XCTAssertTrue(panelPDF.waitForExistence(timeout: 10) || sheet.exists, "opens the document")
        if panelPDF.exists {
            XCTAssertTrue(panelPDF.wait(5) { $0.stringValue == "p. 3" }, "opens at the page: \(panelPDF.stringValue)")
            app.descendants(matching: .any)["panelClose"].click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
        paste(docs.appendingPathComponent("corrupt.pdf"))
        // The tile is one element whose label carries its state ("corrupt.pdf, PDF, Couldn't read this file"), as FilesIntakeTests
        // reads it; the line is not a separate static text (Q-015 r6).
        let failedTile = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'fileTile' AND label CONTAINS 'corrupt.pdf' AND label CONTAINS 'read this file'")).firstMatch
        XCTAssertTrue(failedTile.waitForExistence(timeout: 20), "error on the tile")
        // Q-015 r7: a static text's words are its AX value on macOS (the toast's label is empty; AX probe), as
        // FilesIntakeTests reads the same toast.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "corrupt.pdf", "corrupt.pdf"))
                        .firstMatch.waitForExistence(timeout: 5),
                      "the toast names the file")
    }
}
