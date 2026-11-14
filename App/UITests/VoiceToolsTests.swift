// M3.T13 AT-057 (R-057): tools during a voice conversation. AC1 runs with the real M7 tools (D-026 note 5, the M3.T14
// re-run moved from M7.T16): web search with `-ScriptedWebSearch YES` (M7.T01 recorded search, no request) and a connection from the recorded MCP session `-ScriptedMCP fixtures/web/mcp/scripted-server.jsonl` (M7.T06; the live
// reference server `tools/mcp-ref/` is the OAuth leg); AC2 with the media / file tools (scripted engine tool calls).
// "Spoken text" = the overlay caption of each spoken chunk (`voice.caption`).
// In-process legs: VoiceToolsTests (Harness: pointer stored + spoken, approvals by voice) and VoiceTurnBridgeTests.
// Q-015 r4: the scripts are `tools/fixtures/scripts/voice-*.jsonl` (the web search / connection / file calls of the
// earlier fixtures failed their tools' schemas); the picture and the video run on the scripted media engines with their
// packs present, as the M4 / M5 suites do (without them `create_image` showed the Photo install card, no picture); the
// connection is added through Settings first (`-ScriptedMCP` answers only a connection the user added); every tool's
// ActivityLine (`activityLine`, value = its state) must end `done`.
import XCTest

final class VoiceToolsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func element(_ root: XCUIElement, _ id: String) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func launch(engine: String, extra: [String] = [], startVoice: Bool = true) -> XCUIApplication {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-UseScriptedEngine", engine,
                                            "-FakeVoiceInstalled", "YES", "-FakePermission", "microphone=granted",
                                            "-UseScriptedVoice", "fixtures/voice/scripts/conversation-question.jsonl"] + extra)
        app.launch()
        if startVoice { self.startVoice(app) }
        return app
    }

    func startVoice(_ app: XCUIApplication) {
        let button = element(app, "composer.voice")
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.click()
        XCTAssertTrue(element(app, "voiceOverlay").waitForExistence(timeout: 5))
    }

    static func imageScript() -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-image-\(UUID().uuidString).json")
        try? Data(#"{"steps":4,"delayMs":200}"#.utf8).write(to: url)
        return url.path
    }

    @MainActor func spokenCaptions(_ app: XCUIApplication, until text: String, timeout: TimeInterval = 45) -> Bool {
        let caption = element(app, "voice.caption")
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            // Q-015 r5: read from one snapshot (nil while the caption is not in the tree): `value` of a caption that
            // is momentarily absent (between utterances) failed the test with "No matches found".
            if (((try? caption.snapshot())?.value as? String) ?? "").contains(text) { return true }
            usleep(100_000)
        }
        return false
    }

    /// The reply's ActivityLine reaches `state` (its accessibility value).
    func activity(_ app: XCUIApplication, reaches state: String, timeout: TimeInterval = 45) -> Bool {
        let line = element(app, "activityLine")
        guard line.waitForExistence(timeout: timeout) else { return false }
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if line.stringValue == state { return true }
            usleep(100_000)
        }
        return false
    }

    /// AC1: a spoken question runs web search; the ActivityLine shows in the thread and the reply is spoken.
    @MainActor
    func testSearchDuringVoice() throws {
        let app = launch(engine: "tools/fixtures/scripts/voice-web-search.jsonl", extra: ["-ScriptedWebSearch", "YES"])
        XCTAssertTrue(activity(app, reaches: "done"), "web search ran: \(element(app, "activityLine").displayText)")
        XCTAssertTrue(element(app, "activityLine").displayText.contains("Searched the web"), element(app, "activityLine").displayText)
        XCTAssertTrue(spokenCaptions(app, until: "According to"))
    }

    /// AC1: a connection's tool (the recorded Team Chat session) during voice; the reply after it is spoken.
    @MainActor
    func testConnectionDuringVoice() throws {
        let app = launch(engine: "tools/fixtures/scripts/voice-mcp.jsonl",
                         extra: ["-ScriptedMCP", "fixtures/web/mcp/scripted-server.jsonl"], startVoice: false)
        MCPUI.addTeamChat(app)
        startVoice(app)
        // A new connection's tools ask first (ToolAnnotations: Ask unless curated); the card is answered by its button
        // here (the spoken "allow once" leg is VoiceToolsTests in-process).
        let allow = element(app, "approveAllowOnce")
        if allow.waitForExistence(timeout: 45) { allow.clickReliably() }
        XCTAssertTrue(activity(app, reaches: "done"), "the connection's tool ran: \(element(app, "activityLine").displayText)")
        XCTAssertTrue(spokenCaptions(app, until: "two messages about the standup"))
    }

    /// AC2: a picture made during voice → its tile in the thread; the spoken reply says where it is.
    @MainActor
    func testImageDuringVoiceSpokenPointer() throws {
        let app = launch(engine: "fixtures/scripts/voice-create-image.jsonl",
                         extra: ["-UseScriptedImageEngine", Self.imageScript(), "-FakePackState", "photo=ready"])
        // The pointer is added only for a picture that was made (SpokenSummary: successful calls).
        XCTAssertTrue(spokenCaptions(app, until: "I've made the picture, it's in the chat"))
    }

    @MainActor
    func testVideoDuringVoiceSpokenPointer() throws {
        let app = launch(engine: "fixtures/scripts/voice-create-video.jsonl",
                         extra: ["-UseScriptedVideoEngine", "YES", "-FakeHardware", "T3", "-FakePower", "ac",
                                 "-FakeInstalledPacks", "chat,photo,video"])
        app.startVideoPlan()  // the plan card: a spoken request that is not explicitly a video waits for Start
        XCTAssertTrue(spokenCaptions(app, until: "I've made the video, it's in the chat", timeout: 90))
    }

    @MainActor
    func testFileDuringVoiceSpokenPointer() throws {
        let app = launch(engine: "tools/fixtures/scripts/voice-create-file.jsonl")
        XCTAssertTrue(spokenCaptions(app, until: "I've made the file, it's in the chat"))
        XCTAssertTrue(activity(app, reaches: "done"))
    }
}
