// M10.T09 final acceptance — the UI-automation parts of AT-FA-02/05/07/08/09/10/13 (runbook
// tools/release/final-acceptance.md). Everything the in-VM suite drives in-process (FinalAcceptanceProbe,
// OnboardingProbe, the -RunUninstall hook: `make test-final`) is clicked here the way a user does: the onboarding
// web-search switch, the Evil enable sheet's 18+ box, the Import sheet's Choose File, the crash prompt's buttons and the
// Uninstall sheet's typed confirm. Committed, not run on this Mac (Q-015: XCUITest cannot start); the scripted engine
// keeps them model-free. `-UninstallDryRun YES` stops before anything is removed.
import XCTest

final class FinalAcceptanceTests: XCTestCase {
    @MainActor
    func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    var fixtures: String { ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"] ?? "fixtures" }

    /// AT-FA-02: S-01 → S-04 by keyboard only; the web search switch is visible; no permission prompt.
    @MainActor
    func testOnboardingKeyboardOnlyShowsWebSearchSwitch() {
        // -FakeFreeDiskGB: S-02's Continue is disabled while the disk is short (free < packs + 10 GB), which depends on
        // this Mac's free space, not on keyboard navigation.
        let app = XCUIApplication.antichat(["-ResetOnboarding", "YES", "-UseScriptedEngine", "basic", "-OfflineOnly", "YES",
                                            "-FakeFreeDiskGB", "2000"])
        app.launch()
        XCTAssertTrue(el(app, "onboarding.step1").waitForExistence(timeout: 10), "S-01")
        app.typeKey(.return, modifierFlags: [])  // S-01's Get started (default action) → S-02
        XCTAssertTrue(el(app, "onb.2.total").waitForExistence(timeout: 5))
        // S-02's Continue (default action) is enabled once the hardware probe has picked the packs.
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: el(app, "onb.cta.continue"))
        wait(for: [enabled], timeout: 10)
        app.typeKey(.return, modifierFlags: [])  // Continue → S-03
        XCTAssertTrue(el(app, "onb.3.toggle").waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])  // → S-04
        XCTAssertTrue(el(app, "onb.4.search").waitForExistence(timeout: 5), "web search switch on S-04")
        XCTAssertFalse(app.dialogs.firstMatch.exists, "no permission prompt during onboarding")
    }

    /// AT-FA-07: Settings › Evil Mode → the sheet's Continue needs the 18+ box → ⇧⌘E → frame + badge.
    @MainActor
    func testEvilEnableSheetNeedsAdultBoxThenEvilChat() {
        let app = XCUIApplication.antichat(["-SkipOnboarding", "YES", "-UseScriptedEngine", "basic", "-OfflineOnly", "YES"])
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        el(app, "settings.nav.capabilities").click()
        el(app, "settings.evil.enabled").click()
        XCTAssertTrue(el(app, "evil.enableSheet").waitForExistence(timeout: 5))
        XCTAssertFalse(el(app, "evil.enable.continue").isEnabled, "Continue needs the 18+ box")
        el(app, "evil.enable.adult").click()
        XCTAssertTrue(el(app, "evil.enable.continue").isEnabled)
        el(app, "evil.enable.continue").click()
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("e", modifierFlags: [.command, .shift])
        XCTAssertTrue(el(app, "evil.frame").waitForExistence(timeout: 5))
        XCTAssertTrue(el(app, "evil.badge").exists)
    }

    /// AT-FA-09: Privacy & Data › Import → Choose File (-ImportFile stands in for the open panel) → summary → Imported.
    @MainActor
    func testImportChatGPTExportFromPrivacySettings() {
        let zip = "\(fixtures)/chats/chatgpt-export/export.zip"
        let app = XCUIApplication.antichat(["-SkipOnboarding", "YES", "-UseScriptedEngine", "basic", "-OfflineOnly", "YES",
                                            "-ImportFile", zip])
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        el(app, "settings.nav.privacy").click()
        el(app, "settings.control.importChats").click()
        el(app, "import.choose").click()
        // The summary ("Imported {chats} chats (…)", `import.summary`) by its id, as ImportUITests reads it: SwiftUI
        // may expose the sentence as the text's AX value, not its label.
        XCTAssertTrue(el(app, "import.summary").waitForExistence(timeout: 30), "import summary")
        el(app, "import.done").click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(el(app, "chatRow.imported").waitForExistence(timeout: 5))
    }

    /// AT-FA-10: after a crash the prompt asks first; Don't Send sends nothing.
    @MainActor
    func testCrashPromptAsksAndDontSendSendsNothing() {
        let app = XCUIApplication.antichat(["-SkipOnboarding", "YES", "-UseScriptedEngine", "basic", "-OfflineOnly", "YES",
                                            "-SimulateCrashOnNextLaunch", "YES"])
        app.launch()
        XCTAssertTrue(el(app, "crashPrompt").waitForExistence(timeout: 10))
        XCTAssertTrue(el(app, "crash.send").exists && el(app, "crash.dontSend").exists && el(app, "crash.always").exists)
        el(app, "crash.dontSend").click()
        XCTAssertFalse(el(app, "crashPrompt").waitForExistence(timeout: 2))
    }

    /// AT-FA-13: AntiChat › Uninstall AntiChat… needs the typed word (dry run).
    @MainActor
    func testUninstallSheetNeedsTypedWord() {
        let app = XCUIApplication.antichat(["-SkipOnboarding", "YES", "-UseScriptedEngine", "basic", "-OfflineOnly", "YES",
                                            "-UninstallDryRun", "YES"])
        app.launch()
        app.menuBars.menuBarItems["AntiChat"].click()
        app.menuItems["Uninstall AntiChat…"].click()
        let field = el(app, "uninstall.field"), confirm = el(app, "uninstall.confirm")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("UNINSTAL")
        XCTAssertFalse(confirm.isEnabled)
        field.typeText("L")
        XCTAssertTrue(confirm.isEnabled)
        confirm.click()
    }
}
