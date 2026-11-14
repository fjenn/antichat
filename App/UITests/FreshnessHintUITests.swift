// AT-228 (R-228 AC1–AC4; docs/prd/M7.md M7.T05). Committed for the serial UI run; on this Mac XCUITest cannot start
// (Q-015), so the AT runs as the in-process probe (`LEGS=hint tools/at/at-080-probe.sh`, SearchProbe mode `hint`).
import AppKit
import XCTest

final class FreshnessHintUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() { continueAfterFailure = false }
    override func tearDown() { app?.terminate() }

    @MainActor private func launch(_ extra: [String] = []) {
        let root = ProcessInfo.processInfo.environment["ANTICHAT_ROOT"] ?? TurnApp.repoRoot.path
        app = XCUIApplication.antichat(["-UseScriptedEngine", "\(root)/tools/fixtures/scripts/web-plain.jsonl",
                                        "-ChatModel", "chat-9b-q4", "-DefaultsSuite", "com.antichat.uitest.freshness",
                                        "-net.category.search", "NO"] + extra)  // a defaults launch argument needs its dash (Q-015 catch-up)
        app.launch()
        XCTAssertTrue(element("composer").waitForExistence(timeout: 20))
    }

    @MainActor private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    @MainActor private func ask(_ s: String) {
        app.textViews["composerText"].click()
        app.textViews["composerText"].typeText(s + "\r")
    }

    @MainActor func testHintButtonsOpenConsent() {
        launch()
        ask("What's the latest macOS version?")
        XCTAssertTrue(element("freshHint").waitForExistence(timeout: 20))
        XCTAssertEqual(element("freshHint.text").displayText, "This may need the web. Turn on web search?")
        element("freshHint.on").clickReliably()
        XCTAssertTrue(element("search.consentSheet").waitForExistence(timeout: 3))
    }

    @MainActor func testNotNowHidesForChat() {
        launch()
        ask("What's the latest macOS version?")
        XCTAssertTrue(element("freshHint.later").waitForExistence(timeout: 20))
        element("freshHint.later").clickReliably()
        XCTAssertFalse(element("freshHint").exists)
        ask("Any news on interest rates today?")
        XCTAssertFalse(element("freshHint").waitForExistence(timeout: 10))
    }

    @MainActor func testSettingTurnsOffEverywhere() {
        launch(["-suggestWebSearch", "NO"])  // the dash makes it a defaults argument (without it the hint stayed on)
        ask("What's the weather in Lisbon today?")
        XCTAssertFalse(element("freshHint").waitForExistence(timeout: 10))
    }

    @MainActor func testOfflineVariant() {
        launch(["-OfflineOnly", "YES"])
        ask("What's the weather in Lisbon today?")
        XCTAssertTrue(element("freshHint").waitForExistence(timeout: 20))
        XCTAssertEqual(element("freshHint.text").displayText, "This may need the web, and you're offline.")
        XCTAssertFalse(element("freshHint.on").exists)
    }
}
