// M5.T06 task checks (R-285 video scope, R-040 AC1, R-043 AC2, NFR-F9; AT-285 re-run on video). Content-free
// gradients only (ScriptedVideoEngine; Q-012).
//  - Real detectors (opt-in, `CSC_REAL_DETECTORS=1`): a scripted T2V job through
//    MediaJobRunner → every preview checked before it is written, the final frames checked once as a video, then the
//    MP4 + poster written; terminal `jobResult` with the MP4 path.
//  - UI-testing build only (`-DANTICHAT_UI_TESTING`, tools/at/at-285-runner.sh): a forced `block` on the final video
//    writes nothing at all (no MP4, no poster; no preview either when the block comes from a preview) and ends
//    `jobBlocked` with no reason; the I2V source image is never checked (zero checks besides previews + the video).
import AntiChatEngineProtocol
import AntiChatFoundation
import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import AntiChatEngines

enum VideoGateHarness {
    /// Preview checks a scripted job makes: its previews of the steps VideoPreviewPolicy shows.
    static func shownPreviews(_ s: ScriptedVideoScript) -> Int {
        (1...s.steps).filter { VideoPreviewPolicy.shows(step: $0, of: s.steps) }.count * s.previewFrames
    }

    static func request(_ dir: URL, mode: VideoRequest.Mode = .t2v, script: ScriptedVideoScript) -> VideoRequest {
        VideoRequest(mode: mode, prompt: "a lighthouse on a cliff", width: 320, height: 192, frames: script.frames, fps: script.fps, seed: 5,
                     modelDir: mode == .t2v ? "/models/vid-5b" : "", diffusionModel: mode == .i2v ? "/models/vid-i2v" : "",
                     initImage: mode == .i2v ? dir.appendingPathComponent("source.png").path : nil,
                     outputPath: dir.appendingPathComponent("out/video.mp4").path, scratchDir: "", footprintBytes: 0,
                     previewDir: dir.appendingPathComponent("xfer").path, generator: script.generator)
    }

    static func run(_ req: VideoRequest, runner: MediaJobRunner, safety: SafetyManifest?, events: EventLog) async -> MediaJobEvent {
        await runner.run(job: req.requestID.uuidString, safety: safety, previewDir: req.previewDir, outputPath: req.outputPath,
                         emit: { events.append($0) }) { outputs in
            try await ScriptedVideoEngine.run(req, isCancelled: { false }, outputs: outputs, emit: { _ in })
        }
    }

    static func files(_ dir: URL) -> [String] {
        ((FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String]) ?? []).sorted()
    }
}

