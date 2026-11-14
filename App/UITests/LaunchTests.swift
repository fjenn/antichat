import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testLaunchShowsAntiChatWindow() throws {
        let app = XCUIApplication.antichat()
        app.launch()
        XCTAssertTrue(app.mainWindow.waitForExistence(timeout: 10))
    }
}
