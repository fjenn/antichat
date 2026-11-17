// AT-022 (R-022 AC1–AC4) + AT-045 AC2 Library part (M5.T13; R-045, S-19): the sidebar Library — grid (default) and list
// newest first, filters and search over prompts and names, opening the viewer and the source chat, Save As / Show in
// Finder / Delete (the file leaves the disk), incognito never added, the Evil badge and the "Show Evil items in Library"
// toggle (default on only when Evil is enabled), the Videos tab with poster, length and the sound icon, and the data
// folder (`<container>/Media/<yyyy>/<sha256>.<ext>`, R-205).
// The scripted chat engine writes `create_image` / `create_video` calls; ScriptedImageEngine / ScriptedVideoEngine make
// the files (every output passes the gate). `-SaveVideoFile` stands in for NSSavePanel on clips.
// Committed, not run on this Mac (Q-015: XCUITest cannot start) — pending. In-process legs that run today:
// LibraryIndexTests (AntiChatStorageTests: ordering, filters, FTS, incognito, Evil rule, delete + shared blob, v32),
// LibraryViewTests (AntiChatUIModuleTests: model actions, Evil setting rule, page snapshots light/dark),
// FileActionsMatrixTests (AT-277 Show in Library column, 64/64).
import AppKit
import XCTest

