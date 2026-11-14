// AT-206 part 2 / AT-NFR-R5 UI leg (M2.T13 step 3; R-206 AC6, NFR-R5): `-FakeHardware t0-m1-8` (B = 4.0 GB) with an
// oversized chat model override (`-ChatModel chat-9b-q4`, 6.5 GB catalog footprint, no lighter fallback installed)
// → the helper's scheduler refuses before loading → `model.notEnoughMemory` + [Retry] in place of the reply; the
// default UI has no "try anyway" control anywhere (the override lives only in Settings › Capabilities › Advanced).
// Committed, not run on this Mac (Q-015: XCUITest cannot start); LighterFallbackTests / OverBudgetRefusalTests and
// MemoryFitTests cover the same refusal in-process and through the helper.
import XCTest

final class NotEnoughMemoryUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testOversizedModelShowsNotEnoughMemoryWithRetryAndNoTryAnyway() {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-uitest-nem-\(UUID().uuidString)")
        let app = XCUIApplication.foreground()
        app.launchArguments = ["-ANTICHAT_DEV_CONTAINER", container.path, "-ApplePersistenceIgnoreState", "YES",
                               "-FakeHardware", "t0-m1-8", "-ChatModel", "chat-9b-q4", "-SkipOnboarding", "YES"]
        app.launch()
        app.activate()
        let input = app.descendants(matching: .any).matching(identifier: "composerText").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.click()
        input.typeText("Hello there")
        input.typeKey(.return, modifierFlags: [])
        // The reply row shows ErrorInline with `model.notEnoughMemory` + [Retry]; SwiftUI drops the inline's
        // container identifier on macOS, so find it by its copy inside the assistant message (Q-015 catch-up).
        let reply = app.descendants(matching: .any).matching(identifier: "assistantMessage").firstMatch
        let notice = reply.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Not enough free memory' OR label BEGINSWITH 'Not enough free memory'")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 20))
        XCTAssertTrue(reply.buttons["Retry"].exists, "[Retry]")
        let tryAnyway = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'try anyway' OR identifier CONTAINS[c] 'tryAnyway'")).count
        XCTAssertEqual(tryAnyway, 0, "no 'try anyway' in the default UI")
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }
}
