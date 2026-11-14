// AT-045 AC1 + AC2 (export part) and R-040 AC3 (M5.T12; R-045, P-media-13): the inline player in the video result card
// (play/pause, scrub, loop, mute, full screen), the full-window viewer with Save As…, and Export MP4 (the exported file
// plays — AVURLAsset.isPlayable — and keeps the AI mark; "Save without prompt details" drops the prompt).
// The scripted chat engine writes the `create_video` call; the helper's ScriptedVideoEngine makes the clip
// (`-UseScriptedVideoEngine <script.json>`; every frame passes the gate). `-SaveVideoFile` stands in for NSSavePanel.
// Committed, not run on this Mac (Q-015: XCUITest cannot start) — pending. In-process legs that run today:
// InlineVideoPlayerTests (AntiChatUIModuleTests: loop/mute defaults on real MP4s, toggles, done-card snapshots) and
// MediaProvenanceMP4ExportTests (AntiChatToolsTests: plays, mark kept, prompt stripped).
import AVFoundation
import AppKit
import XCTest

final class VideoPlayerTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// A finished clip in the transcript (scripted job: 3 quick steps, 48 frames at 16 fps = 3 s, so it loops).
    @MainActor
    private func finishedClip(_ extra: [String] = []) throws -> XCUIApplication {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("vp-\(UUID().uuidString).json")
        try Data(#"{"steps":3,"delayMs":200,"frames":48,"fps":16,"previewFrames":2}"#.utf8).write(to: script)
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-SkipOnboarding", "YES",
                                            "-UseScriptedEngine", "YES", "-UseScriptedVideoEngine", script.path,
                                            "-FakeHardware", "T3", "-FakePower", "ac",
                                            "-FakeInstalledPacks", "chat,photo,video"] + extra)
        app.launch()
        app.activate()
        let input = element(app, "composerText")
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.click()
        input.typeText("Make a short video of waves rolling onto a beach at dusk")
        input.typeKey(.return, modifierFlags: [])
        app.startVideoPlan()
        XCTAssertTrue(element(app, "videoJobResult").waitForExistence(timeout: 120), "the clip")
        return app
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// AT-045 AC1: poster first; play mounts the player with inline controls (play/pause, scrub, full screen); loop is on
    /// for a ≤ 10 s clip and mute is on for a clip without sound; both toggle.
    @MainActor
    func testInlineControls() throws {
        let app = try finishedClip()
        XCTAssertTrue(element(app, "videoJob.poster").exists, "poster first")
        let loop = element(app, "videoPlayer.loop"), mute = element(app, "videoPlayer.mute")
        XCTAssertTrue(loop.isSelected, "loop on by default (3 s clip)")
        XCTAssertFalse(mute.isSelected, "muted: the scripted clip has no sound")
        element(app, "videoPlayer.play").click()
        let view = element(app, "videoPlayer.view")
        XCTAssertTrue(view.waitForExistence(timeout: 5), "AVPlayerView mounted")
        view.hover()
        // AVPlayerView's inline controls (system: play/pause button, scrubber slider, full-screen toggle).
        XCTAssertTrue(view.buttons.count >= 1 || view.sliders.count >= 1, "inline controls")
        if view.sliders.firstMatch.exists { view.sliders.firstMatch.adjust(toNormalizedSliderPosition: 0.5) }  // scrub
        // Q-015 r5: the selected trait follows the player model a moment after the click (re-read, bounded).
        loop.click()
        XCTAssertTrue(loop.wait(2) { !$0.isSelected }, "loop off")
        mute.click()
        XCTAssertTrue(mute.wait(2) { $0.isSelected }, "unmuted")
        // Q-015 r6: AVKit exposes its full-screen toggle as a checkbox ("toggle full screen", a two-state control), not a
        // button; any element type.
        let fullScreen = view.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS[c] 'full' OR label CONTAINS[c] 'full'")).firstMatch
        XCTAssertTrue(fullScreen.exists, "full-screen toggle")
    }

    /// R-040 AC3: the clip opens in the viewer with Save As… (and Show in Finder); Esc closes it.
    @MainActor
    func testViewerSaveAs() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-\(UUID().uuidString).mp4")
        let app = try finishedClip(["-SaveVideoFile", out.path])
        element(app, "videoPlayer").hover()
        element(app, "videoPlayer.expand").click()
        XCTAssertTrue(element(app, "videoViewer").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "videoViewer.reveal").exists)
        element(app, "videoViewer.saveAs").click()
        XCTAssertTrue(waitForFile(out))
        XCTAssertTrue(AVURLAsset(url: out).isPlayable)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(element(app, "videoViewer").waitForExistence(timeout: 2))
    }

    /// AT-045 AC2 (export part): ⋯ → Export MP4 → an MP4 that plays and keeps the AI mark; with "Save without prompt
    /// details" the prompt is gone and the mark stays.
    @MainActor
    func testExportMP4() throws {
        for strip in [false, true] {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).mp4")
            let app = try finishedClip(["-SaveVideoFile", out.path] + (strip ? ["-SaveVideoWithoutDetails"] : []))
            element(app, "videoJob.more").clickReliably()
            element(app, "videoJob.export").clickReliably()
            XCTAssertTrue(waitForFile(out))
            XCTAssertTrue(AVURLAsset(url: out).isPlayable, "exported file plays")
            let bytes = try Data(contentsOf: out)
            XCTAssertNotNil(bytes.range(of: Data("trainedAlgorithmicMedia".utf8)), "AI mark kept")
            XCTAssertEqual(bytes.range(of: Data("waves rolling".utf8)) == nil, strip, strip ? "prompt stripped" : "prompt kept")
            app.terminate()
        }
    }
}
