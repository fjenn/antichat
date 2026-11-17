// AT-091 (R-091 AC1–AC4; docs/prd/M8.md M8.T08). Committed for the serial UI run; on this Mac XCUITest cannot enable
// automation mode (Q-015), so the AT runs the host tests meanwhile (`make test-unit FILTER=PrivacyDataViewModelTests`)
// and records this leg as `pending (Q-015)`. The location leg leaves the macOS dialog unanswered (the AT counts
// requests with tools/ci/tcc-requests.sh; nobody clicks Allow) and expects the in-app pending state.
import AppKit
import XCTest

final class PrivacyUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() { continueAfterFailure = false }

    override func tearDown() {
        if let app {
            let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    @MainActor private func launch(script: String = "basic", _ extra: [String] = []) {
        let root = ProcessInfo.processInfo.environment["ANTICHAT_ROOT"] ?? TurnApp.repoRoot.path
        let engine = script == "basic" ? script : "\(root)/tools/fixtures/scripts/\(script)"
        app = XCUIApplication.antichat(["-UseScriptedEngine", engine, "-ApplePersistenceIgnoreState", "YES",
                                        "-DefaultsSuite", "com.antichat.uitest.privacy"] + extra)
        app.launch()
        XCTAssertTrue(element("composer").waitForExistence(timeout: 20), "main window did not appear")
    }

    @MainActor private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    @MainActor private func openPrivacy() {
        app.typeKey(",", modifierFlags: .command)
        element("settings.nav.privacy").click()
        XCTAssertTrue(element("privacy.statement").waitForExistence(timeout: 5))
    }

    /// AC1 + AC4: the statement verbatim, then every row of settings-map §9.
    @MainActor func testStatementAndRowsPresent() {
        launch()
        openPrivacy()
        XCTAssertEqual(element("privacy.statement").displayText,
                       "Your chats never leave this Mac unless you use an online feature. AntiChat never trains on your data and collects no usage data.")
        for id in ["offlineOnly", "networkActivity", "privacyLocation", "newChatsIncognito", "incognitoPersonalizationDefault",
                   "importChats", "exportAll", "restoreBackup", "archivedChats", "archiveAll", "deleteAll", "autoArchiveDays",
                   "crashReports", "exportLogs"] {
            XCTAssertTrue(element("settings.row.\(id)").exists, id)
        }
        for group in ["updates", "catalog", "search", "connections"] {
            XCTAssertTrue(element("networkActivity.row.\(group)").exists, group)
        }
        element("settings.control.offlineOnly").click()
        XCTAssertEqual(element("networkActivity.state.search").displayText, "Paused by Offline only")
    }

    /// AC2: a web search through the gate (the real search tool; `-ScriptedWebSearch` makes no request) → the Web search
    /// row says "Last used just now" and lists the host.
    @MainActor func testNetworkActivityAfterSearch() {
        launch(script: "web-search.jsonl")
        app.buttons["composerAdd"].click()
        XCTAssertTrue(element("addRow.web").waitForExistence(timeout: 3))
        element("addRow.web").click()
        app.textViews["composerText"].click()
        app.textViews["composerText"].typeText("What's the latest macOS version?\r")
        // Any fetched source's pill: with the real search the fetched set varies (Q-015 r4: [1] was not fetched).
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'citation.'")).firstMatch.waitForExistence(timeout: 60))
        openPrivacy()
        XCTAssertEqual(element("networkActivity.lastUsed.search").displayText, "Last used just now")
        element("networkActivity.row.search").clickDisclosure()  // a disclosure row: it toggles on its triangle (Q-015 r4)
        XCTAssertTrue(element("networkActivity.event").waitForExistence(timeout: 3))
    }

    /// AC3: never requested at launch; turning the switch on shows the explainer, then (Continue) asks once.
    /// The setting is on by default since 2026-11-16 (macOS is asked at the first search that would use it), so this
    /// starts from a user who turned it off.
    @MainActor func testLocationNotRequestedUntilEnabled() {
        launch(["-searchUsesLocation", "NO"])
        openPrivacy()
        XCTAssertTrue(element("settings.row.privacyLocation").displayText.contains("Off"))
        element("settings.control.privacyLocation").click()  // → Tools & Connections › the location row
        let toggle = element("settings.control.searchUsesLocation")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.stringValue, "0")
        toggle.click()
        XCTAssertTrue(element("location.explainer").waitForExistence(timeout: 3))
        element("location.explainer.continue").click()
        // The macOS dialog stays unanswered: the row shows the pending state (or denied, if a grant was reset to deny).
        XCTAssertTrue(element("location.notice").waitForExistence(timeout: 5))
    }
}
