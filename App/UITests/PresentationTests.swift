// AT-275 check 1b, UI leg (R-275 AC1; M6.T11 step 4) — XCUITest. XCUITest can't start on the build Mac (Q-015):
// recorded `pending (Q-015)`; the in-process legs are AntiChatToolsTests/PPTXRendererGoldenTests (20 decks, 4 themes,
// layouts, notes, 31 slides rejected) and AntiChatUIModuleTests/FileOutActivityTests.deckCardAndPanelPreview (the card and
// the side panel's Quick Look body for .pptx). Setup: ScriptedEngine `fileout-deck.jsonl` (one create_presentation call).
import XCTest

final class PresentationTests: XCTestCase {
    private var turn: TurnApp!
    private var app: XCUIApplication { turn.app }

    override func setUp() { continueAfterFailure = false }

    override func tearDown() { turn?.app.terminate() }

    @MainActor
    func testPanelPreview() {
        turn = TurnApp(script: "fileout-deck.jsonl")
        turn.launch()
        turn.send("Make a 3-slide deck about the garden club")
        let card = app.descendants(matching: .any)["fileOutCard"].firstMatch  // a made file is a file-out card (Q-015 r4)
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        card.click()
        XCTAssertTrue(app.descendants(matching: .any)["sidePanel"].waitForExistence(timeout: 10), "the deck previews in the side panel")
    }
}
