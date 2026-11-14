// AT-272 check 2, UI leg (R-272 AC2; M6.T08 step 5) — XCUITest. XCUITest can't start on the build Mac (Q-015):
// recorded `pending (Q-015)`; the same path runs in-process in AntiChatHarnessTests/QueryDataTurnTests (the sheet
// loads, the ScriptedEngine's query_data call runs, the activity line carries the summary + rows) and the UI label /
// detail parsing in AntiChatUIModuleTests/QueryActivityTests.
// Setup: ScriptedEngine `sheet-query.jsonl` (one query_data call, then text), budget-20k.xlsx pasted into the composer.
import AppKit
import XCTest

final class SheetQueryTests: XCTestCase {
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

    /// The step shows collapsed as "Queried budget-20k.xlsx · 4 rows" and expands to the SQL + rows.
    @MainActor
    func testQueryStepCollapsedAndExpanded() {
        turn = TurnApp(script: "sheet-query.jsonl")
        turn.launch()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([Self.fixtures.appendingPathComponent("docs/office/budget-20k.xlsx") as NSURL])
        turn.input.click()
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "fileTile").firstMatch.waitForExistence(timeout: 10))
        turn.send("Total spend by region?")
        let line = app.descendants(matching: .any)["activityLine"]
        XCTAssertTrue(line.waitForExistence(timeout: 30))
        // The activity line is one button whose label is the sentence (Q-015 r4: not a separate static text).
        XCTAssertTrue(line.wait(30) { $0.label == "Queried budget-20k.xlsx · 4 rows" }, line.label)
        line.click()
        XCTAssertTrue(app.descendants(matching: .any)["querySQL"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["queryRows"].exists)
    }
}
