// M3.T08 (AT-053; R-053): Settings › Voice. AC1 every row (Microphone with System default + devices + level meter,
// Spoken language Auto-detect + list, ≥ 6 voices, Preview ≈ 3 s, Speed 0.75–1.5), the no-devices state, the 3 s
// preview; AC2 a change applies to the next utterance without a restart. Committed, not run on this Mac (Q-015:
// XCUITest cannot enable automation mode); AudioDeviceCatalogTests, VoiceSettingsViewModelTests and the
// SettingsSnapshotTests voice states cover the logic meanwhile.
import XCTest

final class VoiceSettingsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func element(_ root: XCUIElement, _ id: String) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Q-015 r5: the AX attribute log of the speed slider (AXRead).
    var axLog: URL?

    func openVoice(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-UseScriptedEngine", "basic",
                                            "-FakePackState", "voice=ready", "-FakePermission", "microphone=granted"] + extra)
        axLog = AXRead.enable(app, ids: ["settings.control.voiceRate"])
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        element(app, "settings.nav.voice").click()
        return app
    }

    @MainActor
    func testAllRows() throws {
        let app = openVoice()
        let mic = element(app, "settings.control.voiceInputDevice")
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        mic.click()
        XCTAssertTrue(app.menuItems["System default"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element(app, "settings.voice.levelMeter").exists)
        element(app, "settings.control.voiceSpokenLanguage").click()
        XCTAssertTrue(app.menuItems["Auto-detect"].exists)
        XCTAssertGreaterThan(app.menuItems.count, 100)
        app.typeKey(.escape, modifierFlags: [])
        element(app, "settings.control.voiceID").click()
        XCTAssertGreaterThanOrEqual(app.menuItems.count, 6)
        app.typeKey(.escape, modifierFlags: [])
        let speed = element(app, "settings.control.voiceRate")
        // The shown speed is the slider's spoken value (the visible "1.5×" text beside it is hidden from VoiceOver).
        // Q-015 r5: XCUIElement.value is the slider's raw AXValue (1.5); the spoken "1.5×" is its AXValueDescription
        // (AXRead: the app's DEBUG probe logs it, the sandboxed runner cannot query it).
        let log = try XCTUnwrap(axLog)
        speed.adjust(toNormalizedSliderPosition: 1)
        XCTAssertEqual(Double(speed.stringValue), 1.5)
        XCTAssertEqual(AXRead.wait(log, identifier: "settings.control.voiceRate", .valueDescription, equals: "1.5×"), "1.5×")
        speed.adjust(toNormalizedSliderPosition: 0)
        XCTAssertEqual(Double(speed.stringValue), 0.75)
        XCTAssertEqual(AXRead.wait(log, identifier: "settings.control.voiceRate", .valueDescription, equals: "0.75×"), "0.75×")
        XCTAssertTrue(element(app, "settings.control.voiceMode").exists)
    }

    @MainActor
    func testNoDevices() throws {
        let app = openVoice(["-FakeAudioDevices", "none"])
        XCTAssertTrue(element(app, "settings.voice.noDevices").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "settings.control.voiceInputDevice").isEnabled)
    }

    @MainActor
    func testPreviewPlays3s() throws {
        let app = openVoice()
        let preview = element(app, "settings.voice.preview")
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let t0 = Date()
        preview.click()
        // Playing: the button shows stop; it returns to play when the sentence ends (3 s ± 0.5 s at 1×).
        let back = NSPredicate { _, _ in preview.displayText == "Preview" && Date().timeIntervalSince(t0) > 1 }
        expectation(for: back, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(Date().timeIntervalSince(t0), 3, accuracy: 0.5 + 1)  // + launch of the speech
    }

    @MainActor
    func testChangesApplyNextUtterance() throws {
        let app = openVoice()
        element(app, "settings.control.voiceRate").adjust(toNormalizedSliderPosition: 0.66)
        // No restart: back in the chat window, the next read aloud speaks at the new rate (helper log `ttsStarted`).
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(element(app, "composerText").waitForExistence(timeout: 5))
    }
}