@Suite(.serialized, .enabled(if: RealDetectors.manifest != nil)) struct VideoGateRealDetectorTests {
    @Test func allowedVideoIsCheckedThenWritten() async throws {
        let safety = try #require(RealDetectors.manifest)
        let dir = RunnerHarness.temp("vgate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = ScriptedVideoScript(steps: 3, delayMs: 1, frames: 33, fps: 16, previewFrames: 2)
        let req = VideoGateHarness.request(dir, script: script)
        let runner = RealDetectors.runner()
        let events = EventLog()
        let terminal = await VideoGateHarness.run(req, runner: runner, safety: safety, events: events)
        guard case .jobResult(_, let path, let meta) = terminal else {
            Issue.record("terminal \(terminal)")
            return
        }
        #expect(path == req.outputPath && FileManager.default.fileExists(atPath: path))
        #expect(meta["frames"] == "33" && meta["fps"] == "16" && meta["model"] == "vid-5b" && meta["operation"] == "generate")
        #expect(meta["poster"].map { FileManager.default.fileExists(atPath: $0) } == true)
        let shown = VideoGateHarness.shownPreviews(script)
        #expect(shown > 0)
        #expect(await runner.gateCalls(.preview) == shown)
        #expect(await runner.gateCalls(.video) == 1)
        #expect(await runner.gateCalls(.result) == 0)
        // Every written preview was announced after its check; nothing else is in the job's folders.
        #expect(VideoGateHarness.files(dir.appendingPathComponent("xfer")).count == shown)
        #expect(VideoGateHarness.files(dir.appendingPathComponent("out")) == ["video.mp4", "video.poster.jpg"])
    }
}

#if ANTICHAT_UI_TESTING
@Suite(.serialized) struct VideoGateTests {
    /// A forced block on the final video: no MP4, no poster; previews were allowed (no preview frames in this script).
    @Test func blockedVideoWritesNothing() async throws {
        let dir = RunnerHarness.temp("vblock")
        defer { try? FileManager.default.removeItem(at: dir); ForcedVerdictCheck.current = nil }
        ForcedVerdictCheck.current = .block
        let req = VideoGateHarness.request(dir, script: ScriptedVideoScript(steps: 3, delayMs: 1, frames: 33, fps: 16, previewFrames: 0, audio: true))
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let events = EventLog()
        let terminal = await VideoGateHarness.run(req, runner: runner, safety: nil, events: events)
        #expect(terminal == .jobBlocked(job: req.requestID.uuidString))
        #expect(VideoGateHarness.files(dir).isEmpty, "nothing on disk: \(VideoGateHarness.files(dir))")
        #expect(await runner.gateCalls(.video) == 1)
        #expect(await runner.gateCalls(.preview) == 0)
    }

    /// Allowed (forced) end to end: the MP4 and its poster are written after the one video check.
    @Test func allowedVideoWritesTheMP4() async throws {
        let dir = RunnerHarness.temp("vallow")
        defer { try? FileManager.default.removeItem(at: dir); ForcedVerdictCheck.current = nil }
        ForcedVerdictCheck.current = .allow
        let script = ScriptedVideoScript(steps: 3, delayMs: 1, frames: 33, fps: 16, previewFrames: 2)
        let req = VideoGateHarness.request(dir, script: script)
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let terminal = await VideoGateHarness.run(req, runner: runner, safety: nil, events: EventLog())
        guard case .jobResult(_, let path, _) = terminal else { Issue.record("terminal \(terminal)"); return }
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(await runner.gateCalls(.preview) == VideoGateHarness.shownPreviews(script))
        #expect(await runner.gateCalls(.video) == 1)
    }
}

extension VideoGateTests {
    /// M5.T07: a clip with a sound track is muxed with an AAC track after the (forced) allow; the audio is never checked.
    @Test func allowedVideoWithSoundHasAnAudioTrack() async throws {
        let dir = RunnerHarness.temp("vsound")
        defer { try? FileManager.default.removeItem(at: dir); ForcedVerdictCheck.current = nil }
        ForcedVerdictCheck.current = .allow
        let req = VideoGateHarness.request(dir, script: ScriptedVideoScript(steps: 3, delayMs: 1, frames: 33, fps: 16, previewFrames: 0, audio: true))
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let terminal = await VideoGateHarness.run(req, runner: runner, safety: nil, events: EventLog())
        guard case .jobResult(_, let path, _) = terminal else { Issue.record("terminal \(terminal)"); return }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let a = try await asset.loadTracks(withMediaType: .audio)
        let v = try await asset.loadTracks(withMediaType: .video)
        #expect(a.count == 1 && v.count == 1)
        let ad = try await a[0].load(.timeRange).duration.seconds, vd = try await v[0].load(.timeRange).duration.seconds
        #expect(abs(ad - vd) <= 0.040 + 1.0 / 16, "audio \(ad) s vs video \(vd) s")
        #expect(await runner.gateCalls(.video) == 1)
    }
}

extension VideoGateTests {
    /// M5.T14 review P1-4: a cancel that lands while the (forced) allow check runs, or while the MP4 is encoded, ends the
    /// job `jobCancelled` and leaves nothing on disk (no MP4, no poster). `isCancelled` flips on its n-th read: the
    /// runner reads it when the job starts (1, M4 review P2-1: cancelled while waiting), before the check (2), after the
    /// check (3) and after the encode (4). M10.T09: the flip points moved with the added read (2 = before the check, a
    /// cancel that never reaches the gate, is not this test's case).
    @Test(arguments: [3, 4]) func cancelDuringCheckOrEncodeWritesNothing(_ flipAt: Int) async throws {
        let dir = RunnerHarness.temp("vcancel-\(flipAt)")
        defer { try? FileManager.default.removeItem(at: dir); ForcedVerdictCheck.current = nil }
        ForcedVerdictCheck.current = .allow
        let reads = Mutex(0)
        let out = dir.appendingPathComponent("out/video.mp4")
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let frames = (0..<17).map { Data(repeating: UInt8($0 * 9), count: 64 * 32 * 4) }
        let terminal = await runner.run(job: "c\(flipAt)", safety: nil, previewDir: nil, outputPath: out.path,
                                        isCancelled: { reads.withLock { $0 += 1; return $0 >= flipAt } }, emit: { _ in }) { outputs in
            _ = try await outputs.videoResult(frames: frames, width: 64, height: 32, fps: 16,
                                              info: MP4Encoder.Info(prompt: "a lighthouse", model: "vid-5b", seed: 1, steps: 3))
            return .completed
        }
        #expect(terminal == .jobCancelled(job: "c\(flipAt)"))
        #expect(await runner.gateCalls(.video) == 1)
        #expect(VideoGateHarness.files(dir.appendingPathComponent("out")).isEmpty, "left: \(VideoGateHarness.files(dir))")
    }
}

extension R241PathTraceTests {
    /// T2V and I2V: one check per preview, one video check for the final frames, none for the I2V source image and
    /// none of the image kind (`result`).
    @Test func testVideoJobGateCalls() async throws {
        defer { ForcedVerdictCheck.current = nil }
        ForcedVerdictCheck.current = .allow
        for mode in [VideoRequest.Mode.t2v, .i2v] {
            let dir = RunnerHarness.temp("vtrace")
            defer { try? FileManager.default.removeItem(at: dir) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try ScriptedImageEngine.gradientPNG(width: 64, height: 40, phase: 1).write(to: dir.appendingPathComponent("source.png"))
            let script = ScriptedVideoScript(steps: 2, delayMs: 1, frames: 25, fps: 24, previewFrames: 3)
            let req = VideoGateHarness.request(dir, mode: mode, script: script)
            let shown = VideoGateHarness.shownPreviews(script)
            let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
            let events = EventLog()
            let terminal = await VideoGateHarness.run(req, runner: runner, safety: nil, events: events)
            guard case .jobResult(_, _, let meta) = terminal else { Issue.record("\(mode): \(terminal)"); continue }
            #expect(meta["operation"] == (mode == .i2v ? "animate" : "generate"))
            #expect(await runner.gateCalls(.preview) == shown, "\(mode)")
            #expect(await runner.gateCalls(.video) == 1, "\(mode)")
            #expect(await runner.gateCalls(.result) == 0, "\(mode): the source image is never checked")
            // Every preview's jobProgress (with a path) comes after its check, and the result comes last.
            let withPath = events.all.filter { if case .jobProgress(_, _, _, let p) = $0 { p != nil } else { false } }
            #expect(withPath.count == shown)
        }
    }
}
#endif
