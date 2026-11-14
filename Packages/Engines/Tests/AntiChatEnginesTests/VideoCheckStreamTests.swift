// perf/t4-video (NFR-VID1; R-285, D-006, NFR-F9): the streamed final video check (`VideoCheckStream`,
// `MediaJobOutputs.beginVideoCheck` / `finishVideo`). Content-free gradients only (Q-012).
//  - without detectors the one check fails closed (`safetyMissing`) once the clip is closed; nothing is written;
//  - an incomplete clip, a wrong-size frame, a frame past the end, an aborted stream: no allow, nothing written;
//  - a cancel before the finish writes nothing;
//  - UI-testing build (forced verdicts): allow → the MP4 + poster after the one check; block → nothing.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization
import Testing
@testable import AntiChatEngines

enum StreamHarness {
    static let w = 64, h = 32

    static func frames(_ n: Int, from start: Int = 0) -> [Data] {
        (start..<start + n).map { i in Data(repeating: UInt8(truncatingIfNeeded: i * 7), count: w * h * 4) }
    }

    static func info() -> MP4Encoder.Info { MP4Encoder.Info(prompt: "a lighthouse", model: "vid-5b", seed: 1, steps: 3, operation: "generate") }

    /// One job whose engine streams `body`'s frames into the check and finishes it.
    static func run(_ dir: URL, runner: MediaJobRunner, isCancelled: @escaping @Sendable () -> Bool = { false },
                    body: @escaping @Sendable (MediaJobOutputs, VideoCheckStream) async throws -> Void) async -> MediaJobEvent {
        await runner.run(job: UUID().uuidString, safety: nil, previewDir: nil, outputPath: dir.appendingPathComponent("out/v.mp4").path,
                         preloadDetectors: true, isCancelled: isCancelled, emit: { _ in }) { outputs in
            guard let s = await outputs.beginVideoCheck(frameCount: 25, width: w, height: h, fps: 24) else {
                throw AntiChatError.engine("test", "no stream")
            }
            try await body(outputs, s)
            return .completed
        }
    }

    static func files(_ dir: URL) -> [String] {
        // Files only (an empty output folder holds nothing).
        ((FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String]) ?? []).filter { p in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: dir.appendingPathComponent(p).path, isDirectory: &isDir) && !isDir.boolValue
        }.sorted()
    }
}

@Suite(.serialized) struct VideoCheckStreamTests {
    @Test func withoutDetectorsTheStreamedCheckFailsClosedAndWritesNothing() async throws {
        let dir = RunnerHarness.temp("vstream")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let terminal = await StreamHarness.run(dir, runner: runner) { outputs, s in
            try s.append(StreamHarness.frames(10))
            try s.append(StreamHarness.frames(15, from: 10))
            _ = try await outputs.finishVideo(s, info: StreamHarness.info())
        }
        guard case .safetyMissing = terminal else { Issue.record("terminal \(terminal)"); return }
        #expect(await runner.gateCalls(.video) == 1)
        #expect(StreamHarness.files(dir).isEmpty)
    }

    @Test func incompleteClipIsNeverAllowed() async throws {
        let dir = RunnerHarness.temp("vstream-short")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let thrown = ThrownBox()
        let terminal = await StreamHarness.run(dir, runner: runner) { outputs, s in
            try s.append(StreamHarness.frames(24))
            do { _ = try await outputs.finishVideo(s, info: StreamHarness.info()) } catch {
                thrown.set(error)
                throw error
            }
        }
        #expect((thrown.error as? AntiChatError)?.code == "video.badFrames")
        if case .jobResult = terminal { Issue.record("an incomplete clip was allowed") }
        #expect(StreamHarness.files(dir).isEmpty)
    }

    @Test func wrongSizeOrExtraFramesEndTheStream() async throws {
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let dir = RunnerHarness.temp("vstream-bad")
        defer { try? FileManager.default.removeItem(at: dir) }
        let errors = ThrownBox()
        let terminal = await StreamHarness.run(dir, runner: runner) { outputs, s in
            #expect(throws: AntiChatError.self) { try s.append([Data(count: 10)]) }
            // After a bad frame the stream is closed: more frames are refused too.
            #expect(throws: AntiChatError.self) { try s.append(StreamHarness.frames(1)) }
            do { _ = try await outputs.finishVideo(s, info: StreamHarness.info()) } catch {
                errors.set(error)
                throw error
            }
        }
        #expect(errors.error != nil)
        if case .jobResult = terminal { Issue.record("allowed after a bad frame") }
        #expect(StreamHarness.files(dir).isEmpty)
        // A frame past the clip's end is refused as well.
        let dir2 = RunnerHarness.temp("vstream-extra")
        defer { try? FileManager.default.removeItem(at: dir2) }
        _ = await StreamHarness.run(dir2, runner: runner) { _, s in
            try s.append(StreamHarness.frames(25))
            #expect(throws: AntiChatError.self) { try s.append(StreamHarness.frames(1, from: 25)) }
            s.abort()
        }
        #expect(StreamHarness.files(dir2).isEmpty)
    }

