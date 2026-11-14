// M4.T04 (R-291, R-285 AC1/AC5, D-006; P-media-10): the helper side of the durable media job queue.
// One heavy GPU job at a time (the app's MediaJobQueue sends one, and the runner serialises anyway); the Mac is kept
// awake for the job's lifetime (`SleepAssertion`); every generated preview and result reaches disk or the app ONLY
// through `emitPreview` / `emitResult` / `emitVideoResult` (M5.T06) / `finishVideo` (perf/t4-video: the same video
// check, started during the decode on a VideoCheckStream and decided only once every frame is in) here, which ask `MediaOutputGate` first (R-241 audit rule 2: the gate's
// `check*` is called from this file and nowhere else). `allow` → the PNG is written (previews to the job's xfer dir,
// the result to `outputPath`) and announced; `block` → the bitmap is dropped in memory, nothing is written, the job's
// remaining work stops and the app gets `jobBlocked` (no reason); `safetyMissing` (detectors absent or damaged) →
// same, with the repair size. A blocked preview blocks the whole job: no further preview, no result; a preview the check
// cannot vouch for (below its valid size, or a timeout / detector error) is only not shown (M4 review P1-3/P2-7). The actor
// serialises a job's checks, so a slow preview check can never let a later result slip out first.
// The detectors load at the first check and are released `releaseAfter` (60 s) after the queue drains (NFR-R4).
// M4 lead decisions (NFR-R1, first-check latency): a job with live previews preloads the detectors at its start,
// overlapped with the generator (memory allows them side by side: T3+). A job without live previews (`preview:
// none`, T0–T2) starts with the detectors released, so they are never resident beside the generator; the engine
// unloads the generator before handing over the final image, and only then do the detectors load for its one check.
import AntiChatEngineProtocol
import AntiChatFoundation
import CoreGraphics
import Foundation
import ImageIO

