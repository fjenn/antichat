// M3.T06 (AT-056 AC1; R-056): an audio attachment is transcribed with a real % on its tile (`status.transcribing`),
// becomes ready with its duration, and "summarise this" sends the transcript to the model (ScriptedEngine replies).
// `-FakePackState voice=ready`, `-OfflineOnly YES` (local only). Committed, not run on this Mac (Q-015: XCUITest cannot
// enable automation mode); FilesIntakeHostTests/audioUploadBecomesATranscriptThatGoesOutWithTheMessage (in-process),
// AudioIntakeAdapterTests, FileTranscriptionClientTests and FileTranscriberRealTests cover the path meanwhile.
import XCTest

final class AudioFileTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func element(_ root: XCUIElement, _ id: String) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    func testAttachAndSummarise() throws {
        let clip = TurnApp.repoRoot.appendingPathComponent("fixtures/audio/formats/clip.m4a")
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-UseScriptedEngine", "basic",
                                            "-FakePackState", "voice=ready", "-OfflineOnly", "YES"])
        let stateLog = FileManager.default.temporaryDirectory.appendingPathComponent("tile-states-\(UUID().uuidString).log")
        app.launchEnvironment["ANTICHAT_TILE_STATE_LOG"] = stateLog.path
        app.launch()
        let field = element(app, "composerText")
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([clip as NSURL])
        field.click()
        field.typeKey("v", modifierFlags: .command)
        let tile = element(app, "fileTile")
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        // Q-015 r4: with the dev store's Parakeet the 2:01 clip transcribes in about a second, and an NSPredicate
        // expectation re-evaluates about once a second, so it saw only `ready` (r3: the tile said "clip.m4a, M4A, 2:01",
        // i.e. the transcript was in). The state is polled at 20 ms (as ReadAloud's 1 s bar), still from the tile.
        var sawTranscribing = false
        let end = Date().addingTimeInterval(30)
        while Date() < end {
            let v = tile.stringValue
            if v == "transcribing" { sawTranscribing = true; break }
            if v != "reading" { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Q-015 r5: the transcription can end between two accessibility reads, so the tile's own rendered state lines
        // (DEBUG ANTICHAT_TILE_STATE_LOG) are the record: it showed "Transcribing clip.m4a · n%" with a real percent.
        let shown = (try? String(contentsOf: stateLog, encoding: .utf8)) ?? ""
        let percentLines = shown.split(separator: "\n").filter {
            $0.hasPrefix("transcribing\t") && $0.contains("clip.m4a") && $0.hasSuffix("%")
        }
        XCTAssertTrue(sawTranscribing || !percentLines.isEmpty, "the tile shows the transcription's % (value \(tile.stringValue))")
        XCTAssertFalse(percentLines.isEmpty, "the tile rendered the transcription's % (lines: \(shown.split(separator: "\n")))")
        expectation(for: NSPredicate(format: "value == %@", "ready"), evaluatedWith: tile)
        waitForExpectations(timeout: 120)
        // Ready with the transcript in: the duration, not `tile.transcriptPending`.
        XCTAssertTrue(tile.label.hasSuffix("2:01"), tile.label)
        field.typeText("summarise this\r")
        XCTAssertTrue(element(app, "assistantMessage").waitForExistence(timeout: 10))
        // Q-015 r5: a sent attachment is the user message's `messageAttachment.n` (a button that opens it), not a text.
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'messageAttachment.' AND label == 'clip.m4a'"))
        XCTAssertTrue(sent.firstMatch.waitForExistence(timeout: 5), "the attachment went out with the message")
    }
}
