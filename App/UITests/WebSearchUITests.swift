// AT-080 / AT-250 c1 (R-080 AC1–AC4, R-250 AC1; docs/prd/M7.md M7.T03). Committed for the serial UI run; on this Mac
// XCUITest cannot enable automation mode (Q-015), so the AT runs as the in-process probe (tools/at/at-080-probe.sh,
// App/AntiChat/SearchProbe.swift) until then. All legs use the ScriptedEngine and `-ScriptedWebSearch YES` (fixed
// sources: 1–4 fetched of 9, no network) except the switch / consent / offline legs.
import AppKit
import XCTest

final class WebSearchUITests: XCTestCase {
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

    @MainActor private func launch(script: String, _ extra: [String] = []) {
        let root = ProcessInfo.processInfo.environment["ANTICHAT_ROOT"] ?? TurnApp.repoRoot.path
        // The + menu's Web search row is offered only to a model that takes tools (D-023 a). The harness pins one
        // for scripts with a tool call; the switch / consent / offline legs (web-plain, no call) got the chat-only
        // starter and never saw the row (Q-015 r4).
        app = XCUIApplication.antichat(["-UseScriptedEngine", "\(root)/tools/fixtures/scripts/\(script)",
                                        "-DefaultsSuite", "com.antichat.uitest.websearch", "-FreshDefaultsSuite", "YES",
                                        // Q-015 r4: a restored second window made "composerAdd" ambiguous.
                                        "-ApplePersistenceIgnoreState", "YES", "-ChatModel", "chat-9b-q4"] + extra)
        app.launch()
        XCTAssertTrue(element("composer").waitForExistence(timeout: 20), "main window did not appear")
    }

    @MainActor private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    @MainActor private var text: XCUIElement { app.textViews["composerText"] }

    @MainActor private func pickWebSearch() {
        app.buttons["composerAdd"].click()
        XCTAssertTrue(element("addRow.web").waitForExistence(timeout: 3))
        element("addRow.web").click()
    }

    @MainActor private func send(_ s: String) {
        text.click()
        text.typeText(s + "\r")
    }

    @MainActor func testOnboardingSwitchDefaultOn() {
        // Enough free disk for the default selection (the fake-disk seam, as AccessibilityAuditTests.testOnboarding):
        // on a nearly full Mac step 2's Continue is disabled ("Needs N GB more") and step 4 is never reached.
        app = XCUIApplication.antichat(["-ResetOnboarding", "YES", "-FakeFreeDiskGB", "2000"])
        app.launch()
        // Step 4 (Preparing): the web search switch is On with its note. Onboarding waits for the user on steps 1–3
        // (Return = the step's primary button; Q-015 r2: the test only waited).
        for _ in 0..<4 where !element("onb.4.search").waitForExistence(timeout: 5) {
            app.typeKey(.return, modifierFlags: [])
        }
        XCTAssertTrue(element("onb.4.search").waitForExistence(timeout: 60))
        XCTAssertEqual(element("onb.4.search").stringValue, "1")
    }

    @MainActor func testSettingsToggleAndOfflineOnly() {
        launch(script: "web-plain.jsonl")
        app.typeKey(",", modifierFlags: .command)
        element("settings.nav.tools").click()
        let web = element("settings.control.webSearch")
        XCTAssertTrue(web.waitForExistence(timeout: 5))
        XCTAssertEqual(web.stringValue, "1")
        web.click()  // off
        XCTAssertEqual(web.stringValue, "0")
        web.click()  // on → consent
        XCTAssertTrue(element("search.consentSheet").waitForExistence(timeout: 3))
        element("search.consent.on").click()
        XCTAssertEqual(web.stringValue, "1")
        element("settings.nav.privacy").click()
        element("settings.control.offlineOnly").click()
        element("settings.nav.tools").click()
        XCTAssertEqual(element("settings.control.webSearch").stringValue, "0")
        XCTAssertFalse(element("settings.control.webSearch").isEnabled)
    }

    @MainActor func testConsentSheetWhenEnabledLater() {
        launch(script: "web-plain.jsonl")
        app.typeKey(",", modifierFlags: .command)
        element("settings.nav.tools").click()
        element("settings.control.webSearch").click()  // off
        app.typeKey("w", modifierFlags: .command)
        pickWebSearch()
        XCTAssertTrue(element("search.consentSheet").waitForExistence(timeout: 3))
        let body = element("search.consent.body").displayText
        XCTAssertTrue(body.contains("DuckDuckGo") && body.contains("Never your chats or your name."))
        element("search.consent.cancel").click()
        XCTAssertFalse(element("toolChip.web").exists)
    }

    @MainActor func testChipForcesSearchAndPills() {
        launch(script: "web-search.jsonl", ["-ScriptedWebSearch", "YES"])
        pickWebSearch()
        XCTAssertTrue(element("toolChip.web").waitForExistence(timeout: 3))
        send("What's the latest macOS version?")
        XCTAssertTrue(element("citation.1").waitForExistence(timeout: 20))
        element("citation.1").hover()
        XCTAssertTrue(element("citationHoverCard").waitForExistence(timeout: 3))
    }

    @MainActor func testEveryPillMapsToFetchedSource() {
        launch(script: "web-search.jsonl", ["-ScriptedWebSearch", "YES"])
        pickWebSearch()
        send("What's the latest macOS version?")
        XCTAssertTrue(element("citation.1").waitForExistence(timeout: 20))
        // Round 65 VQ S-10 (098544b61): the pills of a line are one grouped chip ("site +N", `citation.<first>`) that
        // answers for every pill it stands for in its accessibility label ("title, site; …").
        let chip = element("citation.1").displayText
        let fetched = ["macreleasenotes.example", "desktopweekly.example", "techdigest.example", "machelp.example"]
        let unfetched = ["rumourmill.example", "appleforum.example", "dailymac.example", "macblog.example", "newsbrief.example"]
        for (i, site) in fetched.enumerated() { XCTAssertTrue(chip.contains(site), "pill \(i + 1) in the chip: \(chip)") }
        for (i, site) in unfetched.enumerated() { XCTAssertFalse(chip.contains(site), "no pill for unfetched \(i + 5): \(chip)") }
        for n in 2...9 { XCTAssertFalse(element("citation.\(n)").exists, "one chip for the line, no pill \(n) of its own") }
        element("sourcesButton").click()
        XCTAssertTrue(element("sourcesPanel").waitForExistence(timeout: 3))
        for n in 1...4 { XCTAssertTrue(element("sourcesRow.\(n)").exists, "row \(n)") }
        for n in 5...9 { XCTAssertFalse(element("sourcesRow.\(n)").exists) }
    }

    @MainActor func testReadThisURL() {
        launch(script: "web-read.jsonl", ["-ScriptedWebSearch", "YES"])
        text.click()
        text.typeText("Summarise https://example.org/article for me")
        XCTAssertTrue(element("readURLSuggestion").waitForExistence(timeout: 3))
        element("readURLSuggestion").click()
        XCTAssertTrue(element("toolChip.readUrl").exists)
        text.typeText("\r")
        XCTAssertTrue(element("citation.1").waitForExistence(timeout: 20))
        XCTAssertFalse(element("toolChip.readUrl").exists)
    }

    @MainActor func testOfflineChipAndNotice() {
        launch(script: "web-plain.jsonl", ["-OfflineOnly", "YES"])
        pickWebSearch()
        XCTAssertTrue(element("toolChipOffline.web").waitForExistence(timeout: 3))
        send("What's the latest macOS version?")
        XCTAssertTrue(element("activityNotice-network.offlineForSearch").waitForExistence(timeout: 20))
    }
}