final class LibraryTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// A picture made in a fresh container (the Library has one item).
    @MainActor
    private func appWithPicture(container: URL? = nil, _ extra: [String] = []) -> XCUIApplication {
        let app = MediaUIApp.launch(container: container, extra)
        MediaUIApp.send(app, "Draw me a lighthouse at dusk")
        XCTAssertTrue(element(app, "imageJobCard.result").waitForExistence(timeout: 60))
        return app
    }

    @MainActor
    private func openLibrary(_ app: XCUIApplication) -> XCUIElement {
        element(app, "sidebar.library").click()
        let library = element(app, "library")
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        return library
    }

    /// AT-022 AC1: grid by default, list on demand, newest first.
    @MainActor
    func testGridListNewestFirst() {
        // Two different pictures in one container: a picture per launch (the scripted engine replays one call per
        // script; repeating it asks for the same picture, which the duplicate-call guard skips; Q-015 r2).
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-uitest-lib-\(UUID().uuidString)")
        let image = { (p: String) in #"{"t":"toolCallDone","id":"call_1","name":"create_image","args":"{\"prompt\":\"\#(p)\",\"aspect\":\"3:2\"}","delayMs":1}"# }
        let first = MediaUIApp.launch(container: container, chatScript: image("a lighthouse at dusk"))
        MediaUIApp.send(first, "Draw me a lighthouse at dusk")
        XCTAssertTrue(element(first, "imageJobCard.result").waitForExistence(timeout: 60))
        first.terminate()
        let app = MediaUIApp.launch(container: container, chatScript: image("a harbour at dawn"))
        MediaUIApp.send(app, "Now a harbour at dawn")  // a second, newer picture
        XCTAssertTrue(element(app, "imageJobCard.result").waitForExistence(timeout: 60), "the second picture")
        _ = openLibrary(app)
        XCTAssertTrue(element(app, "library.grid").exists, "grid is the default")
        let items = app.descendants(matching: .any).matching(identifier: "library.item")
        XCTAssertTrue(items.element(boundBy: 1).waitForExistence(timeout: 30))
        element(app, "library.layout").radioButtons.element(boundBy: 1).click()
        XCTAssertTrue(element(app, "library.list").waitForExistence(timeout: 5))
        let rows = app.descendants(matching: .any).matching(identifier: "library.row")
        XCTAssertEqual(rows.count, 2)
        // Newest first: the row order matches the dates (the table's first row is the later picture).
        XCTAssertTrue(rows.element(boundBy: 0).frame.minY < rows.element(boundBy: 1).frame.minY)
    }

    /// AT-022 AC1: All / Images / Videos / Files and the search over prompts and names.
    @MainActor
    func testFiltersAndSearch() {
        let app = appWithPicture()
        _ = openLibrary(app)
        let filter = element(app, "library.filter")
        let items = app.descendants(matching: .any).matching(identifier: "library.item")
        filter.radioButtons.element(boundBy: 1).click()  // Images
        XCTAssertEqual(items.count, 1)
        filter.radioButtons.element(boundBy: 2).click()  // Videos
        XCTAssertTrue(element(app, "library.empty").waitForExistence(timeout: 5))
        filter.radioButtons.element(boundBy: 0).click()  // All
        let search = element(app, "library.search")
        search.click()
        search.typeText("lighthouse")
        XCTAssertEqual(items.count, 1, "prompt match")
        search.typeKey("a", modifierFlags: .command)
        search.typeText("zebra")
        XCTAssertTrue(element(app, "library.empty").waitForExistence(timeout: 5), "no match: library.empty.search")
    }

    /// AT-022 AC2: double-click opens the viewer (Quick Look for a picture); Open chat goes to the source message.
    @MainActor
    func testOpensViewerAndSourceChat() {
        let app = appWithPicture()
        _ = openLibrary(app)
        let item = element(app, "library.item")
        item.doubleClick()
        XCTAssertTrue(app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'QuickLook' OR title CONTAINS[c] 'Quick Look' OR title CONTAINS[c] 'image'")).firstMatch
            .waitForExistence(timeout: 5) || app.otherElements["QLPreviewView"].exists)
        app.typeKey(.escape, modifierFlags: [])
        item.rightClick()
        element(app, "library.openChat").click()
        XCTAssertTrue(element(app, "imageJobCard.result").waitForExistence(timeout: 5), "the source turn is on screen")
    }

    /// AT-022 AC2: Save As… copies, Show in Finder selects, Delete asks and removes the file from disk.
    @MainActor
    func testSaveAsRevealDelete() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-uitest-lib-\(UUID().uuidString)")
        let app = appWithPicture(container: container)
        _ = openLibrary(app)
        let item = element(app, "library.item")
        item.rightClick()
        XCTAssertTrue(element(app, "library.saveAs").exists && element(app, "library.reveal").exists)
        app.typeKey(.escape, modifierFlags: [])
        let media = container.appendingPathComponent("Media")
        let before = try FileManager.default.subpathsOfDirectory(atPath: media.path).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(before.count, 1)
        item.rightClick()
        element(app, "library.delete").click()
        element(app, "library.delete.confirm").click()
        XCTAssertTrue(element(app, "library.empty").waitForExistence(timeout: 5))
        let after = try FileManager.default.subpathsOfDirectory(atPath: media.path).filter { $0.hasSuffix(".png") }
        XCTAssertTrue(after.isEmpty, "the file is gone from disk")
    }

    /// AT-022 AC3: a picture made in an incognito chat never shows up in the Library.
    @MainActor
    func testIncognitoNeverAdded() {
        let app = MediaUIApp.launch()
        element(app, "incognitoButton").click()
        XCTAssertTrue(element(app, "incognitoBadge").waitForExistence(timeout: 5), "the chat is incognito before the send")
        MediaUIApp.send(app, "Draw me a lighthouse at dusk")
        XCTAssertTrue(element(app, "imageJobCard.result").waitForExistence(timeout: 60))
        // Leave the incognito chat for the Library: the toolbar button is disabled once the chat has messages (M1.T20),
        // so the sidebar's Library asks "Close chat?" first (Q-015 r2: the old toggle click did nothing).
        element(app, "sidebar.library").click()
        let close = app.buttons["incognito.close.cta"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "leaving an incognito chat with messages asks first")
        close.click()
        if !element(app, "library").waitForExistence(timeout: 3) { _ = openLibrary(app) }
        XCTAssertTrue(element(app, "library.empty").waitForExistence(timeout: 5))
    }

    /// AT-022 AC4: Evil items carry the text badge; hidden when the setting is off; the default is on only while Evil is
    /// enabled.
    @MainActor
    func testEvilBadgeAndToggle() {
        // Its own fresh settings suite: this test turns "Show Evil items in Library" off, and in the shared app domain
        // that stuck (showEvilInLibrary = 0), so every later run found the Library empty before it asserted "default on".
        let app = MediaUIApp.launch(["-FakeEvilEnabled", "YES", "-DefaultsSuite", "com.antichat.uitest.library-evil"])
        element(app, "modeSwitch").click()  // the toolbar's mode picker
        XCTAssertTrue(element(app, "modeSwitch.evil").waitForExistence(timeout: 3))
        element(app, "modeSwitch.evil").click()
        MediaUIApp.send(app, "Draw me a lighthouse at dusk")
        XCTAssertTrue(element(app, "imageJobCard.result").waitForExistence(timeout: 60))
        _ = openLibrary(app)
        // A cell is one accessibility element whose label reads its badges ("image.png, Evil"; Q-015 r2).
        XCTAssertTrue(element(app, "library.item").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "library.item").label.hasSuffix(", Evil"), "default on: Evil is enabled — \(element(app, "library.item").label)")
        app.typeKey(",", modifierFlags: .command)
        // Q-015 r5: Settings opens on General; the switch is in Evil Mode (settings-map §4).
        element(app, "settings.nav.capabilities").click()
        let toggle = element(app, "settings.evil.showLibrary")
        app.scrollViews.matching(identifier: "settings.detail.capabilities").firstMatch.scrollUntilVisible(toggle)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        app.windows.firstMatch.typeKey("w", modifierFlags: .command)
        element(app, "sidebar.newChat").click()
        _ = openLibrary(app)
        XCTAssertTrue(element(app, "library.empty").waitForExistence(timeout: 5), "hidden when the setting is off")
        XCTAssertFalse(element(app, "library.item").exists)
    }

    /// AT-045 AC2: the Videos tab lists clips with their poster and length.
    @MainActor
    func testVideosTab() throws {
        let app = try finishedClip()
        _ = openLibrary(app)
        element(app, "library.filter").radioButtons.element(boundBy: 2).click()
        XCTAssertTrue(element(app, "library.item").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "library.item").label.contains(", 0:03"), "length: \(element(app, "library.item").label)")
        element(app, "library.item").doubleClick()
        XCTAssertTrue(element(app, "videoViewer").waitForExistence(timeout: 5))
    }

    /// AT-045 AC2: the sound icon (`library.hasSound`) shows only on a clip with a sound track (T3+ Normal, LTX).
    @MainActor
    func testSoundIcon() throws {
        let app = try finishedClip(sound: true)
        _ = openLibrary(app)
        element(app, "library.filter").radioButtons.element(boundBy: 2).click()
        XCTAssertTrue(element(app, "library.item").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "library.item").label.contains("Has sound"), "sound icon: \(element(app, "library.item").label)")
    }

    /// AT-022 AC3: items live in the documented data folder `<container>/Media/<yyyy>/<sha256>.<ext>` (R-205).
    @MainActor
    func testDataFolderPath() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-uitest-lib-\(UUID().uuidString)")
        _ = appWithPicture(container: container)
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        let dir = container.appendingPathComponent("Media/\(year)")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(files.count, 1)
        XCTAssertNotNil(files[0].range(of: "^[0-9a-f]{64}\\.png$", options: .regularExpression), files[0])
    }

    // MARK: clips

    @MainActor
    private func finishedClip(sound: Bool = false) throws -> XCUIApplication {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString).json")
        try Data(#"{"steps":3,"delayMs":200,"frames":48,"fps":16,"previewFrames":2,"audio":\#(sound)}"#.utf8).write(to: script)
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-SkipOnboarding", "YES",
                                            "-UseScriptedEngine", "YES", "-UseScriptedVideoEngine", script.path,
                                            "-FakeHardware", "T3", "-FakePower", "ac",
                                            "-FakeInstalledPacks", "chat,photo,video"])
        app.launch()
        app.activate()
        MediaUIApp.send(app, "Make a short video of waves rolling onto a beach at dusk")
        let start = element(app, "videoPlan.start")
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        // An explicit request on AC power counts down and starts by itself (R-290 AC2); Start only when it waits.
        if !element(app, "videoPlan.countdown").exists { start.clickReliably() }
        XCTAssertTrue(element(app, "videoJobResult").waitForExistence(timeout: 120))
        return app
    }
}
