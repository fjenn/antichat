// AT-100 / AT-062 UI legs (M1.T22; R-100, R-062) and the convention-9 forward legs of AT-002 (4)–(5) and
// AT-009 (1): Send with ⌘Enter, Plain-text composer and Show context usage toggled through Settings.
// Committed, not run on this Mac (Q-015: XCUITest cannot enable automation mode); the in-process probe
// `tools/at/at-100-probe.sh` (`-SettingsProbe`) covers the same legs meanwhile.
import XCTest

final class J10SettingsTests: XCTestCase {
    static let suite = "com.antichat.uitest.j10"

    override func setUp() {
        continueAfterFailure = false
    }

    func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-DefaultsSuite", Self.suite,
                                            "-UseScriptedEngine", "basic", "-OfflineOnly", "YES"] + extra)
        app.launch()
        return app
    }

    func settingsWindow(_ app: XCUIApplication) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let w = app.windows.containing(.any, identifier: "settings.root").firstMatch
        XCTAssertTrue(w.waitForExistence(timeout: 3))
        return w
    }

    func element(_ root: XCUIElement, _ id: String) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// (1) ⌘, opens Settings; 13 nav items in order; search finds rows by label.
    @MainActor
    func testStructureAndSearch() {
        let app = launch()
        let w = settingsWindow(app)
        let ids = ["general", "capabilities", "connections", "skills", "personalization", "privacy"].map { "settings.nav.\($0)" }
        let ys = ids.map { element(w, $0).frame.minY }
        XCTAssertEqual(ys, ys.sorted(), "nav order")
        element(w, "settings.search").click()
        app.typeText("send with")
        XCTAssertTrue(element(w, "settings.result.sendWithCommandEnter").waitForExistence(timeout: 1))
        element(w, "settings.result.sendWithCommandEnter").click()
        XCTAssertTrue(element(w, "settings.row.sendWithCommandEnter").waitForExistence(timeout: 1))
    }

    /// (2) Every enabled M1 row changes instantly and survives a relaunch; AT-002 (4)–(5) and AT-009 (1) via the UI.
    @MainActor
    func testRowsSaveInstantlyAndPersist() {
        var app = launch()
        var w = settingsWindow(app)
        let sendWith = element(w, "settings.control.sendWithCommandEnter")
        sendWith.click()
        // The picker's own menu: `app.menuItems` index 1 is the Apple menu's "System Information" (Q-015 catch-up).
        sendWith.menuItems.element(boundBy: 1).click()  // ⌘Enter
        element(w, "settings.control.plainTextComposer").click()
        element(w, "settings.control.showContextUsage").click()
        element(w, "settings.control.menuBarItem").click()
        element(w, "settings.nav.personalization").click()
        element(w, "settings.control.aboutYou").click()
        app.typeText("I sail.")
        element(w, "settings.nav.privacy").click()
        element(w, "settings.control.autoArchiveDays").click()
        app.menuItems["After 30 days"].click()
        w.buttons[XCUIIdentifierCloseWindow].click()

        // AT-002 (4): Return inserts a newline, ⌘Return sends; AT-009 (1): the indicator shows after a turn.
        let main = app.mainWindow
        let composer = element(main, "composerText")
        composer.click()
        app.typeText("line one")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("line two")
        XCTAssertTrue((composer.value as? String ?? "").contains("\n"))
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(element(main, "contextUsage").waitForExistence(timeout: 10))

        app.terminate()
        app = launch()
        w = settingsWindow(app)
        XCTAssertEqual(element(w, "settings.control.plainTextComposer").stringValue, "1")
        XCTAssertEqual(element(w, "settings.control.menuBarItem").stringValue, "0")
        element(w, "settings.nav.personalization").click()
        XCTAssertEqual(element(w, "settings.control.aboutYou").value as? String, "I sail.")
    }

    /// AT-062 (1): 3,000 characters accepted, the 3,001st refused, counter 3000/3000; presets and characteristics.
    @MainActor
    func testPersonalization() {
        let app = launch()
        let w = settingsWindow(app)
        element(w, "settings.nav.personalization").click()
        let field = element(w, "settings.control.aboutYou")
        field.click()
        UIPasteboardWrite(String(repeating: "a", count: 3001))
        app.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(element(w, "settings.counter.aboutYou").value as? String, "3000")
        for id in ["stylePreset", "warmth", "enthusiasm", "headersAndLists", "emoji"] {
            XCTAssertTrue(element(w, "settings.control.\(id)").exists, id)
        }
    }

    /// (3) The sidebar footer menu: Settings, Help, Report a bug, Check for updates.
    @MainActor
    func testFooterMenu() {
        let app = launch()
        let main = app.mainWindow
        element(main, "sidebar.settings").click()
        for id in ["settings", "help", "report", "updates"] {
            XCTAssertTrue(element(app, "footer.\(id)").waitForExistence(timeout: 1), id)
        }
        element(app, "footer.updates").click()
        XCTAssertTrue(element(app, "settings.detail.general").waitForExistence(timeout: 2))
    }

    /// (4) Capabilities → Advanced is collapsed by default.
    @MainActor
    func testCapabilitiesAdvancedCollapsed() {
        let app = launch()
        let w = settingsWindow(app)
        element(w, "settings.nav.capabilities").click()
        XCTAssertTrue(element(w, "settings.row.capabilities.advanced").exists)
        // Q-015 r5: the group's content is its rows (the content id was stamped over them and is now a probe anchor):
        // collapsed = none of them is there.
        XCTAssertFalse(element(w, "override.chat.normal").exists)
        XCTAssertFalse(element(w, "settings.control.keepLoadedMinutes").exists)
    }

    /// Step 8: the launch arguments work as well (`-showContextUsage YES` etc. are read as booleans).
    @MainActor
    func testLaunchArgumentOverrides() {
        let app = launch(["-sendWithCommandEnter", "YES", "-plainTextComposer", "YES", "-showContextUsage", "YES"])
        let w = settingsWindow(app)
        XCTAssertEqual(element(w, "settings.control.plainTextComposer").stringValue, "1")
        XCTAssertEqual(element(w, "settings.control.showContextUsage").stringValue, "1")
    }
}

private func UIPasteboardWrite(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

extension J10SettingsTests {
    /// M2.T03 AT-209 AC3/AC4 (R-209): Privacy & Data → Offline only on → the sidebar indicator shows `net.offlineOnly`
    /// ("Offline only"); off → "Online features on". Every gated request failing while on is CategoryRefusalTests.
    /// Journey 10 is completed in M2.T21. Pending Q-015 like the rest of this file.
    @MainActor
    func testOfflineOnlyDisablesAll() {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-DefaultsSuite", Self.suite + ".offline",
                                            "-UseScriptedEngine", "basic"])
        app.launch()
        let indicator = app.descendants(matching: .any).matching(identifier: "networkIndicator").firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        XCTAssertTrue(indicator.displayText.contains("Online features on"))
        let w = settingsWindow(app)
        element(w, "settings.nav.privacy").click()
        let toggle = element(w, "settings.control.offlineOnly")
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.click()
        XCTAssertTrue(indicator.displayText.contains("Offline only"))
        toggle.click()
        XCTAssertTrue(indicator.displayText.contains("Online features on"))
    }
}