    @Test func cancelBeforeTheFinishWritesNothing() async throws {
        let dir = RunnerHarness.temp("vstream-cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let cancel = EngineRuntime.CancelFlag()
        let terminal = await StreamHarness.run(dir, runner: runner, isCancelled: { cancel.isCancelled }) { outputs, s in
            try s.append(StreamHarness.frames(25))
            cancel.cancel()
            _ = try await outputs.finishVideo(s, info: StreamHarness.info())
        }
        if case .jobResult = terminal { Issue.record("written after a cancel") }
        #expect(StreamHarness.files(dir).isEmpty)
    }

    /// R2 review P1-1 (NFR-R1): only a job that preloaded the detectors (T3+) streams its check; a T0–T2 job (or a
    /// video job before EngineRuntime asked for the preload) gets nil and takes the one-shot path after the release.
    @Test func streamOnlyWhenTheDetectorsWerePreloaded() async throws {
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let dir = RunnerHarness.temp("vstream-tier")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (preload, late) in [(false, false), (true, false), (false, true)] {
            let opened = Mutex<Bool?>(nil)
            _ = await runner.run(job: UUID().uuidString, safety: nil, previewDir: nil, outputPath: dir.appendingPathComponent("v.mp4").path,
                                 preloadDetectors: preload, emit: { _ in }) { outputs in
                if late { await outputs.preloadDetectors() }  // EngineRuntime.runVideoLocked on T3+
                let s = await outputs.beginVideoCheck(frameCount: 25, width: StreamHarness.w, height: StreamHarness.h, fps: 24)
                opened.withLock { $0 = s != nil }
                s?.abort()
                return .cancelled
            }
            #expect(opened.withLock { $0 } == (preload || late), "preload \(preload) late \(late)")
        }
    }

    /// R2 review P2-1: a stream the engine drops without `close` / `abort` (it threw after taking it) still ends its
    /// check, and the check can only block — it never waits forever on the dropped stream.
    @Test(.timeLimit(.minutes(1))) func aDroppedStreamEndsItsCheckClosed() async throws {
        var s: VideoCheckStream? = VideoCheckStream(job: "j", frameCount: 25, width: StreamHarness.w, height: StreamHarness.h, fps: 24) { frames in
            Task {
                do { for try await f in frames { _ = f.index } } catch { return .block }
                return .allow
            }
        }
        try s?.append(StreamHarness.frames(10))
        let check = s!.check
        s = nil
        #expect(await check.value == .block)
    }

    @Test func noStreamForAJobThatIsNotCurrent() async throws {
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        #expect(await runner.beginVideoCheck(frameCount: 25, width: 64, height: 32, fps: 24, job: "nope") == nil)
    }
}

#if ANTICHAT_UI_TESTING
extension VideoCheckStreamTests {
    @Test func forcedAllowWritesTheMP4AfterTheOneCheck() async throws {
        let dir = RunnerHarness.temp("vstream-allow")
        defer { try? FileManager.default.removeItem(at: dir); ForcedVerdictCheck.current = nil }
        ForcedVerdictCheck.current = .allow
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let terminal = await StreamHarness.run(dir, runner: runner) { outputs, s in
            for i in stride(from: 0, to: 25, by: 5) { try s.append(StreamHarness.frames(5, from: i)) }
            _ = try await outputs.finishVideo(s, info: StreamHarness.info())
        }
        guard case .jobResult(_, let path, let meta) = terminal else { Issue.record("terminal \(terminal)"); return }
        #expect(FileManager.default.fileExists(atPath: path) && meta["frames"] == "25")
        #expect(await runner.gateCalls(.video) == 1)
    }

    @Test func forcedBlockWritesNothing() async throws {
        let dir = RunnerHarness.temp("vstream-block")
        defer { try? FileManager.default.removeItem(at: dir); ForcedVerdictCheck.current = nil }
        ForcedVerdictCheck.current = .block
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let terminal = await StreamHarness.run(dir, runner: runner) { outputs, s in
            try s.append(StreamHarness.frames(25))
            _ = try await outputs.finishVideo(s, info: StreamHarness.info())
        }
        guard case .jobBlocked = terminal else { Issue.record("terminal \(terminal)"); return }
        #expect(StreamHarness.files(dir).isEmpty)
    }
}
#endif

final class ThrownBox: @unchecked Sendable {
    private let lock = NSLock()
    private var e: Error?
    func set(_ e: Error) { lock.withLock { self.e = e } }
    var error: Error? { lock.withLock { e } }
}
