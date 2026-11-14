// M3.T04 step 6 (AT-281; R-281): Basic voice before the Voice pack — dictation through SpeechAnalyzer and read aloud
// through the system voice, labelled "Basic voice"; the switch to the Voice pack happens at the next session.
// `-FakePackState voice=absent` + ScriptedVoice; the flip to `ready` goes through `TestHooks.setPackState` (a DEBUG
// distributed notification the running app observes).
// Committed, not run on this Mac (Q-015: XCUITest cannot enable automation mode); VoiceBackendSelectorTests,
// SystemVoiceBackendTests, SpeechAnalyzerBackendTests, DictationControllerTests and DictationBarSnapshotTests cover the
// logic meanwhile.
import XCTest

final class BasicVoiceTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func element(_ root: XCUIElement, _ id: String) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func launch(_ script: String = "stop-review", pack: String = "absent") -> XCUIApplication {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-UseScriptedEngine", "basic",
                                            "-FakePermission", "microphone=granted", "-FakePackState", "voice=\(pack)",
                                            "-UseScriptedVoice", "fixtures/voice/scripts/dictation-\(script).jsonl"])
        app.launch()
        return app
    }

    func dictate(_ app: XCUIApplication, seconds: Double = 4) {
        let mic = element(app, "composer.mic")
        XCTAssertTrue(mic.waitForExistence(timeout: 15))
        mic.click()
        XCTAssertTrue(element(app, "dictationBar").waitForExistence(timeout: 2))
    }

    /// AC1: the DictationBar says "Basic voice" and the final comes from SpeechAnalyzer.
    @MainActor
    func testBasicDictationLabel() throws {
        let app = launch()
        dictate(app)
        XCTAssertEqual(element(app, "voice.basic").displayText, "Basic voice")
        Thread.sleep(forTimeInterval: 4)
        element(app, "dictation.stop").click()
        let filled = NSPredicate(format: "value != %@", "")
        expectation(for: filled, evaluatedWith: element(app, "composerText"))
        waitForExpectations(timeout: 5)
    }

    /// AC1: read aloud plays through the system voice, labelled "Basic voice".
    @MainActor
    func testBasicReadAloud() throws {
        let app = launch()
        let field = element(app, "composerText")
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.click()
        field.typeText("Hello\r")
        XCTAssertTrue(element(app, "assistantMessage").waitForExistence(timeout: 10))
        element(app, "assistantMessage").hover()
        element(app, "action.readAloud").click()
        XCTAssertTrue(element(app, "voice.basic").waitForExistence(timeout: 3))
        element(app, "action.readAloud").click()  // stop
    }

    /// AC2: the pack verifies → the running dictation keeps Basic; the next one has no label.
    @MainActor
    func testSwitchesAtNextSession() throws {
        let app = launch()
        dictate(app)
        XCTAssertTrue(element(app, "voice.basic").exists)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("app.antichat.test.setPackState"), object: "voice=ready", userInfo: nil, deliverImmediately: true)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(element(app, "voice.basic").exists, "never switched mid-session")
        element(app, "dictation.cancel").click()
        dictate(app)
        XCTAssertFalse(element(app, "voice.basic").exists)
    }
}
