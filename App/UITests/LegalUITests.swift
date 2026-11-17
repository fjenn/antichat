// AT-217 UI leg (M10.T06; R-217 AC1/AC2): under `-OfflineOnly YES`, Settings › About & Help › Legal and Help › Legal
// list the 8 bundled pages, each with "Version {v} · {date}"; each opens and renders its body offline; nothing went
// through NetworkGate (Settings › Privacy › Network activity stays empty). "View latest online" hands the site page
// to the browser (`-OpenURLSpy`: recorded, never opened).
// Committed, not run on this Mac: XCUITest cannot enable automation mode here (Q-015). Run, once Q-015 is granted:
//   make test-ui FILTER=LegalUITests
// Meanwhile: `make test-unit FILTER=HelpAndLegalTests` and tools/site/legal-check (AT-217 log). Each test launches a
// fresh throwaway container and its own `-DefaultsSuite` (the developer's settings are never touched).
import XCTest

final class LegalUITests: XCTestCase {
    /// BundledDocument.legalOrder (App/AntiChat/Resources/Legal/*.md, synced from the site by legal-sync.py).
    static let pages = ["terms", "privacy", "evil-mode-terms", "acceptable-use", "abuse", "security", "licenses", "model-licenses"]

    private var app: XCUIApplication!
    private var spy: URL!

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

    @MainActor private func launch() {
        spy = FileManager.default.temporaryDirectory.appendingPathComponent("legal-opened-\(UUID().uuidString).txt")
        app = XCUIApplication.antichat(["-UseScriptedEngine", "basic", "-OfflineOnly", "YES", "-ApplePersistenceIgnoreState", "YES",
                                        "-DefaultsSuite", "com.antichat.uitest.legal",
                                        "-OpenURLSpy", spy.path])
        app.launch()
        XCTAssertTrue(element("composer").waitForExistence(timeout: 20), "main window did not appear")
    }

    @MainActor private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// The texts of the row carrying `id` (its title and its "Version … · …" line): the row is a container whose
    /// children keep their own text (Q-015 r3: the container's own label is empty).
    @MainActor private func labels(_ id: String) -> [String] {
        let row = app.descendants(matching: .any).matching(identifier: id).firstMatch
        return [row.displayText] + row.staticTexts.allElementsBoundByIndex.map { $0.displayText }
    }

    /// AC2: every page listed with its version and date, opens and renders offline.
    @MainActor private func checkLegalSheet() {
        XCTAssertTrue(element("legal.sheet").waitForExistence(timeout: 5), "Legal sheet")
        let version = #"Version \d+\.\d+\.\d+ · \d{4}-\d{2}-\d{2}"#
        var bodies = Set<String>()
        for id in Self.pages {
            let row = element("legal.row.\(id)")
            XCTAssertTrue(row.waitForExistence(timeout: 3), "row \(id)")
            let texts = labels("legal.row.\(id)")
            XCTAssertTrue(texts.contains { $0.range(of: version, options: .regularExpression) != nil },
                          "\(id): no 'Version x.y.z · yyyy-mm-dd' in \(texts)")
            row.click()
            let body = element("legal.body")
            XCTAssertTrue(body.waitForExistence(timeout: 3), "\(id) body")
            let text = body.label.isEmpty ? (body.value as? String ?? "") : body.label
            XCTAssertGreaterThan(text.count, 40, "\(id) renders its bundled text")
            bodies.insert(String(text.prefix(200)))
        }
        XCTAssertEqual(bodies.count, Self.pages.count, "each row shows its own page")
    }

    /// Nothing went out through NetworkGate: every category row's "last used" still reads `privacy.activity.neverUsed`
    /// ("Not used yet"; it read "Never" before VQ S-21, b0cbc561a). The list shows
    /// `networkActivity.empty` only while no category has any event, and a request Offline only refused is an event
    /// too (Q-015 r3: the check read that sentence, so a refused update check failed it).
    @MainActor private func assertNothingWentOut(file: StaticString = #filePath, line: UInt = #line) {
        let used = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'networkActivity.lastUsed.'"))
        XCTAssertTrue(used.firstMatch.waitForExistence(timeout: 5), "Network activity rows", file: file, line: line)
        let values = used.allElementsBoundByIndex.map(\.displayText)
        XCTAssertTrue(values.allSatisfy { $0 == "Not used yet" }, "NetworkGate recorded a request: \(values)", file: file, line: line)
    }

    /// AC2 "no network": the Network activity list is still empty after reading every page.
    @MainActor private func checkNoNetworkActivity() {
        app.typeKey(",", modifierFlags: .command)
        element("settings.nav.privacy").click()
        assertNothingWentOut()
        app.typeKey("w", modifierFlags: .command)
    }

    /// About & Help › Legal (Settings) lists 8 pages with version/date; each opens; NetworkGate count 0.
    @MainActor func testAboutLegalListsEightVersionedPagesOffline() {
        launch()
        app.typeKey(",", modifierFlags: .command)
        element("settings.nav.general").click()
        element("settings.control.legal").click()
        checkLegalSheet()
        app.buttons["Done"].firstMatch.click()
        XCTAssertFalse(element("legal.sheet").exists)
        element("settings.nav.privacy").click()
        assertNothingWentOut()
    }

    /// Help › Legal opens the same sheet over the chat window; "View latest online" goes to the site page (spied).
    @MainActor func testHelpMenuLegalAndViewOnline() {
        launch()
        app.menuBars.menuBarItems["Help"].click()
        app.menuBars.menuBarItems["Help"].menuItems["Legal"].click()
        checkLegalSheet()
        element("legal.row.privacy").click()
        element("legal.viewOnline").click()
        let end = Date().addingTimeInterval(5)
        var opened = ""
        while Date() < end, opened.isEmpty {
            opened = (try? String(contentsOf: spy, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if opened.isEmpty { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        }
        XCTAssertTrue(opened.hasSuffix("/legal/privacy/"), "opened \(opened)")
        XCTAssertFalse(opened.contains("/download"), "site root, not the download page: \(opened)")
        app.buttons["Done"].firstMatch.click()
        checkNoNetworkActivity()
    }
}
