// AT-033 AC1/AC2 UI legs (R-033, M4.T13): edit by text on a generated picture (the card's Edit → the viewer's
// Describe the change → a chat turn that calls edit_image on that picture), on an uploaded picture (a chat message with
// the picture attached), and the version rail keeping every version (v1 → v2, then an edit of v1 → v3).
// The scripted chat engine plays create_image, then edit_image with `{{image}}` = the id the turn's context line names
// (what a real model copies), through the queue, the helper's runner and its gate (ScriptedImageEngine).
// Committed, not run on this Mac (Q-015: XCUITest cannot start). In-process legs that run today: ImageEditFlowTests
// (version tree, lineage, request shape, context line), R241PathTraceTests/testEditJobGateCalls (tools/at/at-285-runner.sh).
import AppKit
import XCTest

final class ImageEditTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    static let editTurn = #"{"t":"toolCallDone","id":"call_e{{n}}","name":"edit_image","args":"{\"prompt\":\"make the sky purple\",\"source_image_id\":\"{{image}}\"}","delayMs":1}"#

    /// A chat whose first turn creates a picture and whose later turns edit the picture in focus.
    /// fix/overlay-field-focus: the scripted engine picks segment k = the assistant messages in the request, so a turn's
    /// tool step and the next turn share a segment, and an assistant reply without text is left out of later prompts.
    /// The old [create][edit] script therefore played the edit in turn 1's tool step (no picture in focus yet:
    /// `source_image_id ""`, unknownSourceImage), and every later turn, its tool-only reply dropped, started at
    /// segment 0 again: a fresh create_image. Each "edit" was a new artifact with one version, so the viewer had no
    /// version rail (testVersionsKept, ImageViewerTests.testVersionRailListsVersions). Now:
    ///   segment 0: turn 1 creates the picture;
    ///   segment 1: turn 1's tool step answers in text; turn 2 ("… sky purple …") calls edit_image on the picture in
    ///              focus (`when`), and its text keeps the reply in later prompts;
    ///   segment 2: text only. A forced edit_image (the card's Edit, the viewer's Describe the change) turns it into the
    ///              call on the picture the turn names; tool steps answer in text.
    /// Pinned by ScriptedEngineTests.imageEditChatScriptEditsThePictureInFocus.
    static let editChat = [
        MediaUIApp.createImageTurn,
        #"{"t":"turn"}"#,
        #"{"t":"toolCallDone","id":"call_e{{n}}","name":"edit_image","args":"{\"prompt\":\"make the sky purple\",\"source_image_id\":\"{{image}}\"}","delayMs":1,"when":"sky purple"}"#,
        #"{"t":"textDelta","v":"Here it is.","delayMs":1}"#,
        #"{"t":"turn"}"#,
        #"{"t":"textDelta","v":"Done.","delayMs":1}"#,
    ].joined(separator: "\n")

    @MainActor
    func launch(_ extra: [String] = []) -> XCUIApplication {
        MediaUIApp.launch(chatScript: Self.editChat, extra)
    }

    @MainActor
    func results(_ app: XCUIApplication) -> XCUIElementQuery { app.descendants(matching: .any).matching(identifier: "imageJobCard.result") }

    @MainActor
    func testEditGeneratedImage() {
        let app = launch()
        MediaUIApp.send(app, "Draw me a lighthouse at dusk")
        XCTAssertTrue(results(app).element(boundBy: 0).waitForExistence(timeout: 60))
        results(app).element(boundBy: 0).hover()
        let edit = MediaUIApp.element(app, "imageResult.edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        let field = MediaUIApp.element(app, "editor.describe")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Make the sky purple")
        field.typeKey(.return, modifierFlags: [])
        // The viewer closes; the turn's edit_image card finishes as a second picture.
        XCTAssertTrue(results(app).element(boundBy: 1).waitForExistence(timeout: 60))
    }

    @MainActor
    func testEditUploadedImage() throws {
        let photo = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"] ?? "fixtures")
            .appendingPathComponent("images/photos-cc0/011.jpg")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: photo.path), "fixtures not reachable from the UI test runner")
        // The upload's turn edits it directly (segment 1 = the edit turn).
        let app = MediaUIApp.launch(chatScript: Self.editTurn)
        let input = MediaUIApp.element(app, "composerText")
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.click()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([photo as NSURL])
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "fileTile").firstMatch.waitForExistence(timeout: 10))
        MediaUIApp.send(app, "Make the sky purple")
        XCTAssertTrue(results(app).element(boundBy: 0).waitForExistence(timeout: 60), "the edit of the upload is a new picture")
    }

    @MainActor
    func testVersionsKept() {
        let app = launch()
        MediaUIApp.send(app, "Draw me a lighthouse at dusk")
        XCTAssertTrue(results(app).element(boundBy: 0).waitForExistence(timeout: 60))
        MediaUIApp.send(app, "Make the sky purple")  // v2 (the picture in focus = the newest)
        XCTAssertTrue(results(app).element(boundBy: 1).waitForExistence(timeout: 60))
        // Open v1's card, edit it from the viewer → v3, a sibling of v2.
        results(app).element(boundBy: 0).click()
        let field = MediaUIApp.element(app, "editor.describe")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("Add a moon")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(results(app).element(boundBy: 2).waitForExistence(timeout: 60))
        results(app).element(boundBy: 2).click()
        for n in 1...3 { XCTAssertTrue(MediaUIApp.element(app, "versionRail.item.\(n)").waitForExistence(timeout: 5), "v\(n) kept") }
    }

    /// fix/u5-renderer: the selection-hang check for TranscriptList's 8-row eager tail (was 60). The edit flow of
    /// testEditGeneratedImage in a chat that already holds 40 finished Markdown turns, so most selectable rows sit
    /// in the lazy section, scrolled through while the picture jobs run. The r4/r5 hang was "main thread busy 30 s"
    /// with the footprint climbing past 3 GB. Seeded by tools/at/longchat-db.sh; run with
    /// TEST_RUNNER_ANTICHAT_LONGCHAT_DB=<sqlite> TEST_RUNNER_ANTICHAT_LONGCHAT_ID=<chat id> (skipped without).
    @MainActor
    func testEditGeneratedImageInLongChat() throws {
        let env = ProcessInfo.processInfo.environment
        guard let db = env["ANTICHAT_LONGCHAT_DB"], let id = env["ANTICHAT_LONGCHAT_ID"],
            FileManager.default.fileExists(atPath: db)
        else { throw XCTSkip("no seeded long chat (tools/at/longchat-db.sh, TEST_RUNNER_ANTICHAT_LONGCHAT_DB/_ID)") }
        let box = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-uitest-longchat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: db), to: box.appendingPathComponent("antichat.sqlite"))
        // One segment: the scripted engine picks a segment by the chat's turn number, and this chat already has 40
        // turns (a two-segment script played edit_image on its first send here, with no picture to edit).
        let app = MediaUIApp.launch(container: box, chatScript: MediaUIApp.createImageTurn)
        let row = MediaUIApp.element(app, "chatRow.\(id)")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the seeded chat is in the sidebar")
        row.click()
        let transcript = app.scrollViews.matching(identifier: "transcript").firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        MediaUIApp.send(app, "Draw me a lighthouse at dusk")
        // Scroll up into the lazy rows and back while the job runs (lazy rows realized, selection overlays made).
        for _ in 0..<3 {
            transcript.scroll(byDeltaX: 0, deltaY: 4000)
            transcript.scroll(byDeltaX: 0, deltaY: -4000)
        }
        XCTAssertTrue(results(app).element(boundBy: 0).waitForExistence(timeout: 60))
        // The viewer over the transcript and back (the r4/r5 hang's tests open it), then the lazy rows again. Not
        // asserted: clicking a result does not reliably open the viewer on main either (testVersionRailListsVersions
        // fails at the same step on f767a630c); this leg checks the app stays responsive.
        results(app).element(boundBy: 0).clickReliably()
        app.typeKey(.escape, modifierFlags: [])
        transcript.scroll(byDeltaX: 0, deltaY: 6000)
        transcript.scroll(byDeltaX: 0, deltaY: -6000)
        XCTAssertTrue(MediaUIApp.element(app, "composerText").waitForExistence(timeout: 10), "the app still answers")
    }
}
