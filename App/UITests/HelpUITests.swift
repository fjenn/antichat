// AT-303 UI legs (M10.T07; R-303 AC1–AC3): the Help menu (titles and order); AntiChat Help offline → the bundled
// short guide with the offline note; online → the help centre URL handed to the browser (`-OpenURLSpy`: recorded,
// never opened, no focus taken); What's new once after an update (`-SimulateUpdatedFrom`) and not on the next launch;
// the first-use "What can AntiChat do?" card gone for good after Got it (TipKit datastore in the container).
// Committed, not run on this Mac: XCUITest cannot enable automation mode here (Q-015). Run, once Q-015 is granted:
//   make test-ui FILTER=HelpUITests
// Meanwhile: `make test-unit FILTER=HelpAndLegalTests` (decisions, notes, tour content, site links) and the website
// search leg of AT-304 (`make site-test`: Pagefind "disk" → the FAQ page). Each test uses its own throwaway container
// and `-DefaultsSuite`; the relaunch legs reuse both on purpose.
import XCTest

final class HelpUITests: XCTestCase {
    /// HelpCommands order (copy keys menu.help.centre … menu.help.whatsNew); macOS adds its own Search field.
    static let menuTitles = ["AntiChat Help", "Keyboard Shortcuts", "Report a Problem…", "Privacy", "Export Logs…", "Legal",
                             "How to Uninstall", "What's New"]

    private var app: XCUIApplication!
    private var container: URL!
    private var suite: String!
    private var spy: URL!

    override func setUp() {
        continueAfterFailure = false
        container = FileManager.default.temporaryDirectory.appendingPathComponent("help-ui-\(UUID().uuidString)", isDirectory: true)
        suite = "com.antichat.uitest.help"
        spy = container.appendingPathComponent("opened-urls.txt")
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let app {
            let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    /// Same container and settings suite on every launch of one test (relaunch legs).
    /// `ready`: the element that shows the main window is up — the composer, or the What's new sheet, which covers
    /// the window's content (a modal sheet hides the composer from accessibility) after an update.
    @MainActor private func launch(_ extra: [String] = [], ready: String = "composer") {
        app?.terminate()
        app = XCUIApplication.antichat(["-ANTICHAT_DEV_CONTAINER", container.path, "-UseScriptedEngine", "basic",
                                        "-ApplePersistenceIgnoreState", "YES", "-DefaultsSuite", suite,
                                        "-OpenURLSpy", spy.path] + extra)
        app.launch()
        XCTAssertTrue(element(ready).waitForExistence(timeout: 20), "main window did not appear")
    }

    @MainActor private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    @MainActor private func helpItem(_ title: String) -> XCUIElement {
        app.menuBars.menuBarItems["Help"].menuItems[title]
    }

    @MainActor private func openHelpCentre() {
        app.menuBars.menuBarItems["Help"].click()
        helpItem("AntiChat Help").click()
    }

    @MainActor private func spied(timeout: TimeInterval = 5) -> [String] {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let s = try? String(contentsOf: spy, encoding: .utf8), !s.isEmpty {
                return s.split(separator: "\n").map(String.init)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return []
    }

    /// AC1: Help menu items, titles and order; Keyboard Shortcuts carries ⌘/.
    @MainActor func testHelpMenuItems() {
        launch(["-OfflineOnly", "YES"])
        app.menuBars.menuBarItems["Help"].click()
        let titles = app.menuBars.menuBarItems["Help"].menuItems.allElementsBoundByIndex.map(\.title).filter { !$0.isEmpty }
        XCTAssertEqual(titles.filter { Self.menuTitles.contains($0) }, Self.menuTitles, "order")
        XCTAssertTrue(helpItem("What's New").isEnabled, "notes/<version>.json is bundled")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("/", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Keyboard Shortcuts"].waitForExistence(timeout: 3), "⌘/ opens the shortcut list")
    }

    /// AC1 offline: Offline only → AntiChat Help shows the bundled guide with the offline note; nothing is opened.
    @MainActor func testHelpOfflineShowsBundledGuide() {
        launch(["-OfflineOnly", "YES"])
        openHelpCentre()
        XCTAssertTrue(element("help.guide").waitForExistence(timeout: 5), "HelpWindow with the bundled guide")
        XCTAssertEqual(element("help.offlineNote").displayText, "You're offline, so this is the short built-in guide.")
        let body = element("help.guide.body")
        let text = body.label.isEmpty ? (body.value as? String ?? "") : body.label
        for heading in ["Packs", "Evil Mode", "Uninstall"] {
            XCTAssertTrue(text.localizedCaseInsensitiveContains(heading), "guide covers \(heading)")
        }
        XCTAssertTrue(spied(timeout: 1).isEmpty, "offline: nothing handed to the browser")
        element("help.close").click()
        XCTAssertFalse(element("help.guide").exists)
    }

    /// AC1 online: AntiChat Help hands the help centre URL (the site's /help/faq/) to the browser; no sheet.
    @MainActor func testHelpOnlineOpensBrowser() {
        launch(["-OfflineOnly", "NO"])
        openHelpCentre()
        let opened = spied()
        XCTAssertEqual(opened.count, 1, "one URL handed to the browser: \(opened)")
        let url = URL(string: opened.first ?? "")
        // `URL.path` drops the trailing slash; the site's pages live at the slash form (Q-015 r3).
        XCTAssertEqual(url?.path(percentEncoded: false), "/help/faq/", "the help centre, not \(opened)")
        XCTAssertTrue(["http", "https"].contains(url?.scheme ?? ""))
        XCTAssertFalse(element("help.guide").exists, "online: no bundled guide sheet")
    }

    /// AC2: launched as an update from 0.0.0 → What's new once (3–5 items); relaunch → not shown again.
    @MainActor func testWhatsNewAfterUpdate() {
        launch(["-OfflineOnly", "YES", "-SimulateUpdatedFrom", "0.0.0"], ready: "whatsNew")
        let sheet = element("whatsNew")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "What's new after an update")
        // The title is a text SwiftUI may expose as its AX value (displayText, Q-015 r3).
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH \"What's new in AntiChat \" OR value BEGINSWITH \"What's new in AntiChat \"")).count == 1)
        app.buttons["Continue"].firstMatch.click()
        XCTAssertFalse(sheet.exists)
        launch(["-OfflineOnly", "YES", "-SimulateUpdatedFrom", "0.0.0"])  // same container + suite: version recorded
        XCTAssertFalse(element("whatsNew").waitForExistence(timeout: 3), "shown once per version")
    }

    /// AC3: the first empty chat shows "What can AntiChat do?"; Got it removes it, also after a relaunch.
    @MainActor func testTourCardDismissForGood() {
        launch(["-OfflineOnly", "YES"])
        let tip = element("tourTip")
        XCTAssertTrue(tip.waitForExistence(timeout: 5), "tour card in the first empty chat")
        XCTAssertTrue(app.staticTexts["What can AntiChat do?"].exists)
        app.buttons["Got it"].firstMatch.click()
        XCTAssertTrue(tip.waitForNonExistence(timeout: 3), "dismissed")
        launch(["-OfflineOnly", "YES"])
        XCTAssertFalse(element("tourTip").waitForExistence(timeout: 3), "gone for good (TipKit datastore in the container)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent("Tips").path),
                      "datastore under the AntiChat container")
    }
}
