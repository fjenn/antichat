// M7.T11 AT-255 c3 / c5-app (R-255 AC3, A-M7-06; S-24 Composio consent, vq-10): Connections → Gmail tile [Connect] →
// consent sheet (Composio storage/logging statement + privacy link) [Continue] → browser sign-in = 3 user actions; the
// row ends Connected with the Cloud badge. Needs `make relay-dev` (relay/.env.test + mock Composio; its link page calls
// back) and `-RelayURL`; the rate-limit case runs relay-dev with RELAY_TEST_MCP_PER_MIN=1. Pending Q-015 (XCUITest
// automation mode is blocked on this Mac); the same flows run in-process in ComposioHostTests / RelayIdentityTests.
import XCTest

final class ComposioUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// The sign-in link the app sent to the browser (`-OpenURLSpy`): the test plays the browser (Q-015 r2: a real
    /// browser would open on the owner's Mac).
    private let spy = FileManager.default.temporaryDirectory.appendingPathComponent("composio-open-\(UUID().uuidString).txt")

    @MainActor private func launch(relay: String = ProcessInfo.processInfo.environment["ANTICHAT_RELAY_URL"] ?? "http://127.0.0.1:3000") -> XCUIApplication {
        let app = XCUIApplication.foreground()
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("composio-ui-\(UUID().uuidString)").path
        app.launchArguments += ["-ANTICHAT_DEV_CONTAINER", container, "-SkipOnboarding", "YES", "-RelayURL", relay,
                                "-OpenURLSpy", spy.path]
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        app.descendants(matching: .any).matching(identifier: "settings.nav.connections").firstMatch.click()
        return app
    }

    @MainActor func testConnectGmailTwoSteps() throws {
        let app = launch()
        var actions = 0
        // The page says how apps connect before anything is pressed (the consent sheet's meaning, one line).
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "connections.intro").firstMatch.waitForExistence(timeout: 5))
        app.descendants(matching: .any).matching(identifier: "connections.add.gmail").firstMatch.click(); actions += 1
        actions += 1  // the browser sign-in: the mock Composio's hosted page activates the account when loaded
        browse()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "connections.menu.gmail").firstMatch.waitForExistence(timeout: 30))
        XCTAssertLessThanOrEqual(actions, 2)
    }

    /// Loads the sign-in link the app opened, as the browser would.
    private func browse(file: StaticString = #filePath, line: UInt = #line) {
        var link: URL?
        for _ in 0..<50 where link == nil {
            link = (try? String(contentsOf: spy, encoding: .utf8))?.split(separator: "\n").last.flatMap { URL(string: String($0)) }
            if link == nil { Thread.sleep(forTimeInterval: 0.2) }
        }
        guard let link else { return XCTFail("the app opened no sign-in link", file: file, line: line) }
        let done = expectation(description: "sign-in page")
        URLSession.shared.dataTask(with: link) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }

    /// Needs a second relay-dev with RELAY_TEST_MCP_PER_MIN=1 (`ANTICHAT_RELAY_URL_LIMITED`, default port 3001).
    @MainActor func testRateLimitedShowsCopy() throws {
        let app = launch(relay: ProcessInfo.processInfo.environment["ANTICHAT_RELAY_URL_LIMITED"] ?? "http://127.0.0.1:3001")
        app.descendants(matching: .any).matching(identifier: "connections.add.gmail").firstMatch.click()
        // Connect is a spinner while a sign-in waits, so it is pressed again only while it is there (Q-015 r3).
        let slack = app.descendants(matching: .any).matching(identifier: "connections.add.slack").firstMatch
        for _ in 0..<3 where slack.waitForExistence(timeout: 3) { slack.click() }
        let error = app.descendants(matching: .any).matching(identifier: "composio.error").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertTrue(error.displayText.contains("Connections are busy"))
    }
}
