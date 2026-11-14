// M3.T02 step 6 (S-05 "asked the first time", S-24, IS-10): the just-in-time microphone flow from the composer's
// mic button with the Voice pack present (`-FakeVoiceInstalled YES`).
// Committed, not run on this Mac (Q-015: XCUITest cannot enable automation mode); PermissionCenterTests and
// PermissionSnapshotTests cover the logic and the views meanwhile. The real system dialog is accepted in vq-08
// step 1 with computer use (Q-021) — macOS draws it in a system process, so testMicPromptFlow stops at
// "system dialog requested" when run with `-FakePermission microphone=notDetermined`.
import XCTest

final class PermissionJITTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func element(_ root: XCUIElement, _ id: String) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func launch(_ permission: String) -> XCUIApplication {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-UseScriptedEngine", "basic",
                                            "-OfflineOnly", "YES", "-FakeVoiceInstalled", "YES",
                                            "-FakePermission", "microphone=\(permission)"])
        app.launch()
        return app
    }

    /// First click → sheet with `voice.permission` → [Continue] → the (fake) dialog grants → mic ready.
    @MainActor
    func testMicPromptFlow() throws {
        let app = launch("notDetermined")
        let mic = element(app, "composer.mic")
        XCTAssertTrue(mic.waitForExistence(timeout: 15))
        XCTAssertEqual(mic.value as? String, "needsPermission")  // nothing asked before the click
        mic.click()
        XCTAssertTrue(element(app, "permissionPromptSheet").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "voice.permission").exists)
        element(app, "voice.permission.continue").click()
        // Granted → the click the user made goes on: dictation starts (the DictationBar replaces the mic while it
        // records, so the mic's own `ready` value is read after Cancel; Q-015 r3).
        XCTAssertTrue(element(app, "dictationBar").waitForExistence(timeout: 5), "granted: dictation started")
        element(app, "dictation.cancel").click()
        let ready = NSPredicate(format: "value == %@", "ready")
        expectation(for: ready, evaluatedWith: mic)
        waitForExpectations(timeout: 5)
    }

    /// Denied → popover with `voice.denied` (opens System Settings › Privacy › Microphone).
    @MainActor
    func testMicDenied() throws {
        let app = launch("denied")
        let mic = element(app, "composer.mic")
        XCTAssertTrue(mic.waitForExistence(timeout: 15))
        mic.click()
        XCTAssertTrue(element(app, "permissionDeniedPopover").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "voice.denied").exists)
        XCTAssertFalse(element(app, "permissionPromptSheet").exists)
    }

    /// [Not now] closes the sheet without asking; the next click shows it again.
    @MainActor
    func testNotNowAsksNothing() throws {
        let app = launch("notDetermined")
        let mic = element(app, "composer.mic")
        XCTAssertTrue(mic.waitForExistence(timeout: 15))
        mic.click()
        element(app, "voice.permission.later").click()
        XCTAssertEqual(mic.value as? String, "needsPermission")
    }
}
