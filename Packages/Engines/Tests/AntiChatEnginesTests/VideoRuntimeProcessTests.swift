// M5.T03 task check (R-041, NFR-VID3 part; D-006): the video runtime server as a supervised child of the helper, and a
// whole job through MediaJobRunner → VideoEngine. Uses the runtime tree of `make runtime-video`
// (build/runtimes/video-runtime) with its `--generator scripted` (no model, no GPU); skipped when it is not built.
//  - launch + /health with the token; the socket dir is 0700; no TCP listener (lsof); stop removes everything; restart.
//  - a job without detectors: the first preview is withheld (`safetyMissing`), nothing is written, the job stops.
//  - cancel: the job ends `jobCancelled`, quickly, and the server survives (or is killed when it does not answer).
//  - ScriptedVideoEngine (no runtime): progress + the final frames reach the runner's video gate (M5.T06); with no
//    detectors installed the gate fails closed (`safetyMissing`) and nothing is written.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization
import Testing
@testable import AntiChatEngines

@Suite(.serialized) struct VideoRuntimeProcessTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let runtime = repo.appendingPathComponent("build/runtimes/video-runtime")
    static var built: Bool { FileManager.default.isExecutableFile(atPath: runtime.appendingPathComponent("bin/video-runtime-launcher").path) }

    /// The version of the built runtime tree (its RUNTIME.json) and the one catalog/runtimes.yaml ships. `make test-unit`
    /// runs against whatever tree the checkout last built; a tree older than the catalog lacks the behaviour the newer
    /// tests pin (fix/video-stream-flake: a 0.3.2 tree serves no frames while the job runs).
    static var builtVersion: String? {
        guard let d = try? Data(contentsOf: runtime.appendingPathComponent("RUNTIME.json")),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return o["version"] as? String
    }

    static var catalogVersion: String? {
        guard let text = try? String(contentsOf: repo.appendingPathComponent("catalog/runtimes.yaml"), encoding: .utf8),
              let start = text.range(of: "- name: video-runtime\n") else { return nil }
        for line in text[start.upperBound...].split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- name:") { break }
            if t.hasPrefix("version:") { return t.dropFirst("version:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
        }
        return nil
    }

    static func tcpListeners(_ pid: Int32) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-a", "-p", "\(pid)", "-i"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func request(_ prompt: String = "waves", frames: Int = 17, generator: String = "scripted", out: URL) -> VideoRequest {
        VideoRequest(mode: .t2v, prompt: prompt, width: 320, height: 192, frames: frames, fps: 16, seed: 1, runtimeDir: runtime.path,
                     modelDir: "/nonexistent", taehv: "", outputPath: out.appendingPathComponent("video.mp4").path,
                     scratchDir: out.path, footprintBytes: 0, previewDir: out.appendingPathComponent("xfer").path, generator: generator)
    }

    static func files(_ dir: URL) -> [String] {
        (FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String]) ?? []
    }

    @Test func launchesAnswersHealthOnASocketOnlyAndStopsClean() async throws {
        guard Self.built else { print("VideoRuntimeProcessTests: runtime not built, skipped"); return }
        let p = VideoRuntimeProcess(config: .init(runtimeDir: Self.runtime.path, generator: "scripted"))
        let s = try await p.start()
        #expect(s < 20)
        let pid = await p.pid
        let sock = await p.socketPath
        let dir = (sock as NSString).deletingLastPathComponent
        let mode = (try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(mode & 0o077 == 0, "socket dir is private")
        let h = try await p.client().health()
        #expect(h.ok && h.version == "0.2.0")
        // Wrong token → 401.
        let bad = VideoRuntimeClient(socketPath: sock, token: "0000000000000000")
        await #expect(throws: (any Error).self) { _ = try await bad.health() }
        #expect(Self.tcpListeners(pid).isEmpty)
        await p.stop()
        #expect(!(await p.isRunning))
        #expect(kill(pid, 0) != 0)
        #expect(!FileManager.default.fileExists(atPath: dir))
        // Restart works.
        try await p.start()
        #expect(await p.isRunning)
        await p.stop()
    }

    @Test func jobWithoutDetectorsWithholdsTheFirstPreviewAndWritesNothing() async throws {
        guard Self.built else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vrt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        // fix/t05-video: this 320×192 clip is below the gate's valid preview size, so the product asks for no previews;
        // min side 0 keeps the preview plumbing under test here (the gate still fails closed on the first one).
        let engine = VideoEngine(previewMinSide: 0)
        let req = Self.request(out: dir)
        let events = EventLog()
        let terminal = await runner.run(job: req.requestID.uuidString, safety: nil, previewDir: req.previewDir, outputPath: req.outputPath,
                                        emit: { events.append($0) }) { outputs in
            try await engine.run(req, isCancelled: { false }, outputs: outputs, emit: { _ in })
        }
        await engine.shutdown()
        guard case .safetyMissing = terminal else { Issue.record("terminal \(terminal)"); return }
        #expect(Self.files(dir).isEmpty, "nothing written: \(Self.files(dir))")
        #expect(await runner.gateCalls(.preview) == 1)
        #expect(await runner.gateCalls(.video) == 0)
    }

    /// fix/t05-video (VID2, NFR-F7): a clip below the gate's valid preview size gets no previews from the runtime (none
    /// could ever be shown); the final frames still go through the one video check, which fails closed without
    /// detectors; nothing is written; the runtime's stage metrics arrive as one `videoRuntimeMetrics` note only for a
    /// completed job (none here: the job was withheld).
    @Test func clipBelowThePreviewSizeMakesNoPreviewsAndTheFinalCheckStillRuns() async throws {
        guard Self.built else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vrt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let engine = VideoEngine()
        let req = Self.request(out: dir)
        #expect(min(req.width, req.height) < MediaOutputGate.previewMinSide)
        let events = EventLog()
        let notes = Mutex<[SchedulerNote]>([])
        let terminal = await runner.run(job: req.requestID.uuidString, safety: nil, previewDir: req.previewDir, outputPath: req.outputPath,
                                        emit: { events.append($0) }) { outputs in
            try await engine.run(req, isCancelled: { false }, outputs: outputs, emit: { ev in
                if case .scheduler(let n) = ev { notes.withLock { $0.append(n) } }
            })
        }
        await engine.shutdown()
        #expect(terminal == .safetyMissing(job: req.requestID.uuidString, sizeBytes: 0))
        #expect(await runner.gateCalls(.preview) == 0)
        #expect(await runner.gateCalls(.video) == 1, "the final frames are still checked")
        let progress = events.all.compactMap { e -> String?? in if case .jobProgress(_, _, _, let p) = e { p } else { nil } }
        #expect(!progress.isEmpty && progress.allSatisfy { $0 == nil }, "step progress only, never a preview path")
        #expect(Self.files(dir).isEmpty, "nothing written: \(Self.files(dir))")
        #expect(!notes.withLock { $0 }.contains { $0.action == "videoRuntimeMetrics" })
    }

    /// perf/t4-video: the final check starts during the decode — frames are pulled while the runtime still decodes
    /// (`videoStream` note: all were in before `frames_ready`), the one video check fails closed without detectors
    /// (`safetyMissing`), and nothing is written.
    /// fix/video-stream-flake: none of this depends on timing. Every decode progress event precedes `frames_ready` in
    /// the job's event log and the engine pulls on each one inline (StreamedFrames), so all 49 frames are in before
    /// `frames_ready` is read however late the consumer runs; `decode-delay` only spreads the decode so the pulls
    /// overlap it. The one failure mode is a runtime tree older than 0.3.3 (`/frames` answers 404 while the job runs):
    /// the pull then fails, the stream is aborted and the one-shot path checks the clip — D-006 still holds, but this
    /// test would race the runtime's job thread (pass when the pull lands after `completed`, fail when before). That
    /// tree is refused up front instead of flaking.
    @Test func finalFramesStreamIntoTheCheckDuringTheDecode() async throws {
        guard Self.built else { return }
        guard let built = Self.builtVersion, built == Self.catalogVersion else {
            Issue.record("""
                build/runtimes/video-runtime is \(Self.builtVersion ?? "unversioned"), the catalog ships \(Self.catalogVersion ?? "?"): \
                stale tree, run `make runtime-video` (before 0.3.3 no frames are served during the decode)
                """)
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vrt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let engine = VideoEngine()
        // No previews (each raises in the scripted generator); 49 frames decoded in 16-frame chunks, 0.3 s apart.
        let req = Self.request("waves preview-raise decode-delay=0.3", frames: 49, out: dir)
        let notes = Mutex<[SchedulerNote]>([])
        let terminal = await runner.run(job: req.requestID.uuidString, safety: nil, previewDir: req.previewDir, outputPath: req.outputPath,
                                        emit: { _ in }) { outputs in
            await outputs.preloadDetectors()  // T3+: EngineRuntime.runVideoLocked preloads before the engine runs
            return try await engine.run(req, isCancelled: { false }, outputs: outputs, emit: { ev in
                if case .scheduler(let n) = ev { notes.withLock { $0.append(n) } }
            })
        }
        await engine.shutdown()
        #expect(terminal == .safetyMissing(job: req.requestID.uuidString, sizeBytes: 0))
        #expect(await runner.gateCalls(.video) == 1)
        #expect(await runner.gateCalls(.preview) == 0)
        let stream = notes.withLock { $0 }.first { $0.action == "videoStream" }
        let pulled = Int(stream?.detail["pulled_before_ready"] ?? "") ?? 0
        #expect(pulled == 49, "frames pulled before frames_ready: \(String(describing: stream))")
        #expect(stream?.detail["frames"] == "49")
        #expect(Self.files(dir).isEmpty, "nothing written: \(Self.files(dir))")
    }

    /// R2 review P1-1 (NFR-R1, M4 lead decision (a)): a T0–T2 job (no detectors preloaded) never streams. The gate's
    /// video check (and with it the detector load) is not called during the decode nor before the runtime released the
    /// job (the `frames` stage comes after `release`); it runs once, on the one-shot path, and fails closed here.
    @Test func lowTierJobChecksTheClipOnlyAfterTheRuntimeReleasedIt() async throws {
        guard Self.built else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vrt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let engine = VideoEngine()
        let req = Self.request("waves preview-raise decode-delay=0.1", frames: 49, out: dir)
        let notes = Mutex<[SchedulerNote]>([])
        let callsAt = Mutex<[(stage: String, calls: Int)]>([])
        let terminal = await runner.run(job: req.requestID.uuidString, safety: nil, previewDir: req.previewDir, outputPath: req.outputPath,
                                        preloadDetectors: false, emit: { _ in }) { outputs in
            try await engine.run(req, isCancelled: { false }, outputs: outputs, emit: { ev in
                switch ev {
                case .scheduler(let n): notes.withLock { $0.append(n) }
                case .videoProgress(let p) where p.stage == "decode" || p.stage == "frames":
                    let n = await runner.gateCalls(.video)
                    callsAt.withLock { $0.append((p.stage, n)) }
                default: break
                }
            })
        }
        await engine.shutdown()
        #expect(terminal == .safetyMissing(job: req.requestID.uuidString, sizeBytes: 0))
        let seen = callsAt.withLock { $0 }
        #expect(seen.contains { $0.stage == "decode" } && seen.last?.stage == "frames", "stages: \(seen)")
        #expect(seen.allSatisfy { $0.calls == 0 }, "video check before the runtime released the job: \(seen)")
        #expect(await runner.gateCalls(.video) == 1)
        #expect(!notes.withLock { $0 }.contains { $0.action == "videoStream" })
        #expect(Self.files(dir).isEmpty, "nothing written: \(Self.files(dir))")
    }

    /// R2 review P2-1: the audio fetch fails after the streamed frames were all in (the runtime died or answered an
    /// HTTP error; here the fetch is replaced by one that throws). The open check is ended (not left waiting), the job
    /// fails, and nothing is written.
    @Test(.timeLimit(.minutes(1))) func audioFetchFailureAfterAStreamedClipEndsTheCheckAndWritesNothing() async throws {
        guard Self.built else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vrt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let engine = VideoEngine()
        var withAudio = Self.request("waves preview-raise", frames: 33, out: dir)
        withAudio.audio = true
        let req = withAudio
        await engine.setAudioFetch { _, _ in throw AntiChatError.engine("video.audio", "HTTP 500 0 B") }
        let notes = Mutex<[SchedulerNote]>([])
        let terminal = await runner.run(job: req.requestID.uuidString, safety: nil, previewDir: req.previewDir, outputPath: req.outputPath,
                                        emit: { _ in }) { outputs in
            await outputs.preloadDetectors()
            return try await engine.run(req, isCancelled: { false }, outputs: outputs, emit: { ev in
                if case .scheduler(let n) = ev { notes.withLock { $0.append(n) } }
            })
        }
        await engine.shutdown()
        guard case .jobFailed = terminal else { Issue.record("terminal \(terminal)"); return }
        #expect(await runner.gateCalls(.video) == 1, "the streamed check was opened")
        #expect(!notes.withLock { $0 }.contains { $0.action == "videoStream" })
        #expect(Self.files(dir).isEmpty, "nothing written: \(Self.files(dir))")
    }

    @Test func cancelEndsTheJobFastAndFreesTheRuntimeJob() async throws {
        guard Self.built else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vrt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let engine = VideoEngine()
        let req = Self.request("waves step-delay=30", out: dir)
        let cancel = EngineRuntime.CancelFlag()
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            cancel.cancel()
        }
        let terminal = await runner.run(job: req.requestID.uuidString, safety: nil, previewDir: req.previewDir, outputPath: req.outputPath,
                                        emit: { _ in }) { outputs in
            try await engine.run(req, isCancelled: { cancel.isCancelled }, outputs: outputs, emit: { _ in })
        }
        let after = cancel.at.map { VideoChild.secs(ContinuousClock.now - $0) } ?? 99
        #expect(terminal == .jobCancelled(job: req.requestID.uuidString))
        // Deterministic: the scripted step sleeps 30 s and cannot see the soft cancel, so the job can only end through the
        // escalation (soft cancel → SIGTERM → SIGKILL); ending far inside the step proves it was not waited out. The
        // NFR-VID3 2 s bar itself is measured on the real runtime by VideoCancelTests (gpu-run.sh timing).
        #expect(after < 15, "cancel → terminal \(after) s: the step was waited out")
        #expect(Self.files(dir).isEmpty)
        // The server is still usable for the next job (the cancel stopped the job, not the process) — or was killed.
        await engine.shutdown()
    }

    @Test func scriptedVideoEngineFinalFramesAreGatedAndNothingIsWrittenWithoutDetectors() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let script = ScriptedVideoScript(steps: 3, delayMs: 5, frames: 32, fps: 16, previewFrames: 0)
        let req = Self.request(out: dir).with(generator: script.generator)
        #expect(ScriptedVideoEngine.isScripted(req))
        let events = EventLog()
        let terminal = await runner.run(job: req.requestID.uuidString, safety: nil, previewDir: req.previewDir, outputPath: req.outputPath,
                                        emit: { events.append($0) }) { outputs in
            try await ScriptedVideoEngine.run(req, isCancelled: { false }, outputs: outputs, emit: { _ in })
        }
        #expect(terminal == .safetyMissing(job: req.requestID.uuidString, sizeBytes: 0))
        #expect(await runner.gateCalls(.video) == 1)
        let steps = events.all.compactMap { if case .jobProgress(_, let s, _, _) = $0 { return s } else { return nil } }
        #expect(steps == [1, 2, 3])
        #expect(Self.files(dir).isEmpty)
    }
}

extension VideoRequest {
    func with(generator g: String) -> VideoRequest {
        var r = self
        r.generator = g
        return r
    }
}
