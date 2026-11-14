// M5.T11 (R-041, components §4 VideoJobCard, NFR-P3, NFR-B3/B5; AT-041 in-process legs while XCUITest cannot run,
// Q-015): the VideoJobCard's state from queue updates (real % by stage, monotonic, 100 % only with the result; stage
// lines; paused hot with [Resume]; paused for another app; the serious line), the preview set and its failure rule, the
// last-window rule while a video runs, and snapshots of every state, light/dark (Reduce Motion: the newest preview
// frame, still; the seconds read 0).
// Re-record: SNAPSHOT_TESTING_RECORD=all swift test --filter VideoJobCardTests.
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct VideoJobCardTests {
    static func update(_ state: MediaJobState, video: VideoJobStatus? = nil, position: Int? = nil, result: String? = nil,
                       code: String? = nil) -> MediaJobQueue.Update {
        MediaJobQueue.Update(job: "v1", state: state, position: position, progress: 0, previewPath: nil, resultPath: result,
                             errorCode: code, video: video)
    }

    static func spec() -> VideoRequest {
        VideoRequest(mode: .t2v, prompt: "waves", width: 1280, height: 704, frames: 81, fps: 24, seed: 1, outputPath: "",
                     scratchDir: "", footprintBytes: 0)
    }

    @Test func realPercentAndStage() {
        var s = VideoJobCardState(aspect: 1)
        s.adopt(Self.spec())
        #expect(abs(s.aspect - 1280.0 / 704) < 0.001 && s.specLine == "720p · 3.4 s", "chosen resolution and length")
        s.apply(Self.update(.queued, position: 2))
        #expect(s.stageText == "Waiting for the current job · 2 in line")
        s.apply(Self.update(.running, video: VideoJobStatus(stage: "encode", step: 1, total: 1)))
        #expect(s.progress.percent == 0 && s.stageText == "Getting the video model ready", "encode 0 %")
        s.apply(Self.update(.running, video: VideoJobStatus(stage: "denoise", step: 2, total: 3)))
        #expect(s.progress.percent == 60 && s.stageText == "Generating · step 2/3")
        s.apply(Self.update(.running, video: VideoJobStatus(stage: "decode", step: 40, total: 81)))
        #expect(s.progress.percent == 94 && s.stageText == "Finishing · frame 40/81")
        s.apply(Self.update(.running, video: VideoJobStatus(stage: "denoise", step: 1, total: 3)))
        #expect(s.progress.percent == 94, "monotonic")
        s.apply(Self.update(.running, video: VideoJobStatus(stage: "frames", step: 81, total: 81)))
        #expect(s.progress.percent == 99, "100 only with the result")
        s.apply(Self.update(.done, result: "/tmp/r.mp4"))
        #expect(s.phase == .done(resultPath: "/tmp/r.mp4") && s.progress.percent == 100 && !s.isActive)
    }

    @Test func pausedHotOffersResumeAndOtherAppDoesNot() {
        var s = VideoJobCardState(job: "v1", aspect: 16.0 / 9)
        s.apply(Self.update(.running, video: VideoJobStatus(stage: "denoise", step: 1, total: 3, notice: "thermal.serious")))
        #expect(s.noticeText == "Running slower to keep your Mac cool." && s.stageText == "Generating · step 1/3")
        s.apply(Self.update(.running, video: VideoJobStatus(stage: "denoise", step: 1, total: 3, paused: "hot")))
        #expect(s.stageText == "Paused — your Mac is hot. Resume" && s.noticeText == nil)
        #expect(VideoJobCard(state: s, onResume: {}).phaseID == "videoJobPaused")
        s.apply(Self.update(.running, video: VideoJobStatus(stage: "denoise", step: 1, total: 3, paused: "app", background: true)))
        #expect(s.stageText == "Paused for another app")
        s.apply(Self.update(.cancelled, video: VideoJobStatus(stage: "denoise", step: 1, total: 3, paused: "app")))
        #expect(s.stageText == "Cancelled" && s.video.paused == nil, "an ended job is never shown paused")
        var lost = VideoJobCardState(aspect: 1)
        lost.apply(Self.update(.lost))
        #expect(lost.stageText == "This video didn't finish. Retry")
        // VQ r65 (S-12): the failed line names the video (not "picture or video") and only "Retry" takes the accent.
        var failed = VideoJobCardState(aspect: 1)
        failed.phase = .failed(code: "video.failed")
        #expect(failed.stageText == "This video couldn't be made. Retry")
        #expect(TrailingActionLine.split(failed.stageText ?? "")?.action == "Retry")
        // M9.T08 R6: only the action word takes the accent; the status reads as the card's other lines.
        #expect(TrailingActionLine.split("Paused — your Mac is hot. Resume")! == ("Paused — your Mac is hot. ", "Resume"))
        #expect(TrailingActionLine.split("Pausiert – dein Mac ist heiß. Fortsetzen")?.action == "Fortsetzen")
        #expect(TrailingActionLine.split("This video didn't finish. Retry")?.action == "Retry")
        #expect(TrailingActionLine.split("Paused for another app") == nil)
        #expect(TrailingActionLine.split("Done. It is saved in your Library.") == nil, "a long last sentence is not an action")
        var blocked = VideoJobCardState(aspect: 1)
        blocked.apply(Self.update(.blocked))
        #expect(VideoJobCard(state: blocked).phaseID == "videoJobBlocked" && BlockedMediaTile.key(.video).string() == "This video can't be shown.")
    }

    /// The window can close while a video runs: the app stays (the helper owns the job); otherwise the menu bar rule.
    @Test func lastWindowRuleWhileAVideoRuns() throws {
        #expect(MediaJobQuitGuard.terminateAfterLastWindowClosed(menuBarItem: false, queue: nil))
        #expect(!MediaJobQuitGuard.terminateAfterLastWindowClosed(menuBarItem: true, queue: nil))
        #expect(SettingsRegistry.rows(in: .capabilities).contains { $0.id == "yieldGPU" }, "Capabilities → Advanced setting")
    }

    static func frames(_ n: Int, dir: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try (0..<n).map { i in
            let url = dir.appendingPathComponent(String(format: "preview-0003-%02d.jpg", i))
            let ctx = CGContext(data: nil, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                CGColor(red: 0.15, green: 0.35 + 0.1 * Double(i), blue: 0.8, alpha: 1), CGColor(red: 0.95, green: 0.6, blue: 0.3, alpha: 1),
            ] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 160, y: 90), options: [])
            try NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .jpeg, properties: [:])!.write(to: url)
            return url.path
        }
    }

    /// A preview that cannot be read never fails the job: the last good set stays (or the placeholder).
    @Test func previewFailureKeepsTheLastPreview() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vjc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = try Self.frames(3, dir: dir)
        #expect(good.allSatisfy { PreviewFrameCache.image($0) != nil })
        let broken = dir.appendingPathComponent("preview-0004-00.jpg")
        try Data("not a jpeg".utf8).write(to: broken)
        #expect(PreviewFrameCache.image(broken.path) == nil && PreviewFrameCache.image("/nonexistent/preview-0004-01.jpg") == nil)
        var s = VideoJobCardState(job: "v1", aspect: 16.0 / 9)
        var v = VideoJobStatus(stage: "denoise", step: 3, total: 3)
        good.forEach { v.addPreview($0, step: 3) }
        s.apply(Self.update(.running, video: v))
        v.addPreview(broken.path, step: 4)
        s.apply(Self.update(.running, video: v))
        #expect(s.isActive && s.phase == .running, "the job goes on")
        // The card keeps showing the good set while the new step's frames cannot be read.
        #expect(AnimatedPreview.displayed([broken.path], lastGood: good) == good)
        #expect(AnimatedPreview.displayed([broken.path, good[1]], lastGood: good) == [good[1]], "readable frames of the new set win")
        #expect(AnimatedPreview.displayed([broken.path], lastGood: []).isEmpty, "nothing good yet: the placeholder")
        #expect(AnimatedPreview.minSide == 160)
    }

    @Test func snapshotsOfEveryState() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vjc-snap")
        let frames = try Self.frames(3, dir: dir)
        // VQ r65 (S-12): a fixed start and a frozen clock (mediaClockNow) at the elapsed time the plan's "About 1 min"
        // gives each state, never the "0 s" of a job started in the distant future.
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func state(_ phase: VideoJobCardState.Phase, _ v: VideoJobStatus = .init(), percent: Double = 0) -> VideoJobCardState {
            var s = VideoJobCardState(job: "v1", aspect: 16.0 / 9, startedAt: start)
            s.adopt(Self.spec())
            s.video = v
            s.progress.observe(progress: percent)
            if case .done = phase { s.progress.finished() }
            s.phase = phase
            return s
        }
        let gen = VideoJobStatus(stage: "denoise", step: 3, total: 3, previewStep: 3, previewFrames: frames)
        var serious = gen
        serious.notice = "thermal.serious"
        var hot = gen
        hot.paused = "hot"
        var app = gen
        app.paused = "app"
        app.background = true
        let cases: [(String, VideoJobCardState)] = [
            ("placeholder", state(.placeholder)), ("waiting", state(.waiting(position: 2))),
            ("preparing", state(.running, VideoJobStatus(stage: "encode", step: 1, total: 1))),
            ("generating", state(.running, VideoJobStatus(stage: "denoise", step: 1, total: 3), percent: 0.3)),
            ("preview", state(.running, gen, percent: 0.9)),
            ("finishing", state(.running, VideoJobStatus(stage: "decode", step: 40, total: 81, previewStep: 3, previewFrames: frames), percent: 0.94)),
            ("serious", state(.running, serious, percent: 0.9)), ("pausedHot", state(.running, hot, percent: 0.6)),
            ("pausedApp", state(.running, app, percent: 0.6)), ("done", state(.done(resultPath: frames[0]))),
            ("blocked", state(.blocked)), ("failed", state(.failed(code: "video.failed"))), ("cancelled", state(.cancelled)),
            ("lost", state(.lost)),
        ]
        for (name, s) in cases {
            for look in ResponseActionsSnapshotTests.Look.allCases {
                let v = VideoJobCard(state: s, poster: name == "done" ? frames[0] : nil, onCancel: {}, onRetry: {}, onResume: {})
                    .environment(\.reduceMotionOverride, true)
                    .environment(\.mediaClockNow, start.addingTimeInterval(3 + 0.6 * Double(s.progress.percent)))
                assertSnapshot(of: ResponseActionsSnapshotTests.render(v, width: 420, look: look),
                               as: .image(precision: 1, perceptualPrecision: 0.98), named: "\(name)-\(look.rawValue)",
                               testName: "videoJobCard")
            }
        }
    }
}
}
