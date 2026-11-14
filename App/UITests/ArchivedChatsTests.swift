// AT-011 leg (4) UI form (M1.T22; R-011 AC4): Privacy & Data → Archived chats lists archived chats, search filters
// them, Unarchive and Delete work; Archive all; Delete all requires typing DELETE; Auto-archive defaults to Never.
// Committed, not run on this Mac (Q-015); `tools/at/at-100-probe.sh` runs the same leg in-process meanwhile.
// The virtual-clock half (30 days archives a chat inactive 31 days on the next daily run) is
// AutoArchiveServiceTests (unit).
import XCTest

final class ArchivedChatsTests: XCTestCase {
    func element(_ root: XCUIElement, _ id: String) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    func testArchivedChatsPageArchiveAllDeleteAll() {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-DefaultsSuite",
                                            "com.antichat.uitest.archived", "-UseScriptedEngine", "basic"])
        app.launch()
        let main = app.mainWindow
        // Two chats, one archived from the row menu.
        for text in ["Lisbon trip ideas", "Tax return questions"] {
            element(main, "sidebar.newChat").click()
            element(main, "composerText").click()
            app.typeText(text + "\n")
            _ = element(main, "assistantMessage").waitForExistence(timeout: 10)
        }
        app.typeKey("a", modifierFlags: [.command, .shift])  // archive the current chat

        app.typeKey(",", modifierFlags: .command)
        let w = app.windows.containing(.any, identifier: "settings.root").firstMatch
        XCTAssertTrue(w.waitForExistence(timeout: 3))
        element(w, "settings.nav.privacy").click()
        XCTAssertEqual(element(w, "settings.control.autoArchiveDays").value as? String, "Never")
        element(w, "settings.control.archivedChats").click()
        XCTAssertTrue(element(app, "archived.page").waitForExistence(timeout: 2))
        element(app, "archived.search").click()
        app.typeText("zzz")
        XCTAssertTrue(element(app, "archived.empty").waitForExistence(timeout: 1))
        element(app, "archived.done").click()

        element(w, "settings.control.archiveAll").click()
        element(app, "archiveAll.confirm").click()
        element(w, "settings.control.deleteAll").click()
        XCTAssertFalse(element(app, "deleteAll.confirm").isEnabled)
        element(app, "deleteAll.field").click()
        app.typeText("DELETE")
        XCTAssertTrue(element(app, "deleteAll.confirm").isEnabled)
        element(app, "deleteAll.confirm").click()
    }
}
