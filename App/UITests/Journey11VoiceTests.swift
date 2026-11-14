// M3.T11 step 6 / test-strategy §4.1 journey 11 (AT-052): dictate a question → stop-to-review → send; open voice → ask
// (q02) → barge in (`barge-in/item03-room1-user.wav`) → a second reply exists → End. ScriptedVoice + ScriptedEngine by
// default; `JOURNEY11_REAL=1` drops the scripted engine for the tier cap's real chat model (`make models-dev
// TIER=T1|T3`), so STT, LLM and TTS are all real.
// Committed, not run on this Mac (Q-015). The helper path runs end to end in `-Bench voice-session` and BargeInFixtureTests.
import XCTest

final class Journey11VoiceTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func element(_ root: XCUIElement, _ id: String) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    func testDictationThenVoiceWithBargeIn() throws {
        let real = ProcessInfo.processInfo.environment["JOURNEY11_REAL"] == "1"
        var args = ["-ApplePersistenceIgnoreState", "YES", "-OfflineOnly", "YES", "-FakeVoiceInstalled", "YES",
                    "-FakePermission", "microphone=granted",
                    "-UseScriptedVoice", "fixtures/voice/scripts/journey11-dictation.jsonl"]
        args += real ? [] : ["-UseScriptedEngine", "fixtures/scripts/stream-600w.jsonl"]  // real: the XPC helper + tier-cap chat
        let app = XCUIApplication.antichat(args)
        app.launch()
        // 1. Dictate q01, stop to review, send.
        let mic = element(app, "composer.mic")
        XCTAssertTrue(mic.waitForExistence(timeout: 15))
        mic.click()
        XCTAssertTrue(element(app, "dictationBar").waitForExistence(timeout: 2))
        // q01 (7.1 s) plays 1 s after capture starts, and capture starts once the helper has loaded the models: the bar
        // shows at the click, before that. A cold load on a busy Mac ate the fixed 9 s, so ■ came before the speech ended
        // (Q-015 r4). The timeline starts at the first level update (DictationTests.testRecordingBarAnatomy).
        let wave = element(app, "dictation.waveform")
        let captureBy = Date().addingTimeInterval(30)
        while wave.stringValue == "0" || wave.stringValue.isEmpty, Date() < captureBy { Thread.sleep(forTimeInterval: 0.1) }
        Thread.sleep(forTimeInterval: 9)
        element(app, "dictation.stop").click()
        // ■ finalises first (the bar stays while the last words are transcribed); the field is hidden from
        // accessibility until then, so it was read too early (r3: "No matches found" for composerText).
        XCTAssertTrue(element(app, "dictationBar").waitForNonExistence(timeout: 30), "the dictation finalised")
        let field = element(app, "composerText")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value != %@", ""), evaluatedWith: field)
        waitForExpectations(timeout: 5)
        field.typeText("\r")
        let assistants = app.descendants(matching: .any).matching(identifier: "assistantMessage")
        XCTAssertTrue(assistants.firstMatch.waitForExistence(timeout: 30))
        app.terminate()
        // 2. Voice in the same chat: q02, then a barge-in during the spoken reply.
        args = args.map { $0.hasSuffix("journey11-dictation.jsonl") ? "fixtures/voice/scripts/journey11.jsonl" : $0 }
        let voice = XCUIApplication.antichat(args)
        voice.launch()
        let button = element(voice, "composer.voice")
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.click()
        let replies = voice.descendants(matching: .any).matching(identifier: "assistantMessage")
        XCTAssertTrue(replies.element(boundBy: 1).waitForExistence(timeout: real ? 90 : 40), "a second reply after the barge-in")
        element(voice, "voice.end").click()
        XCTAssertFalse(element(voice, "voiceOverlay").waitForExistence(timeout: 1))
    }
}
