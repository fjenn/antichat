// M3.T11 step 6 (AT-052; S-16, IS-9): the voice conversation in a chat, with ScriptedVoice as the microphone
// (`-UseScriptedVoice fixtures/voice/scripts/conversation-<case>.jsonl`, `[IN-PIPELINE]`) and the scripted engine for the
// replies (`stream-600w` = a reply long enough to barge into). The Voice pack's real models come from the dev store
// (`make models-dev TIER=T1`); the mic permission is faked granted.
// Committed, not run on this Mac (Q-015: XCUITest cannot enable automation mode). Meanwhile VoiceSessionTests,
// VoiceSessionStateTests, BargeInFixtureTests (real models), VoiceTurnBridgeTests, VoiceSessionControllerTests and
// VoiceOverlaySnapshotTests cover the logic, and `-Bench voice-session` drives the helper path end to end (AT-052 log).
import XCTest

final class VoiceConversationTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func element(_ root: XCUIElement, _ id: String) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func launch(_ script: String, engine: String = "fixtures/scripts/stream-600w.jsonl", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-UseScriptedEngine", engine,
                                            "-OfflineOnly", "YES", "-FakeVoiceInstalled", "YES",
                                            "-FakePermission", "microphone=granted",
                                            "-UseScriptedVoice", "fixtures/voice/scripts/conversation-\(script).jsonl"] + extra)
        app.launch()
        return app
    }

    func startVoice(_ app: XCUIApplication) {
        let button = element(app, "composer.voice")
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.click()
        XCTAssertTrue(element(app, "voiceOverlay").waitForExistence(timeout: 3))
    }

    /// The chat's turns: UserBubble (`userBubble`) and AssistantMessageView (`assistantMessage`); the voice turns are
    /// ordinary chat messages (Q-015 r3: `message.<role>` was the pre-M1.T06 placeholder row's id).
    func messages(_ app: XCUIApplication, role: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: role == "user" ? "userBubble" : "assistantMessage")
    }

    /// AC1: orb · caption · mute mic · mute speaker · × End above the composer of the same chat; typing still sends a
    /// turn whose reply is spoken.
    @MainActor
    func testOverlayAnatomyAndTyping() throws {
        let app = launch("empty", engine: "basic")
        startVoice(app)
        for id in ["voice.orb", "voice.caption", "voice.muteMic", "voice.muteSpeaker", "voice.end"] {
            XCTAssertTrue(element(app, id).exists, id)
        }
        let field = element(app, "composerText")
        field.click()
        field.typeText("Hello there\r")
        XCTAssertTrue(messages(app, role: "assistant").firstMatch.waitForExistence(timeout: 15))
        let orb = element(app, "voice.orb")
        XCTAssertTrue(orb.waitForPhase("Speaking", timeout: 15), "the typed turn's reply is spoken")
        element(app, "voice.end").click()
    }

    /// AC2: hands-free is the default; push-to-talk holds Space (composer not first responder).
    @MainActor
    func testHandsFreeDefaultAndPTT() throws {
        let app = launch("question", engine: "basic")
        startVoice(app)
        XCTAssertEqual(element(app, "voiceOverlay").displayText, "Hands-free")  // M9.T01: localised; the label (Q-015 r3)
        XCTAssertTrue(messages(app, role: "user").firstMatch.waitForExistence(timeout: 20), "hands-free: the turn ends by itself")
        element(app, "voice.end").click()
        app.terminate()

        let ptt = launch("question", engine: "basic", extra: ["-voiceMode", "pushToTalk"])
        startVoice(ptt)
        XCTAssertEqual(element(ptt, "voiceOverlay").displayText, "Push-to-talk (hold Space)")
        element(ptt, "voice.orb").click()  // focus off the composer field (Space is push-to-talk only then)
        Thread.sleep(forTimeInterval: 8)
        XCTAssertFalse(messages(ptt, role: "user").firstMatch.exists, "no Space held: no turn in push-to-talk")
        element(ptt, "voice.end").click()
    }

    /// AC3: barge in while the reply is spoken → the first reply is `interrupted` (its stored text = what was heard) and
    /// the interrupting utterance gets a second reply.
    @MainActor
    func testBargeInAnswersNewUtterance() throws {
        let app = launch("barge-in")
        startVoice(app)
        let assistants = messages(app, role: "assistant")
        XCTAssertTrue(assistants.element(boundBy: 1).waitForExistence(timeout: 40), "a second reply exists")
        XCTAssertTrue(element(app, "interruptedNotice").exists, "the first reply is interrupted")  // status interrupted
        element(app, "voice.end").click()
    }

    /// AC5: the turns are chat messages (user + assistant), captions are visible while speaking.
    @MainActor
    func testTranscriptAsTurnsAndCaptions() throws {
        let app = launch("question")
        startVoice(app)
        XCTAssertTrue(messages(app, role: "user").firstMatch.waitForExistence(timeout: 20))
        // AC6 with the menu bar item on (the default): the item carries the call and says so (Q-015 r4).
        XCTAssertEqual(app.menuBars.statusItems["menuBarItem"].stringValue, "Voice conversation in progress")
        XCTAssertTrue(element(app, "voice.orb").waitForPhase("Speaking", timeout: 20))
        let caption = element(app, "voice.caption")
        XCTAssertFalse((caption.value as? String ?? "").isEmpty, "the spoken sentence is captioned")
        XCTAssertTrue(messages(app, role: "assistant").firstMatch.exists)
        element(app, "voice.end").click()
    }

    /// AC6: the session keeps running hidden; the menu bar indicator exists during the call and is gone after End.
    @MainActor
    func testKeepsRunningInBackground() throws {
        // M8.T13: while the menu bar item is on (the default) it carries the call; M3.T11's own indicator shows only with
        // that item off (CallIndicatorExtra). This leg turns the item off to see the indicator (Q-015 r4).
        let app = launch("question", extra: ["-menuBarItem", "NO"])
        startVoice(app)
        XCTAssertTrue(callIndicator(app).waitForExistence(timeout: 5))
        let hide = NSAppleScript(source: "tell application \"System Events\" to set visible of process \"AntiChat\" to false")
        hide?.executeAndReturnError(nil)
        Thread.sleep(forTimeInterval: 15)
        app.activate()
        XCTAssertTrue(messages(app, role: "assistant").firstMatch.waitForExistence(timeout: 20), "the reply came while hidden")
        element(app, "voice.end").click()
        XCTAssertFalse(callIndicator(app).waitForExistence(timeout: 2), "removed after End")
    }

    /// The call indicator's status item: its id, or its label (`voice.callActive`) where the MenuBarExtra's id does not
    /// reach the status item.
    func callIndicator(_ app: XCUIApplication) -> XCUIElement {
        app.menuBars.statusItems.matching(NSPredicate(format: "identifier == 'callIndicator' OR label == %@",
                                                      "Voice conversation in progress")).firstMatch
    }

    /// IS-9: a session with no utterance writes nothing (no message rows, the chat keeps its pending title).
    @MainActor
    func testEmptySessionWritesNothing() throws {
        let app = launch("empty", engine: "basic")
        startVoice(app)
        Thread.sleep(forTimeInterval: 5)
        element(app, "voice.end").click()
        XCTAssertFalse(messages(app, role: "user").firstMatch.exists)
        // A chat row (`chatRow.<id>`); the sidebar's own rows (New chat, Search, …) are outline cells too (Q-015 r3).
        let chatRows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chatRow.'"))
        XCTAssertFalse(chatRows.firstMatch.exists, "no chat row was created")
    }

    /// M3.T12 AT-280 AC2: VPIO unavailable → half duplex; the hint under the orb says `voice.headphones`.
    @MainActor
    func testHalfDuplexHint() throws {
        let app = launch("question", engine: "basic", extra: ["-FakeAEC", "unavailable"])
        startVoice(app)
        // The session decides half duplex when its audio starts, after the models load ("Getting voice ready…"); a cold
        // load on a busy Mac took longer than the hint's 10 s wait (Q-015 r3 v2: still connecting at the failure).
        let orb = element(app, "voice.orb")
        let end = Date().addingTimeInterval(45)
        while orb.label == "Getting voice ready…", Date() < end { Thread.sleep(forTimeInterval: 0.2) }
        let hint = element(app, "voice.headphonesHint")
        XCTAssertTrue(hint.waitForExistence(timeout: 10))
        XCTAssertTrue(hint.displayText.contains("Use headphones to interrupt by voice"), hint.displayText)
        element(app, "voice.end").click()
    }

    /// M3.T12 AT-280 AC3: with the ducking setting off on a headphone route the session runs without VPIO (nothing
    /// is ducked); on speakers VPIO stays at the minimum level. The test hook is the session's `audio.ducking.*`
    /// signpost, mirrored in the overlay's accessibility value only in DEBUG builds; the in-process legs are
    /// HalfDuplexPolicyTests.duckingPlan and `tools/voice/ducking-check.sh`.
    @MainActor
    func testDuckingSettingOff() throws {
        let app = launch("question", engine: "basic", extra: ["-FakeAudioRoute", "headphones", "-voiceDuckOthers", "NO"])
        startVoice(app)
        XCTAssertFalse(element(app, "voice.headphonesHint").waitForExistence(timeout: 3), "headphones: full duplex")
        element(app, "voice.end").click()
    }
}

extension XCUIElement {
    /// The orb's phase (`voice.orb`): M9.T01 made the localised phase its label ("Speaking", `a11y.voice.speaking`), so
    /// VoiceOver reads it; there is no AX value any more (Q-015 r4: the suite still polled the value for "speaking").
    func waitForPhase(_ phase: String, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if label == phase { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    func waitForValue(containing text: String, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if (value as? String ?? "").contains(text) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}