public actor MediaJobRunner {
    /// Random per helper launch, reported in `HelloAck` and `jobStarted` (lost detection, R-291 AC2).
    public nonisolated let engineInstanceID: String
    private let gate: MediaOutputGate
    private let manifest: ManifestBox
    private let releaseAfter: Duration
    public nonisolated let sleep = SleepAssertion()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseTask: Task<Void, Never>?
    private var current: Current?
    private var preloadTask: Task<Double?, Never>?
    /// Bumped per job: a release timer of an earlier drain never drops the detectors under a newer job (review P2).
    private var generation = 0
    /// fix/soak-engine: jobs that released the detectors at their end (no preload), for the tests.
    private(set) var endOfJobReleases = 0
    /// M9 review E3: end-of-job releases skipped because a gate check was still in flight (for the tests and logs).
    private(set) var endOfJobReleasesSkipped = 0

    /// How the engine ended its work (the runner decides the job's terminal event from this and the gate's verdicts).
    public enum EngineEnd: Sendable { case completed, cancelled }

    /// Why the runner stopped a job's output.
    public enum Withheld: Sendable, Equatable {
        case blocked, safetyMissing(sizeBytes: Int64)
        /// `ImageResult.status` of the bench lane.
        public var status: String {
            switch self {
            case .blocked: "blocked"
            case .safetyMissing: "safetyMissing"
            }
        }
    }

    struct Current {
        var job: MediaJobID
        var previewDir: URL?
        var outputPath: URL
        var withheld: Withheld?
        var resultPath: String?
        var resultMetadata: [String: String] = [:]
        /// A result is being checked (M4 review: exactly once — a second `result` while one is in flight is refused).
        var resultInFlight = false
        /// Seconds the job's first gate check took (detector load included when they were not resident yet).
        var firstCheckSeconds: Double?
        /// The job's cancel flag (M5.T14 review P1-4: a cancel after the engine's `end` still ends the job cancelled).
        var isCancelled: @Sendable () -> Bool = { false }
        /// M9.T05 (NFR-F7 video leg, `F7_VIDEO`): what the gate cost this job, timing only (no verdict depends on it).
        var gate = GateTiming()
        /// M9 review E3: the detectors go when the job ends (the T0–T2 path: they load only for the final check). Set at
        /// the start from "no preload"; a late preload clears it unless it is a low tier's final-check-only preload.
        var releaseAtEnd = false
    }

    /// M9.T05 (NFR-F7 "video frame checks ≤ 10 % of generation time"): seconds the ChildSafetyCheck gate took for one
    /// job. Preview checks run inline (the step waits for them); the final check of a streamed clip overlaps the
    /// decode, so only its tail (every frame in → verdict) adds to the job; a one-shot final check adds all of it.
    public struct GateTiming: Sendable, Equatable {
        public var previewSeconds = 0.0
        public var previewChecks = 0
        /// fix/t05-video-t4 (VID2): previews the gate allowed and the runner announced (`jobProgress` with the preview,
        /// the card's path; nil path when the job has no preview folder). previewChecks − previewShown = withheld ones.
        public var previewShown = 0
        /// Final check: frames complete → verdict (streamed) or the whole check (one-shot).
        public var finalSeconds = 0.0
        /// Final check: its start → verdict (streamed: overlaps the decode; one-shot: = finalSeconds).
        public var finalWallSeconds = 0.0
        public var finalStreamed = false
        /// M9.T05 (D-006 evidence for timed media runs): final image checks this job made (exactly 1 for a checked
        /// image result, whatever the verdict; 0 = the output never reached the gate and was not written).
        public var resultChecks = 0
        /// The gate's time added to the job: previews + the final check's non-overlapped part.
        public var addedSeconds: Double { previewSeconds + finalSeconds }
    }

    final class ManifestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: SafetyManifest?
        var manifest: SafetyManifest? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    public init(engineInstanceID: String = UUID().uuidString, releaseAfter: Duration = .seconds(60), cacheDirectory: URL? = nil) {
        self.engineInstanceID = engineInstanceID
        self.releaseAfter = releaseAfter
        let box = ManifestBox()
        manifest = box
        gate = MediaOutputGate(manifestProvider: { box.manifest }, cacheDirectory: cacheDirectory)
    }

    /// True while a job runs or waits (the helper never idle-exits then; architecture §4).
    public var isBusy: Bool { busy || !waiters.isEmpty }
    public var detectorsLoaded: Bool { get async { await gate.isLoaded } }
    /// Install-time compile of the ChildSafetyCheck detectors (`ClientMessage.prepareSafety`; nothing is evaluated).
    public func prepareSafety(_ m: SafetyManifest) async -> MediaOutputGate.PrepareOutcome { await gate.prepare(m) }
    public func safetyPrepared(_ m: SafetyManifest) async -> Bool { await gate.isPrepared(m) }
    /// Gate checks made by this runner, per output kind (R241PathTraceTests).
    public func gateCalls(_ kind: MediaOutputKind) async -> Int { await gate.calls[kind, default: 0] }

    /// Runs one job: waits its turn, holds the sleep assertion, lets `engine` produce outputs through the handle,
    /// and emits exactly one terminal `MediaJobEvent` (returned too).
    @discardableResult
    public func run(_ submit: MediaJobSubmit, isCancelled: @escaping @Sendable () -> Bool = { false },
                    emit: @escaping @Sendable (MediaJobEvent) async -> Void,
                    engine: @escaping @Sendable (MediaJobOutputs) async throws -> EngineEnd) async -> MediaJobEvent {
        await run(job: submit.job, safety: submit.safety, previewDir: submit.previewDir, outputPath: submit.image.outputPath,
                  preloadDetectors: submit.image.preview != "none", isCancelled: isCancelled, emit: emit, engine: engine)
    }

    /// M5.T03: the same job lifecycle for a submit that is not an `ImageRequest` (a video job, `VideoRequest`).
    /// `preloadDetectors`: true = a job with live previews (detectors preloaded beside the generator); false = the
    /// detectors start released and load only for the final check (M4 lead decision (a); video until M5.T06 decides).
    @discardableResult
    public func run(job: MediaJobID, safety: SafetyManifest?, previewDir: String?, outputPath: String,
                    preloadDetectors: Bool = false, isCancelled: @escaping @Sendable () -> Bool = { false },
                    emit: @escaping @Sendable (MediaJobEvent) async -> Void,
                    engine: @escaping @Sendable (MediaJobOutputs) async throws -> EngineEnd) async -> MediaJobEvent {
        await acquire()
        // M4 review P2-1: a job cancelled while it waited for the runner ends at once (no step-aside, no engine start).
        if isCancelled() {
            let terminal = MediaJobEvent.jobCancelled(job: job)
            await emit(terminal)
            handOff()
            return terminal
        }
        generation += 1
        // A release timer that already fired finishes first, so it can never release under this job.
        releaseTask?.cancel()
        await releaseTask?.value
        releaseTask = nil
        sleep.hold()
        manifest.manifest = safety
        preloadTask?.cancel()
        if preloadDetectors {
            let gate = gate
            preloadTask = Task { await gate.preload() }
        } else {
            preloadTask = nil
            await gate.release()
        }
        let submit = (job: job, previewDir: previewDir)
        current = Current(job: job, previewDir: previewDir.map { URL(fileURLWithPath: $0) },
                          outputPath: URL(fileURLWithPath: outputPath), isCancelled: isCancelled,
                          releaseAtEnd: !preloadDetectors)
        await emit(.jobStarted(job: submit.job, engineInstanceID: engineInstanceID))
        let handle = MediaJobOutputs(runner: self, job: submit.job, emit: emit)
        let terminal: MediaJobEvent
        do {
            let end = try await engine(handle)
            terminal = terminalEvent(submit.job, end: end)
        } catch {
            let code = (error as? AntiChatError)?.code ?? "internal"
            terminal = current?.withheld != nil || isCancelled() ? terminalEvent(submit.job, end: .cancelled)
                : .jobFailed(job: submit.job, code: code)
        }
        let releaseAtEnd = current?.releaseAtEnd ?? !preloadDetectors
        current = nil
        // fix/soak-engine (NFR-R1 at the T1 cap, M9.T06 dry run): a job that started with the detectors released (no live
        // previews: the T0–T2 path) loaded them only for its final check, and the next such job releases them at its
        // start anyway, so keeping them `releaseAfter` longer buys nothing. Kept, they stayed resident (≈ 1.5 GB) beside
        // the chat model the app reloads right after the job: helper peak 10.3 GB against B = 9.5 GB. They go now,
        // before the terminal event, so that reload never starts beside them. A job that preloaded them (live
        // previews, or a T3+ video's late preload) keeps the 60 s window for the next job.
        // M9 review E3: decided by the job's own flag, not by `preloadTask == nil`: the T0–T2 image path preloads the
        // detectors right after the generator exits (`preloadDetectors(job:keepAfterJob: false)`), which set
        // `preloadTask` and so skipped this release on exactly the tiers it was written for. A preload still running
        // finishes first (else it could load them again after the release). Never while a gate check is in flight.
        if releaseAtEnd {
            if let p = preloadTask {
                p.cancel()
                _ = await p.value
                preloadTask = nil
            }
            if await gate.checksInFlight == 0 {
                await gate.release()
                endOfJobReleases += 1
            } else {
                endOfJobReleasesSkipped += 1
                AppLog.log(.media, .notice, "media runner: end-of-job detector release skipped (a check is in flight)")
            }
        }
        await emit(terminal)
        sleep.release()
        releaseLater()
        handOff()
        return terminal
    }

    /// perf/t4-video: the engine of a job that started with the detectors released (video) asks for them once it knows
    /// they fit beside its generator (T3+). Same preload as a previews job's start; a load already running is kept.
    /// M9 review E3: `keepAfterJob: false` = the T0–T2 final-check-only preload (the generator has already exited): the
    /// job still releases them at its end. `true` (T3+) keeps the 60 s window for the next job.
    func preloadDetectors(job: MediaJobID, keepAfterJob: Bool = true) {
        guard current?.job == job else { return }
        if keepAfterJob { current?.releaseAtEnd = false }
        guard preloadTask == nil else { return }
        let gate = gate
        preloadTask = Task { await gate.preload() }
    }

    /// Ends a job's turn: the runner passes straight to the next waiter (`busy` stays true, so a newcomer can never
    /// slip in between the resume and the waiter waking up: M4 review P2-1), else it is free.
    private func handOff() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    private func terminalEvent(_ job: MediaJobID, end: EngineEnd) -> MediaJobEvent {
        switch current?.withheld {
        case .blocked: return .jobBlocked(job: job)
        case .safetyMissing(let size): return .safetyMissing(job: job, sizeBytes: size)
        case nil: break
        }
        if let path = current?.resultPath { return .jobResult(job: job, path: path, metadata: current?.resultMetadata ?? [:]) }
        return end == .cancelled || current?.isCancelled() == true ? .jobCancelled(job: job) : .jobFailed(job: job, code: "noResult")
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }  // resumed by `handOff` with `busy` still true
    }

    /// NFR-R4: the detectors leave memory `releaseAfter` after the last job (a new job cancels the timer).
    private func releaseLater() {
        let wait = releaseAfter, gen = generation
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            await self.releaseIfIdle(since: gen)
        }
    }

    /// Releases the detectors only when no job started since `gen` and none runs or waits.
    private func releaseIfIdle(since gen: Int) async {
        guard generation == gen, !isBusy else { return }
        await gate.release()
    }

    /// fix/soak-engine (NFR-R4 job models, NFR-R1): a model load on T0–T2 first drops detectors left from an earlier job
    /// (a preview or local job's 60 s window), as the E.2.7 order evicts idle job models first; also inside a job once
    /// its outcome is settled (`restoreChat`'s in-job reload comes after the final check). Never while a job may still
    /// check an output. A later check reloads them (`loadChecker`). Returns whether anything was released.
    @discardableResult
    public func releaseDetectorsIfNoJobRuns() async -> Bool {
        if let c = current, c.resultInFlight || (c.resultPath == nil && c.withheld == nil) { return false }
        guard await gate.isLoaded, await gate.checksInFlight == 0 else { return false }
        await gate.release()
        return true
    }

    // MARK: - The only output path (R-241 rule 2)

    /// One live preview (PNG). Returns false when the job must stop (the gate withheld this or an earlier output).
    func emitPreview(_ png: Data, step: Int, totalSteps: Int, frame: Int? = nil, job: MediaJobID,
                     emit: @Sendable (MediaJobEvent) async -> Void) async -> Bool {
        guard let c = current, c.job == job, c.withheld == nil else { return false }
        // An undecodable preview cannot be checked, so it is neither written nor shown; the job goes on.
        guard let image = Self.decode(png) else {
            await emit(.jobProgress(job: job, step: step, totalSteps: totalSteps, previewPath: nil))
            return true
        }
        let t0 = ContinuousClock.now
        let outcome = await gate.checkPreview(image, job: job)
        if current?.job == job, current?.firstCheckSeconds == nil { current?.firstCheckSeconds = Self.secs(ContinuousClock.now - t0) }
        if current?.job == job {
            current?.gate.previewSeconds += Self.secs(ContinuousClock.now - t0)
            current?.gate.previewChecks += 1
        }
        switch outcome {
        case .allow: break
        case .withhold:
            // M4 review P1-3 / P2-7: this preview is not shown (not valid at its size, or the check could not finish);
            // nothing is written, the job goes on and its final output is checked on its own.
            guard current?.job == job, current?.withheld == nil else { return false }
            await emit(.jobProgress(job: job, step: step, totalSteps: totalSteps, previewPath: nil))
            return true
        case .block: _ = apply(.block, job: job); return false
        case .safetyMissing(let s): _ = apply(.safetyMissing(sizeBytes: s), job: job); return false
        }
        // Reentrancy (review P2): another output of this job may have been withheld while this check awaited.
        guard current?.job == job, current?.withheld == nil else { return false }
        // M4 review P1-2: a cancelled job writes nothing more (its session or turn is gone).
        guard !c.isCancelled() else { return false }
        var path: String?
        if let dir = c.previewDir {
            // M5.T03: a video step's animated preview set is several frames, each checked and written on its own.
            let name = frame.map { String(format: "preview-%04d-%02d.jpg", step, $0) } ?? String(format: "preview-%04d.png", step)
            let url = dir.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try png.write(to: url, options: .atomic)
                path = url.path
            } catch {
                AppLog.log(.engine, .error, "media job \(job): preview write failed: \(error)")
            }
        }
        if current?.job == job { current?.gate.previewShown += 1 }
        await emit(.jobProgress(job: job, step: step, totalSteps: totalSteps, previewPath: path))
        return true
    }

    /// A step without preview bytes (sd preview `none`): progress only, nothing to check or write.
    func emitProgress(step: Int, totalSteps: Int, job: MediaJobID, emit: @Sendable (MediaJobEvent) async -> Void) async -> Bool {
        guard let c = current, c.job == job, c.withheld == nil else { return false }
        await emit(.jobProgress(job: job, step: step, totalSteps: totalSteps, previewPath: nil))
        return true
    }

    /// The final output (PNG). Returns the written path, or nil when the gate withheld it (nothing written).
    func emitResult(_ png: Data, metadata: [String: String], job: MediaJobID) async -> String? {
        guard let c = current, c.job == job, c.withheld == nil, c.resultPath == nil, !c.resultInFlight else { return nil }
        guard let image = Self.decode(png) else { return nil }
        current?.resultInFlight = true
        let tCheck = ContinuousClock.now
        let outcome = await timedCheck { await gate.checkResult(image, job: job) }
        guard current?.job == job else { return nil }
        current?.resultInFlight = false
        let checkS = Self.secs(ContinuousClock.now - tCheck)  // M9.T05: the one-shot final check (timing only)
        current?.gate.resultChecks += 1
        current?.gate.finalSeconds = checkS
        current?.gate.finalWallSeconds = checkS
        guard apply(outcome, job: job) else { return nil }
        // Reentrancy (review P2): a preview withheld while this check awaited stops the job: nothing is written.
        guard current?.withheld == nil, current?.resultPath == nil else { return nil }
        // M4 review P1-2: a job cancelled while it was checked writes nothing (its session or turn is gone).
        guard !c.isCancelled() else { return nil }
        do {
            try FileManager.default.createDirectory(at: c.outputPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: c.outputPath, options: .atomic)
        } catch {
            AppLog.log(.engine, .error, "media job \(job): result write failed: \(error)")
            return nil
        }
        current?.resultPath = c.outputPath.path
        current?.resultMetadata = metadata
        return c.outputPath.path
    }

    /// Runs one gate check, recording the job's first-check latency (M4 lead decision (b): measured with and without
    /// the preload).
    private func timedCheck(_ check: () async -> GateOutcome) async -> GateOutcome {
        let t0 = ContinuousClock.now
        let outcome = await check()
        if current?.firstCheckSeconds == nil { current?.firstCheckSeconds = Self.secs(ContinuousClock.now - t0) }
        return outcome
    }

    static func secs(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

    func firstCheckSeconds(_ job: MediaJobID) -> Double? { current?.job == job ? current?.firstCheckSeconds : nil }

    /// M9.T05: the job's gate timing so far (nil = not this runner's current job).
    func gateTiming(_ job: MediaJobID) -> GateTiming? { current?.job == job ? current?.gate : nil }

    /// M5.T06 (R-285 video scope, NFR-F9, D-014): the final frames of a video job (RGBA8, `width × height × 4` each).
    /// The gate checks them first (`checkVideo`: every frame at ≥ 2 fps + the first + the last, sampled inside the
    /// check; an incomplete stream blocks). Only on `allow` does MP4Encoder write the MP4 (+ audio, never checked:
    /// D-006) and the poster frame next to it, and the job ends `jobResult`. On `block` / `safetyMissing` the frames
    /// and audio are dropped from memory, nothing is written, and the job ends `jobBlocked` / `safetyMissing` (the
    /// thrown `video.withheld` only unwinds the engine; the runner reports the verdict). Previews were checked one by
    /// one before display (`emitPreview`).
    func emitVideoResult(frames: [Data], width: Int, height: Int, fps: Double, audio: Data?, info: MP4Encoder.Info,
                         job: MediaJobID) async throws -> String {
        guard let c = current, c.job == job, c.withheld == nil, c.resultPath == nil else {
            throw AntiChatError.engine("video.withheld", "job \(job) already withheld or finished")
        }
        let frameBytes = width * height * 4
        guard width > 0, height > 0, !frames.isEmpty, fps.isFinite, fps > 0, frames.allSatisfy({ $0.count == frameBytes }) else {
            throw AntiChatError.engine("video.badFrames", "\(width)x\(height) n=\(frames.count) fps=\(fps)")
        }
        // M5.T14 review P1-4: a cancel that arrives after the engine's `end` (frames pull) stops here: nothing checked,
        // nothing written.
        try throwIfCancelled(c)
        // M5.T14 review P2: images only for the indices the check must see (it skips every other non-preview frame),
        // built one at a time as the check pulls them (no image of the whole clip in memory at once).
        let sampled = MediaOutputGate.sampleIndices(frameCount: frames.count, fps: fps)
        let stream = AsyncThrowingStream<MediaFrame, Error> { cont in
            let t = Task {
                for i in sampled {
                    if Task.isCancelled { cont.finish(throwing: CancellationError()); return }
                    guard let img = Self.cgImage(rgba: frames[i], width: width, height: height) else {
                        cont.finish(throwing: AntiChatError.engine("video.badFrames", "frame \(i)"))  // incomplete ⇒ block
                        return
                    }
                    cont.yield(MediaFrame(index: i, image: img, isPreview: false))
                }
                cont.finish()
            }
            cont.onTermination = { _ in t.cancel() }
        }
        let tCheck = ContinuousClock.now
        let outcome = await timedCheck { await gate.checkVideo(frames: stream, frameCount: frames.count, fps: fps, job: job) }
        if current?.job == job {
            // One value, written once (reading `current` inside its own write is an exclusivity violation).
            let checkS = Self.secs(ContinuousClock.now - tCheck)
            current?.gate.finalSeconds = checkS
            current?.gate.finalWallSeconds = checkS
            current?.gate.finalStreamed = false
        }
        return try await writeVideo(outcome, frames: frames, width: width, height: height, fps: fps, audio: audio, info: info, c: c,
                                    job: job)
    }

    /// perf/t4-video (NFR-VID1): opens the final check of a video job before its frames are all decoded (see
    /// `VideoCheckStream`). The check starts now and consumes the sampled frames as the engine appends them; its
    /// verdict is applied only by `finishVideo`. Nil when the job is not this runner's current one or is already
    /// withheld / finished (the engine then falls back to `emitVideoResult`).
    /// R2 review P1-1 (NFR-R1, M4 lead decision (a)): nil too when the job did not preload the detectors (T0–T2). The
    /// streamed check would load them (≈ 4.3 GB) during the decode, beside the runtime's peak memory; a low-tier job
    /// instead takes the one-shot path, whose check (and detector load) starts only after the runtime released the job.
    func beginVideoCheck(frameCount: Int, width: Int, height: Int, fps: Double, job: MediaJobID) -> VideoCheckStream? {
        guard let c = current, c.job == job, c.withheld == nil, c.resultPath == nil, !c.isCancelled(), frameCount > 0,
              width > 0, height > 0, fps.isFinite, fps > 0, preloadTask != nil else { return nil }
        let gate = gate
        return VideoCheckStream(job: job, frameCount: frameCount, width: width, height: height, fps: fps) { stream in
            Task { await gate.checkVideo(frames: stream, frameCount: frameCount, fps: fps, job: job) }
        }
    }

    /// perf/t4-video: closes a streamed check (every frame appended) and finishes the job exactly like
    /// `emitVideoResult`: the verdict, then — only on allow — the MP4 and the poster. An incomplete clip, a stream of
    /// another job, a withheld / finished / cancelled job: the check is aborted and nothing is written.
    func finishVideo(_ s: VideoCheckStream, audio: Data?, info: MP4Encoder.Info, job: MediaJobID) async throws -> String {
        guard let c = current, c.job == job, s.job == job, c.withheld == nil, c.resultPath == nil else {
            s.abort()
            throw AntiChatError.engine("video.withheld", "job \(job) already withheld or finished")
        }
        guard let frames = s.close() else {
            s.abort()
            throw AntiChatError.engine("video.badFrames", "got \(s.count) of \(s.frameCount) frames")
        }
        do { try throwIfCancelled(c) } catch {
            s.abort()
            throw error
        }
        let tFramesIn = ContinuousClock.now
        let outcome = await s.check.value
        if current?.job == job, current?.firstCheckSeconds == nil {
            current?.firstCheckSeconds = Self.secs(ContinuousClock.now - s.startedAt)
        }
        if current?.job == job {
            current?.gate.finalSeconds = Self.secs(ContinuousClock.now - tFramesIn)
            current?.gate.finalWallSeconds = Self.secs(ContinuousClock.now - s.startedAt)
            current?.gate.finalStreamed = true
        }
        // Reentrancy: the job may have ended or been withheld while the check finished.
        guard let now = current, now.job == job, now.withheld == nil, now.resultPath == nil else {
            throw AntiChatError.engine("video.withheld", "job \(job) ended during the check")
        }
        return try await writeVideo(outcome, frames: frames, width: s.width, height: s.height, fps: s.fps, audio: audio,
                                    info: info, c: now, job: job)
    }

    /// The verdict of a video check, then (allow only) the MP4 + poster; shared by both video result paths.
    private func writeVideo(_ outcome: GateOutcome, frames: [Data], width: Int, height: Int, fps: Double, audio: Data?,
                            info: MP4Encoder.Info, c: Current, job: MediaJobID) async throws -> String {
        guard apply(outcome, job: job) else { throw AntiChatError.engine("video.withheld", "gate") }
        try throwIfCancelled(c)  // cancelled during the check: the allowed clip is not encoded
        let poster = c.outputPath.deletingPathExtension().appendingPathExtension("poster.jpg")
        func removeWritten() {
            try? FileManager.default.removeItem(at: c.outputPath)
            try? FileManager.default.removeItem(at: poster)
        }
        do {
            try await MP4Encoder.encode(frames: frames, width: width, height: height, fps: fps, audio: audio, info: info, to: c.outputPath)
        } catch {
            removeWritten()
            throw error
        }
        var meta = ["width": "\(width)", "height": "\(height)", "fps": String(format: "%g", fps), "frames": "\(frames.count)",
                    "seed": "\(info.seed)", "model": info.model, "operation": info.operation]
        if let jpeg = PosterFrame.jpeg(rgba: frames[0], width: width, height: height), (try? jpeg.write(to: poster, options: .atomic)) != nil {
            meta["poster"] = poster.path
        }
        do { try throwIfCancelled(c) } catch {  // cancelled during the encode: what was written goes
            removeWritten()
            throw error
        }
        current?.resultPath = c.outputPath.path
        current?.resultMetadata = meta
        return c.outputPath.path
    }

    private func throwIfCancelled(_ c: Current) throws {
        if c.isCancelled() { throw AntiChatError.engine("cancelled", "job \(c.job) cancelled") }
    }

    static func cgImage(rgba: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Records a withholding verdict; true = allowed.
    private func apply(_ outcome: GateOutcome, job: MediaJobID) -> Bool {
        switch outcome {
        case .allow: return true
        case .block: current?.withheld = .blocked
        case .safetyMissing(let s): current?.withheld = .safetyMissing(sizeBytes: s)
        }
        return false
    }

    func withheld(_ job: MediaJobID) -> Withheld? { current?.job == job ? current?.withheld : nil }

    /// Seconds of the gate's last detector load (the job's metrics; nil = none yet).
    public var detectorLoadSeconds: Double? { get async { await gate.lastLoadSeconds } }

    /// The one image an output holds. A multi-image file (APNG, multi-page, …) is refused: only frame 0 would be
    /// checked while the file written could show the others (review P2).
    static func decode(_ png: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil), CGImageSourceGetCount(src) == 1 else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// The engine's handle on one job's outputs. Engines never write a generated image themselves: they hand the PNG
/// bytes here, and only what the gate allowed is written and announced.
public struct MediaJobOutputs: Sendable {
    let runner: MediaJobRunner
    public let job: MediaJobID
    /// The job's event sink (progress included), from `MediaJobRunner.run`.
    let emit: @Sendable (MediaJobEvent) async -> Void

    init(runner: MediaJobRunner, job: MediaJobID, emit: @escaping @Sendable (MediaJobEvent) async -> Void) {
        self.runner = runner
        self.job = job
        self.emit = emit
    }

    /// A step's preview; false ⇒ stop the job now (withheld).
    public func preview(_ png: Data, step: Int, totalSteps: Int) async -> Bool {
        await runner.emitPreview(png, step: step, totalSteps: totalSteps, job: job, emit: emit)
    }

    /// One frame of a step's animated preview set (video, M5.T03); false ⇒ stop the job now (withheld).
    public func preview(_ image: Data, step: Int, totalSteps: Int, frame: Int) async -> Bool {
        await runner.emitPreview(image, step: step, totalSteps: totalSteps, frame: frame, job: job, emit: emit)
    }

    /// The final video frames (RGBA8, `width × height × 4` each; audio = 48 kHz stereo interleaved Float32) → the
    /// runner: the gate, then the MP4 (M5.T06/T05). Returns the written MP4 path; throws when withheld (nothing written).
    public func videoResult(frames: [Data], width: Int, height: Int, fps: Double, audio: Data? = nil, info: MP4Encoder.Info) async throws -> String {
        try await runner.emitVideoResult(frames: frames, width: width, height: height, fps: fps, audio: audio, info: info, job: job)
    }

    /// perf/t4-video: opens the job's final video check while the frames are still being decoded (`VideoCheckStream`);
    /// nil ⇒ use `videoResult`. Close it with `finishVideo` (or `abort()` it when the job does not complete).
    public func beginVideoCheck(frameCount: Int, width: Int, height: Int, fps: Double) async -> VideoCheckStream? {
        await runner.beginVideoCheck(frameCount: frameCount, width: width, height: height, fps: fps, job: job)
    }

    /// perf/t4-video: every frame was appended → the verdict, then (allow only) the MP4. Throws when withheld or the
    /// clip is incomplete (nothing written).
    public func finishVideo(_ stream: VideoCheckStream, audio: Data? = nil, info: MP4Encoder.Info) async throws -> String {
        try await runner.finishVideo(stream, audio: audio, info: info, job: job)
    }

    /// perf/t4-video: loads the detectors now, beside the generator (T3+, where they fit with it), so the final check
    /// does not wait for them. Returns at once; the load runs in the background.
    /// M9 review E3: `keepAfterJob: false` on T0–T2 (loaded for the final check only, released when the job ends).
    public func preloadDetectors(keepAfterJob: Bool = true) async {
        await runner.preloadDetectors(job: job, keepAfterJob: keepAfterJob)
    }

    /// A step without a preview image; false ⇒ stop the job now.
    public func progress(step: Int, totalSteps: Int) async -> Bool {
        await runner.emitProgress(step: step, totalSteps: totalSteps, job: job, emit: emit)
    }

    /// The final PNG; the written path, or nil when withheld.
    public func result(_ png: Data, metadata: [String: String] = [:]) async -> String? {
        await runner.emitResult(png, metadata: metadata, job: job)
    }

    /// Seconds the job's first gate check took (nil = no check yet).
    public var firstCheckSeconds: Double? { get async { await runner.firstCheckSeconds(job) } }

    /// M9.T05 (`F7_VIDEO`): the ChildSafetyCheck gate's time for this job so far.
    public var gateTiming: MediaJobRunner.GateTiming? { get async { await runner.gateTiming(job) } }

    /// M9.T05 (`F7_VIDEO`): the job's gate time as a scheduler note (`videoGate`, seconds = the time the gate added to
    /// the job) in the job's event stream, after the final check. Timing only: nothing about the verdicts changes.
    public func noteGateTiming(emit: @Sendable (MediaEvent) async -> Void) async {
        guard let g = await gateTiming else { return }
        func f(_ x: Double) -> String { String(format: "%.4f", x) }
        await emit(.scheduler(SchedulerNote(action: "videoGate", model: "video", seconds: g.addedSeconds, detail: [
            "gate_s": f(g.addedSeconds), "preview_s": f(g.previewSeconds), "preview_checks": "\(g.previewChecks)",
            "preview_shown": "\(g.previewShown)",
            "final_s": f(g.finalSeconds), "final_wall_s": f(g.finalWallSeconds), "streamed": g.finalStreamed ? "1" : "0"])))
    }

    /// Seconds of the last detector load (the first check's warm-load cost, or the preload's).
    public var detectorLoadSeconds: Double? { get async { await runner.detectorLoadSeconds } }

    /// Why the job's output was withheld (nil = it was not).
    public var withheld: MediaJobRunner.Withheld? { get async { await runner.withheld(job) } }
}
