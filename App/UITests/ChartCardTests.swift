// AT-274 check 2, UI leg (R-274 AC2; M6.T12 step 4) — XCUITest. XCUITest can't start on the build Mac (Q-015):
// recorded `pending (Q-015)`; the in-process legs are AntiChatUIModuleTests/ChartCardModelTests (Save PNG / Save SVG /
// Copy / View data) and AntiChatToolsTests/VegaRendererTests (SVG + PNG, zero network).
// Setup: ScriptedEngine `fileout-chart.jsonl` (one create_chart call with inline values).
import XCTest

final class ChartCardTests: XCTestCase {
    private var turn: TurnApp!
    private var app: XCUIApplication { turn.app }

    override func setUp() { continueAfterFailure = false }

    override func tearDown() { turn?.app.terminate() }

    @MainActor
    func testChartCardActions() {
        turn = TurnApp(script: "fileout-chart.jsonl")
        turn.launch()
        turn.send("Chart 3, 5 and 8 as bars")
        let card = app.descendants(matching: .any)["chartCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        card.hover()
        app.buttons["chartViewData"].click()
        XCTAssertTrue(app.descendants(matching: .any)["chartDataTable"].waitForExistence(timeout: 5))
        app.buttons["chartCopy"].click()
        XCTAssertNotNil(NSPasteboard.general.data(forType: .png), "Copy puts the PNG on the pasteboard")
    }
}
