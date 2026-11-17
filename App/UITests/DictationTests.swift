// M3.T03 step 9 (AT-050; S-17, IS-9): dictation from the composer's mic with ScriptedVoice as the microphone
// (`-UseScriptedVoice fixtures/voice/scripts/dictation-<case>.jsonl`, `[IN-PIPELINE]`) and the scripted engine for
// the reply. The Voice pack's real models come from the dev store (`make models-dev TIER=T1`), the mic permission
// is faked granted.
// Committed, not run on this Mac (Q-015: XCUITest cannot enable automation mode); DictationServiceTests,
// DictationControllerTests, RecordingStoreTests, ParakeetBackendTests and DictationBarSnapshotTests cover the logic
// meanwhile, and `antichat-bench`'s `-Bench dictation` probe drives the helper path end to end (AT-050 log).
import XCTest

final class DictationTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func element(_ root: XCUIElement, _ id: String) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func launch(_ script: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-UseScriptedEngine", "basic",
                                            "-OfflineOnly", "YES", "-FakeVoiceInstalled", "YES",
                                            "-FakePermission", "microphone=granted",
                                            "-UseScriptedVoice", "fixtures/voice/scripts/dictation-\(script).jsonl"] + extra)
        app.launch()
        return app
    }

    func startDictation(_ app: XCUIApplication) {
        let mic = element(app, "composer.mic")
        XCTAssertTrue(mic.waitForExistence(timeout: 15))
        mic.click()
        XCTAssertTrue(element(app, "dictationBar").waitForExistence(timeout: 2))
    }

    /// Waits for capture to start (the first level update; the bar shows at the click, capture once the helper has the
    /// models), then for the fixture's speech to play out, then presses ■ and waits for the dictation to finalise.
    /// Q-015 r4: a fixed sleep from the click ended before the speech on a cold model load, so the dictation stopped
    /// with no final text and stored nothing.
    func dictateAndStop(_ app: XCUIApplication, speechEnds seconds: TimeInterval) {
        let wave = element(app, "dictation.waveform")
        let captureBy = Date().addingTimeInterval(30)
        while wave.stringValue == "0" || wave.stringValue.isEmpty, Date() < captureBy { Thread.sleep(forTimeInterval: 0.1) }
        Thread.sleep(forTimeInterval: seconds)
        element(app, "dictation.stop").click()
        XCTAssertTrue(element(app, "dictationBar").waitForNonExistence(timeout: 30), "the dictation finalised")
    }

    func composerText(_ app: XCUIApplication) -> String { (element(app, "composerText").value as? String) ?? "" }

    /// AC1: × · dots · m:ss · ■ · ↑, and the waveform follows the fixture speech (≥ 5 level changes in 2 s).
    @MainActor
    func testRecordingBarAnatomy() throws {
        let app = launch("anatomy")
        startDictation(app)
        for id in ["dictation.cancel", "dictation.waveform", "dictation.elapsed", "dictation.stop", "dictation.send"] {
            XCTAssertTrue(element(app, id).exists, id)
        }
        let wave = element(app, "dictation.waveform")
        // The bar shows at the click; capture runs once the helper has the models (Q-015 r3: the 2 s window used to
        // end before the first level arrived). The window starts at the first level update.
        let started = Date().addingTimeInterval(20)
        while wave.stringValue == "0" || wave.stringValue.isEmpty, Date() < started { Thread.sleep(forTimeInterval: 0.1) }
        var values: Set<String> = []
        let end = Date().addingTimeInterval(2.5)
        while Date() < end {
            values.insert((wave.value as? String) ?? "")
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertGreaterThanOrEqual(values.count, 5)
    }

    /// ■: the final text lands in the composer for editing (no message sent).
    @MainActor
    func testStopToReview() throws {
        let app = launch("stop-review")
        startDictation(app)
        Thread.sleep(forTimeInterval: 5)
        element(app, "dictation.stop").click()
        let filled = NSPredicate(format: "value != %@", "")
        expectation(for: filled, evaluatedWith: element(app, "composerText"))
        waitForExpectations(timeout: 3)
        XCTAssertFalse(element(app, "dictationBar").exists)
        XCTAssertFalse(composerText(app).isEmpty)
        XCTAssertFalse(element(app, "assistantMessage").exists)
    }

    /// ↑: the final text is sent as a user message (the scripted engine answers).
    @MainActor
    func testSendNow() throws {
        let app = launch("send-now")
        startDictation(app)
        Thread.sleep(forTimeInterval: 5)
        element(app, "dictation.send").click()
        XCTAssertTrue(element(app, "userBubble").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "assistantMessage").waitForExistence(timeout: 10))
    }

    /// ×: nothing reaches the composer, the bar goes away.
    @MainActor
    func testCancel() throws {
        let app = launch("cancel")
        startDictation(app)
        Thread.sleep(forTimeInterval: 2)
        element(app, "dictation.cancel").click()
        XCTAssertTrue(element(app, "composerText").waitForExistence(timeout: 2))
        XCTAssertFalse(element(app, "dictationBar").exists)
        XCTAssertEqual(composerText(app), "")
    }

    /// AC3: silence only → empty composer, no ErrorInline, no toast.
    @MainActor
    func testSilenceOnly() throws {
        let app = launch("silence")
        startDictation(app)
        Thread.sleep(forTimeInterval: 3)
        element(app, "dictation.stop").click()
        XCTAssertTrue(element(app, "composerText").waitForExistence(timeout: 3))
        XCTAssertEqual(composerText(app), "")
        XCTAssertFalse(element(app, "errorInline").exists)
        XCTAssertFalse(element(app, "toast").exists)
    }

    /// AC4: a finished dictation shows in Settings → Voice → Recent recordings.
    @MainActor
    func testRecentRecordingsList() throws {
        let app = launch("recordings")
        startDictation(app)
        dictateAndStop(app, speechEnds: 7)  // q05: 5.9 s from 0.3 s
        XCTAssertFalse(composerText(app).isEmpty, "the dictation's text is in the composer")
        app.typeKey(",", modifierFlags: .command)
        element(app, "settings.nav.capabilities").click()
        // Recent recordings sit below the fold of the Voice section (Q-015 r3).
        app.scrollViews.matching(identifier: "settings.detail.capabilities").firstMatch.scrollUntilVisible(element(app, "recording.row"))
        XCTAssertTrue(element(app, "recording.row").waitForExistence(timeout: 5))
    }

    /// AC4 / contract 3: an incognito dictation leaves no recording.
    @MainActor
    func testIncognitoKeepsNoRecording() throws {
        let app = launch("incognito")
        element(app, "incognitoButton").click()
        // The composer moves into the incognito empty state; click the mic once it has settled (Q-015 r3).
        XCTAssertTrue(element(app, "incognitoHeadline").waitForExistence(timeout: 5))
        let mic = element(app, "composer.mic")
        var last = CGRect.null
        for _ in 0..<20 where mic.frame != last { last = mic.frame; Thread.sleep(forTimeInterval: 0.15) }  // frame settled
        startDictation(app)
        dictateAndStop(app, speechEnds: 9)  // q06: 7.8 s from 0.3 s
        XCTAssertFalse(composerText(app).isEmpty, "the incognito dictation still fills the composer")
        app.typeKey(",", modifierFlags: .command)
        element(app, "settings.nav.capabilities").click()
        app.scrollViews.matching(identifier: "settings.detail.capabilities").firstMatch.scrollUntilVisible(element(app, "recordings.empty"))
        XCTAssertTrue(element(app, "recordings.empty").waitForExistence(timeout: 5))
    }
}
