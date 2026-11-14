// fix/t05-video (NFR-F7 video leg, F7_VIDEO T3; VID2): structural checks of the gate-time changes. None of them
// relaxes D-006 — these pin that down:
//  - which previews the runtime is asked for (VideoEngine.previewPlan): none below the gate's valid preview size (none
//    of them could ever be shown), exactly that size above it, and only the steps VideoPreviewPolicy shows;
//  - frame coverage: the streamed final check (T3+, preload) sees exactly the one-shot path's sampled frames;
//  - order: the streamed verdict is applied before anything is written, and fails closed (no detectors ⇒ nothing);
//  - a too-small preview is withheld without loading the detectors, nothing is written, and the final check still runs
//    and still fails closed on a damaged install.
// Content-free: flat buffers and gradients only (D-017).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization
import Testing
@testable import AntiChatEngines

@Suite(.serialized) struct VideoGateTimingTests {
    @Test func previewPlanFollowsTheGatesValidSize() {
        let min = 512
        // T3 default 832×480: no preview can be shown at 480 px, so none is made (the card shows step progress).
        #expect(VideoEngine.previewPlan(width: 832, height: 480, minSide: min) == nil)
        #expect(VideoEngine.previewPlan(width: 480, height: 832, minSide: min) == nil)
        // T4 default 1280×704: previews at the valid size, only the shown steps.
        let t4 = VideoEngine.previewPlan(width: 1280, height: 704, minSide: min)
        #expect(t4 == VideoEngine.PreviewPlan(shortSide: 512, minFraction: VideoPreviewPolicy.minDenoiseFraction))
        // Exactly at the size; unreadable thresholds (Int.max) ⇒ never.
        #expect(VideoEngine.previewPlan(width: 512, height: 900, minSide: min)?.shortSide == 512)
        #expect(VideoEngine.previewPlan(width: 1280, height: 704, minSide: Int.max) == nil)
        // The plumbing-test setting (min side 0) keeps the runtime's 160 px floor, never above the clip.
        #expect(VideoEngine.previewPlan(width: 320, height: 192, minSide: 0)?.shortSide == 160)
        #expect(VideoEngine.previewPlan(width: 120, height: 96, minSide: 0)?.shortSide == 96)
        // The product value is the shipped threshold.
        #expect(MediaOutputGate.previewMinSide == 512)
    }

    /// Frame coverage is the same whichever path checks the clip: the stream hands the check exactly
    /// `MediaOutputGate.sampleIndices` (≥ 2 fps + first + last), the set the one-shot path builds images for.
    @Test(arguments: [(73, 24.0), (121, 24.0), (81, 24.0), (97, 24.0), (25, 16.0)])
    func streamedCheckSeesTheOneShotSampleSet(_ frames: Int, _ fps: Double) async throws {
        let seen = Mutex<[Int]>([])
        let s = VideoCheckStream(job: "j", frameCount: frames, width: 8, height: 8, fps: fps) { stream in
            Task {
                do { for try await f in stream { seen.withLock { $0.append(f.index) } } } catch { return .block }
                return .allow
            }
        }
        var i = 0
        while i < frames {  // in decode-sized chunks, as StreamedFrames pulls them
            let k = Swift.min(16, frames - i)
            try s.append((i..<i + k).map { _ in Data(repeating: 9, count: 8 * 8 * 4) })
            i += k
        }
        #expect(s.close()?.count == frames)
        #expect(await s.check.value == .allow)
        let expected = MediaOutputGate.sampleIndices(frameCount: frames, fps: fps)
        #expect(seen.withLock { $0 } == expected.sorted())
        #expect(expected.contains(0) && expected.contains(frames - 1))
    }

    /// Order + fail closed on the streamed path (T3+ with the preload): the verdict comes first; without detectors it
    /// withholds and nothing is written; the gate note says the final check streamed and no preview was checked.
    @Test func streamedVerdictComesBeforeAnyWriteAndFailsClosed() async throws {
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let dir = RunnerHarness.temp("vtiming")
        defer { try? FileManager.default.removeItem(at: dir) }
        let notes = Mutex<[SchedulerNote]>([])
        let terminal = await StreamHarness.run(dir, runner: runner) { outputs, s in
            try s.append(StreamHarness.frames(25))
            do {
                _ = try await outputs.finishVideo(s, info: StreamHarness.info())
            } catch {
                await outputs.noteGateTiming(emit: { ev in if case .scheduler(let n) = ev { notes.withLock { $0.append(n) } } })
                throw error
            }
        }
        guard case .safetyMissing = terminal else { Issue.record("terminal \(terminal)"); return }
        #expect(StreamHarness.files(dir).isEmpty, "nothing written before (or without) an allow")
        #expect(await runner.gateCalls(.video) == 1)
        #expect(await runner.gateCalls(.preview) == 0)
        let gate = notes.withLock { $0 }.first { $0.action == "videoGate" }
        #expect(gate?.detail["streamed"] == "1" && gate?.detail["preview_checks"] == "0")
    }

    /// A preview below the valid size: withheld (job goes on, nothing written, no path announced) without loading the
    /// detectors; the final frames are still checked and a damaged install still fails closed there.
    @Test func smallPreviewIsWithheldWithoutALoadAndTheFinalCheckStillFailsClosed() async throws {
        let (install, damaged) = try MediaOutputGateTests.fakeInstall()
        defer { try? FileManager.default.removeItem(at: install) }
        try Data("flipped".utf8).write(to: URL(fileURLWithPath: damaged.nudityPath))
        let dir = RunnerHarness.temp("vsmall")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let events = EventLog()
        let goOn = Mutex<Bool?>(nil)
        let loadedAfterPreview = Mutex<Bool?>(nil)
        let side = MediaOutputGate.previewMinSide - 1
        let terminal = await runner.run(job: "small", safety: damaged, previewDir: dir.appendingPathComponent("xfer").path,
                                        outputPath: dir.appendingPathComponent("out/v.mp4").path, emit: { events.append($0) }) { outputs in
            let jpeg = ScriptedVideoEngine.gradientJPEG(width: side + 64, height: side, phase: 1)
            goOn.withLock { $0 = true }
            let ok = await outputs.preview(jpeg, step: 3, totalSteps: 3, frame: 0)
            goOn.withLock { $0 = ok }
            let loaded = await runner.detectorsLoaded
            loadedAfterPreview.withLock { $0 = loaded }
            let frames = (0..<17).map { ScriptedVideoEngine.gradientRGBA(width: 32, height: 16, phase: $0) }
            _ = try await outputs.videoResult(frames: frames, width: 32, height: 16, fps: 16, info: StreamHarness.info())
            return .completed
        }
        #expect(goOn.withLock { $0 } == true, "a withheld preview does not stop the job")
        #expect(loadedAfterPreview.withLock { $0 } == false, "no detector load for a preview that can never be shown")
        #expect(terminal == .safetyMissing(job: "small", sizeBytes: 466_000_000), "the final check fails closed")
        #expect(StreamHarness.files(dir).isEmpty, "no preview, no MP4, no poster")
        let paths = events.all.compactMap { e -> String?? in if case .jobProgress(_, _, _, let p) = e { p } else { nil } }
        #expect(paths.count == 1 && paths.allSatisfy { $0 == nil })
        #expect(await runner.gateCalls(.preview) == 1)
        #expect(await runner.gateCalls(.video) == 1)
    }
}
