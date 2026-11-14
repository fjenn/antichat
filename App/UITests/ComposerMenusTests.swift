// AT-013 (R-013, all three criteria; docs/prd/M1.md M1.T17). Committed for the serial UI run (M1.T27 step 8); on this
// Mac XCUITest cannot enable automation mode (Q-015), so the AT runs as the in-process probe
// (tools/at/at-013-probe.sh, App/AntiChat/MenusProbe.swift) until then. Variants per M1.md: chat only; Photo installed
// but off; the full fake set (Web search + Connections); D-023 (the starter shows no tool rows or chips).
import AppKit
import XCTest

final class ComposerMenusTests: XCTestCase {
    private var app: XCUIApplication!
    private var container: URL?

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

    private static let fullSet = ["-FakeInstalledPacks", "chat,photo,video", "-FakeWebSearchEnabled", "YES",
                                  "-FakeConnectionsEnabled", "YES"]

    @MainActor
    private func launch(_ extra: [String], reuseContainer: Bool = false) {
        let script = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"].map { "\($0)/scripts/basic.jsonl" }
            ?? TurnApp.script("basic.jsonl")  // fixtures repo, else the tools/fixtures staging copy (a worktree has no submodule)
        // -ApplePersistenceIgnoreState: a restored second window made "composerText" ambiguous (as WebSearchUITests).
        app = XCUIApplication.antichat(["-UseScriptedEngine", script, "-UseScriptedTools", "YES", "-OfflineOnly", "YES",
                                        "-ApplePersistenceIgnoreState", "YES"] + extra)
        if reuseContainer, let container {
            app.launchArguments += ["-ANTICHAT_DEV_CONTAINER", container.path]  // the last value wins
        } else if let i = app.launchArguments.firstIndex(of: "-ANTICHAT_DEV_CONTAINER") {
            container = URL(fileURLWithPath: app.launchArguments[i + 1])
        }
        app.launch()
        XCTAssertTrue(element("composer").waitForExistence(timeout: 20), "main window did not appear")
    }

    @MainActor private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    @MainActor private var text: XCUIElement { app.textViews["composerText"] }

    @MainActor private func openAdd() {
        app.buttons["composerAdd"].click()
        XCTAssertTrue(element("addMenu").waitForExistence(timeout: 3))
    }

    @MainActor private func row(_ id: String) -> XCUIElement { element("addRow.\(id)") }

    // MARK: (1) + menu

    @MainActor func testLeg1_ChatOnly_PacksDisabledWithReason_WebAndConnectionsAbsent() {
        launch([])
        openAdd()
        for id in ["files", "image", "video", "project"] { XCTAssertTrue(row(id).exists, id) }
        XCTAssertEqual(row("image").value as? String, "Install Photo to use this")
        XCTAssertEqual(row("video").value as? String, "Install Video to use this")
        XCTAssertFalse(row("web").exists)
        XCTAssertFalse(row("connections").exists)
    }

    @MainActor func testLeg1_PhotoInstalledButOff_EnableInSettings() {
        launch(["-FakeInstalledPacks", "chat,photo,video", "-FakeDisabledPacks", "photo"])
        openAdd()
        XCTAssertTrue(row("image").exists, "an installed-but-off pack stays listed")
        XCTAssertEqual(row("image").value as? String, "Enable in Settings")
        row("image").click()
        // Q-015 r7: the Settings window's title (and accessibility title) is its section's ("Capabilities"), not
        // "Settings"; it is found by its root container, as J09 finds it.
        XCTAssertTrue(app.windows.containing(.any, identifier: "settings.root").firstMatch.waitForExistence(timeout: 3),
                      "clicking it opens Settings")
    }

    @MainActor func testLeg1_FullSet_WebSearchAndConnectionsEnabled() {
        launch(Self.fullSet + ["-ChatModel", "chat-9b-q4"])
        openAdd()
        XCTAssertTrue(row("web").exists && row("web").isEnabled)
        XCTAssertTrue(row("connections").exists && row("connections").isEnabled)
    }

    @MainActor func testD023_StarterShowsNoToolRows() {
        launch(Self.fullSet + ["-ChatModel", "chat-0.8b"])
        openAdd()
        XCTAssertFalse(row("web").exists)
        XCTAssertFalse(row("connections").exists)
        app.typeKey(.escape, modifierFlags: [])
        text.click()
        text.typeText("/")
        XCTAssertTrue(element("slashAtMenu").waitForExistence(timeout: 2))
        XCTAssertFalse(element("menuRow.tool:echo").exists)
    }

    // MARK: (2) Triggers

    @MainActor func testLeg2_SlashAtStartAndAtMidTextOpenTheSameFilteredWrappingList() {
        launch(Self.fullSet + ["-ChatModel", "chat-9b-q4"])
        text.click()
        text.typeText("/")
        XCTAssertTrue(element("slashAtMenu").waitForExistence(timeout: 2))
        let slashRows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'menuRow.'")).count
        text.typeKey(.upArrow, modifierFlags: [])
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'menuRow.'"))
        XCTAssertTrue(rows.element(boundBy: rows.count - 1).isSelected, "↑ from the first goes to the last")
        text.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(rows.element(boundBy: 0).isSelected, "↓ from the last goes to the first")
        text.typeKey(.escape, modifierFlags: [])
        text.typeKey(.delete, modifierFlags: [])
        text.typeText("hello @")
        XCTAssertTrue(element("slashAtMenu").waitForExistence(timeout: 2))
        XCTAssertEqual(rows.count, slashRows, "@ lists the same items as /")
        text.typeText("ech")
        XCTAssertTrue(element("menuRow.tool:echo").exists)
        XCTAssertLessThan(rows.count, slashRows, "typing filters")
        text.typeKey(.escape, modifierFlags: [])
        text.typeKey("a", modifierFlags: .command)
        text.typeKey(.delete, modifierFlags: [])
        text.typeText("hello /")
        XCTAssertFalse(element("slashAtMenu").waitForExistence(timeout: 1), "/ mid-text does not open the menu")
    }

    // MARK: (3) Chips

    @MainActor func testLeg3_ChipIsStickyAndRemovalSurvivesRelaunch() {
        launch(Self.fullSet + ["-ChatModel", "chat-9b-q4"])
        text.click()
        text.typeText("@ech\r")
        XCTAssertTrue(element("toolChip.tool:echo").waitForExistence(timeout: 2), "picking a tool shows a chip")
        text.typeText("/wri\r")
        XCTAssertTrue(element("toolChip.tool:write_note").waitForExistence(timeout: 2))
        text.typeText("first message\r")
        XCTAssertTrue(element("stop").waitForNonExistence(timeout: 30))
        XCTAssertTrue(element("toolChip.tool:echo").exists, "the chip is still there for the next message")
        element("toolChipRemove.tool:echo").click()
        XCTAssertTrue(element("toolChip.tool:echo").waitForNonExistence(timeout: 2))
        app.terminate()
        launch(Self.fullSet + ["-ChatModel", "chat-9b-q4"], reuseContainer: true)
        let firstChat = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chatRow.' AND NOT (identifier IN %@)", ["chatRow.more", "chatRow.renameField", "chatRow.streaming"])).firstMatch
        XCTAssertTrue(firstChat.waitForExistence(timeout: 5))
        firstChat.click()
        XCTAssertTrue(element("toolChip.tool:write_note").waitForExistence(timeout: 3))
        XCTAssertFalse(element("toolChip.tool:echo").exists, "× stays removed after relaunch")
    }
}
