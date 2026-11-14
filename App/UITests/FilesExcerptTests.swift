// AT-270 checks 1–3, UI leg (R-270 AC1–AC3; M6.T02 steps 4, 6, 7) — XCUITest. XCUITest can't start on the build Mac
// (Q-015): recorded `pending (Q-015)`; the same paths run in-process in DocumentContextAssemblerTests (excerpt path +
// pages, Read whole file forces inline, Summarise the whole document = map-reduce as a new version with rising
// `.summarising` progress), MapReduceTests and TurnControllerTests.statusLine (`status.summarising` label + args).
// Setup: ScriptedEngine, `-FakeHardware T0` + `-FakeContextWindow 32768`, `budget-40/doc-020p.pdf` (10,325 tokens):
// it fits the context but not the T0 time cap (the scripted key has no measured prefill_tps → the T0 default,
// A-M6-T02a), so the reply uses excerpts and offers [Read whole file (about N s)].
import AppKit
import XCTest

final class FilesExcerptTests: XCTestCase {
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
    private func sendWithDocument() {
        // Q-015 r4: a script with a real prefill (3 s, 15 progress steps). basic.jsonl reported no prefill progress, so
        // "Reading … · n%" could never show and the re-run finished before the status line was looked for.
        turn = TurnApp(script: "files-excerpt.jsonl")
        // Q-015 r4: the excerpt note never appeared because the dev default chat key (`chat-0.8b`) has a measured
        // prefill rate since tier-budgets.json gained it (19,500 tok/s: 10,325 tokens fit the 20 s cap, so inline).
        // The setup this check states — a key with no measured rate, so the T0 default (300 tok/s) — is pinned.
        turn.app.launchArguments += ["-FakeHardware", "T0", "-FakeContextWindow", "32768", "-ChatModel", "chat-g26"]
        turn.launch()
        let url = Self.fixtures.appendingPathComponent("docs/budget-40/doc-020p.pdf")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        turn.input.click()
        app.typeKey("v", modifierFlags: .command)
        let tile = app.descendants(matching: .any).matching(identifier: "fileTile").firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        XCTAssertTrue(tile.wait(30) { $0.label.contains("20 pages") }, "extraction finished")
        turn.send("What does page 7 say?")
    }

    /// Check 1: the grey `files.usedExcerpts` line with the pages disclosure.
    @MainActor
    func testExcerptNoteListsPages() {
        sendWithDocument()
        let note = app.descendants(matching: .any)["excerptNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 30))
        XCTAssertEqual(note.displayText, "Used excerpts from doc-020p.pdf")  // the note is the disclosure button
        note.click()
        let pages = app.descendants(matching: .any)["excerptNotePages"]
        XCTAssertTrue(pages.waitForExistence(timeout: 5))
        XCTAssertTrue((pages.displayText.isEmpty ? (pages.value as? String ?? "") : pages.displayText).hasPrefix("Pages used: "))
    }

    /// Check 2: `[Read whole file (about N s)]` only when `fitsContext && !fitsTime`; pressing it re-runs the reply with
    /// the document inline and the prefill shows a real reading percent (NFR-C5).
    @MainActor
    func testReadWholeFileShowsEstimateAndReadingPercent() {
        sendWithDocument()
        let button = app.buttons["readWholeFile"]
        XCTAssertTrue(button.waitForExistence(timeout: 30))
        XCTAssertTrue(button.displayText.hasPrefix("Read whole file (about "), button.displayText)
        button.click()
        let verb = app.staticTexts.matching(identifier: "statusVerb").firstMatch
        XCTAssertTrue(verb.waitForExistence(timeout: 20))
        // "Thinking…" first, "Reading … · n%" from the first prefill progress on (Q-015 r4: was read at appearance).
        XCTAssertTrue(verb.wait(20) { $0.displayText.hasPrefix("Reading doc-020p.pdf · ") && $0.displayText.hasSuffix("%") },
                      verb.exists ? verb.displayText : "status line gone")
        XCTAssertTrue(app.descendants(matching: .any)["excerptNote"].waitForNonExistence(timeout: 60),
                      "the new version read the whole file: no excerpt note")
    }

    /// Check 3: ⋯ → Summarise the whole document shows `status.summarising` with n/total and a percent that only rises.
    @MainActor
    func testSummariseWholeShowsRisingProgress() {
        sendWithDocument()
        let more = app.descendants(matching: .any)["excerptNoteMore"]
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        more.click()
        let item = app.menuItems["Summarise the whole document"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        let verb = app.staticTexts.matching(identifier: "statusVerb").firstMatch
        XCTAssertTrue(verb.waitForExistence(timeout: 20))
        var percents: [Int] = []
        let deadline = Date().addingTimeInterval(60)
        // `shownText` (one snapshot): the line vanishes when the summary ends, and reading `label` of an element that
        // went between `exists` and the read failed the test ("No matches found") on a fast finish.
        while Date() < deadline, let label = verb.shownText {
            if label.hasPrefix("Summarising section "), let p = Int(label.split(separator: "·").last?
                .trimmingCharacters(in: .whitespaces).dropLast() ?? "") {
                percents.append(p)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertFalse(percents.isEmpty, "status.summarising was shown")
        XCTAssertEqual(percents, percents.sorted(), "the percent only increases")
        XCTAssertFalse(turn.assistantText.displayText.isEmpty, "the summary is the new version's text")
    }
}
