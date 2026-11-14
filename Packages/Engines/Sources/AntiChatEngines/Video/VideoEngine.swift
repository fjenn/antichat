// M5.T03 step 2–3, 5 (R-040, R-041; P-media-11): one text-to-video job, helper side. The job already holds the
// scheduler's job slot (EngineRuntime.runVideo: StepAside made room — T2 unloads chat, T3+ co-resides when it fits B).
// Flow: start (or reuse warm) the runtime server → `POST /v1/video/jobs` → consume SSE:
//   progress → `.videoProgress` (stage + step, for the card) and, for denoise steps without a preview, `outputs.progress`;
//   preview  → steps `VideoPreviewPolicy` shows (A-M5-07: not the early, still-noisy ones, which stay progress only):
//              every frame of the step's animated set goes through `outputs.preview` = MediaJobRunner.emitPreview
//              (ChildSafetyCheck before it is written or announced; a withheld preview stops the job). fix/t05-video
//              (VID2, NFR-F7): the runtime is asked for previews at the gate's valid preview size and only for the
//              shown steps (`previewPlan`); a clip smaller than that size gets none (none could ever be shown);
//   decode   → (perf/t4-video, NFR-VID1) T3+ only (the detectors were preloaded beside the generator): the frames
//              decoded so far are pulled into memory and the final check starts on them (`outputs.beginVideoCheck`,
//              VideoCheckStream): the gate checks the sampled frames while the runtime decodes the rest. T0–T2 never
//              stream (R2 review P1-1, NFR-R1): the detectors load only after the runtime released the job;
//   frames_ready → the last frames are pulled → `outputs.finishVideo` (the verdict; allow ⇒ MP4 + poster, M5.T05;
//              withheld ⇒ nothing written). If streaming was not possible (an older runtime, a short pull) the frames
//              are pulled at once and go to `outputs.videoResult` (M5.T06: the same gate, then the same MP4).
// Nothing in this file writes a frame, preview or video.
// Cancel (NFR-VID3): `POST …/cancel`; if `end` has not arrived within `cancelWait` (500 ms) the process group gets
// SIGTERM → `killGrace` → SIGKILL (VideoRuntimeProcess.kill). The runtime frees its MLX memory with the job (or the
// process). A runtime crash mid-job fails the job with `video.runtimeCrashed` (the app's retry; a helper crash is
// `lost`, M4.T04 rule).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation

public actor VideoEngine {
    public typealias Emit = @Sendable (MediaEvent) async -> Void

    public struct Timing: Sendable {
        public var cancelWait: Duration = .milliseconds(500)
        // NFR-VID3 "cancel frees GPU memory ≤ 2 s": 500 ms soft cancel + ≤ 1 s SIGTERM grace, then SIGKILL (M5.md T03
        // failure mode: a DiT step is 2.7 s on S4, far more under load, so a step is never waited out).
        public var killGrace: Duration = .seconds(1)
        public init() {}
    }

    private var process: VideoRuntimeProcess?
    private let logFile: String?
    private let watchdogExecutable: String?
    public var timing = Timing()
    /// Set by EngineRuntime per job: T3+ keeps the server warm between jobs (architecture §4); T0–T2 stops it.
    private var keepWarmTask: Task<Void, Never>?
    private var runningJob: (id: String, client: VideoRuntimeClient)?

    /// The runtime server's pid for the helper's peak-footprint sampler (read off-actor).
    public nonisolated let pidHint = PIDHint()

    /// fix/t05-video: the shortest preview side the gate can show (`MediaOutputGate.previewMinSide`); tests of the
    /// preview plumbing on small scripted clips pass 0.
    let previewMinSide: Int

    public init(logFile: String? = nil, watchdogExecutable: String? = nil, previewMinSide: Int = MediaOutputGate.previewMinSide) {
        self.logFile = logFile
        self.watchdogExecutable = watchdogExecutable
        self.previewMinSide = previewMinSide
    }

    /// fix/t05-video (VID2, NFR-F7): which previews the runtime makes for a `width × height` clip. A preview whose short
    /// side is below the gate's valid size is never shown (`evaluatePreview` withholds it), so a clip smaller than
    /// that gets none (nil: no preview decode in the runtime, no preview reaches the gate; the card shows step
    /// progress, as it did when every such preview was withheld). Otherwise previews come at exactly that size (the
    /// runtime's 160 px default could never be shown) and only for the steps VideoPreviewPolicy shows (A-M5-07).
    /// Nothing about the checks changes: every preview made still goes through `outputs.preview` (the gate) before it
    /// is written or shown, and the final frames through the video check.
    struct PreviewPlan: Equatable, Sendable {
        var shortSide: Int
        var minFraction: Double
    }

    static func previewPlan(width: Int, height: Int, minSide: Int) -> PreviewPlan? {
        let short = min(width, height)
        guard short > 0, minSide < Int.max, short >= minSide else { return nil }
        return PreviewPlan(shortSide: min(short, max(minSide, 160)), minFraction: VideoPreviewPolicy.minDenoiseFraction)
    }

    public var serverPID: Int32 { get async { await process?.pid ?? 0 } }

    func server(for req: VideoRequest) async throws -> (VideoRuntimeProcess, Double) {
        let generator = req.generator ?? "wan22"
        if let p = process, p.config.runtimeDir == req.runtimeDir, p.config.generator == generator, await p.isRunning {
            return (p, 0)
        }
        if let p = process { await p.stop() }
        let p = VideoRuntimeProcess(config: .init(runtimeDir: req.runtimeDir, logFile: logFile, watchdogExecutable: watchdogExecutable,
                                                  generator: generator))
        process = p
        let s = try await p.start()
        return (p, s)
    }

    /// Runs one job to its end. Returns `.cancelled` when the cancel flag stopped it.
    public func run(_ req: VideoRequest, isCancelled: @escaping @Sendable () -> Bool, outputs: MediaJobOutputs,
                    emit: @escaping Emit, governor: VideoJobGovernor? = nil) async throws -> MediaJobRunner.EngineEnd {
        keepWarmTask?.cancel()
        keepWarmTask = nil
        let t0 = ContinuousClock.now
        func now() -> Double { VideoChild.secs(ContinuousClock.now - t0) }
        let (proc, startS) = try await server(for: req)
        let pid = await proc.pid
        pidHint.value = pid
        await emit(.videoProgress(VideoProgress(stage: "spawn", t: now(), childPID: pid)))
        let client = try await proc.client()
        let jobID = req.requestID.uuidString
        var job = VideoRuntimeClient.Job(jobID: jobID, modelDir: req.modelDir, taehvPath: req.taehv.isEmpty ? nil : req.taehv,
                                         prompt: req.prompt, width: req.width, height: req.height, numFrames: req.frames, fps: req.fps,
                                         seed: req.seed, memoryLimitBytes: req.memoryLimitBytes)
        if let plan = Self.previewPlan(width: req.width, height: req.height, minSide: previewMinSide) {
            job.previewShortSide = plan.shortSide
            job.previewMinFraction = plan.minFraction
        } else {
            job.preview = false  // fix/t05-video: no preview of this clip could ever be shown
        }
        if req.modelKind == "ltx" {  // M5.T07: LTX-2.3 (+ sound); 11 distilled steps, no previews
            job.modelKind = "ltx"
            job.gemmaDir = req.gemmaDir
            job.audio = req.audio == true
            job.preview = false
        }
        try await client.submit(job)
        runningJob = (jobID, client)
        defer { runningJob = nil }
        // M5.T11: heat / other-app pauses go to this job as `/pause` + `/resume` (cooperative, between steps).
        await governor?.attach(RuntimePauseTarget(pid: pid, engine: self))

        // Cancel watcher: cancel → POST cancel → 500 ms → kill the process group.
        let timing = self.timing
        let cancelled = CancelState()
        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                if isCancelled() {
                    cancelled.mark()
                    try? await client.cancel(jobID)
                    try? await Task.sleep(for: timing.cancelWait)
                    if !Task.isCancelled, let self { await self.escalate(grace: timing.killGrace, emit: emit, since: cancelled) }
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { watcher.cancel() }

        var metrics: [String: Double] = ["runtime_start_s": startS]
        var seen = EventOutcome()
        // perf/t4-video (NFR-VID1): the final check runs during the decode — frames are pulled as the runtime decodes
        // them and the gate checks the sampled ones meanwhile (`StreamedFrames`); its verdict is applied only after
        // `frames_ready` (finishVideo). Any pull failure drops the stream and the job uses the one-shot path below, and
        // so does every T0–T2 job (no detectors preloaded: `beginVideoCheck` is nil, R2 review P1-1).
        let streamed = StreamedFrames(client: client, jobID: jobID, outputs: outputs, width: req.width, height: req.height,
                                      fps: Double(req.fps))
        defer { streamed.abort() }
        do {
            seen = try await Self.consume(client.events(jobID), isCancelled: isCancelled, cancelled: cancelled, outputs: outputs,
                                          emit: emit, governor: governor, metrics: &metrics, pid: pid, now: now,
                                          stop: { try? await client.cancel(jobID) },
                                          decoded: { done, total in await streamed.decoded(done, of: total) })
        } catch {
            if cancelled.isMarked { seen.endStatus = "cancelled" } else if await !proc.isRunning {
                throw AntiChatError.engine("video.runtimeCrashed", "\(error)")
            } else {
                throw error
            }
        }
        if cancelled.isMarked || isCancelled() {
            try? await client.release(jobID)
            metrics["cancel_to_end_s"] = cancelled.secondsSinceMark
            await emit(.videoProgress(VideoProgress(stage: "cancelled", t: now(), childPID: pid)))
            return .cancelled
        }
        if seen.withheld {
            try? await client.release(jobID)
            return .completed  // the runner turns its withheld verdict into jobBlocked / safetyMissing
        }
        guard seen.endStatus == "completed", let r = seen.ready else {
            throw AntiChatError.engine("video.failed", seen.errorCode ?? seen.endStatus)
        }
        let info = Self.info(req, steps: req.modelKind == "ltx" ? 11 : 3)
        // M5.T07: the sound track rides along to the runner, which never checks it (D-006) and muxes it after allow.
        // R2 review P2-1: fetched before the streamed check is handed over (`complete`), so a failed fetch leaves the
        // stream with `streamed`, whose deferred `abort()` ends the open check (it blocks; nothing is written).
        let audio: Data?
        do { audio = req.audio == true ? try await fetchAudio(client, jobID) : nil } catch {
            try? await client.release(jobID)
            throw error
        }
        if let stream = await streamed.complete(count: r.count, width: r.width, height: r.height) {
            await emit(.scheduler(SchedulerNote(action: "videoStream", model: "video", detail: [
                "pulled_before_ready": "\(streamed.pulledBeforeReady)", "frames": "\(r.count)"])))
            try? await client.release(jobID)
            await emit(.videoProgress(VideoProgress(stage: "frames", step: r.count, totalSteps: r.count, t: now(), childPID: pid)))
            let t1 = now()
            _ = try await outputs.finishVideo(stream, audio: audio, info: info)
            await Self.noteFinal(emit: emit, outputs: outputs, streamed: true, afterFrames: now() - t1)
            await Self.noteRuntimeMetrics(emit: emit, seen.runtimeMetrics)
            return .completed
        }
        let frames = try await client.frames(jobID, count: r.count, width: r.width, height: r.height)
        // M5.T14 review P2: exactly the frames `frames_ready` announced (a short pull is an incomplete clip: fail).
        guard frames.count == r.count else {
            try? await client.release(jobID)
            throw AntiChatError.engine("video.badFrames", "got \(frames.count) of \(r.count) frames")
        }
        try? await client.release(jobID)  // the runtime's copy goes; the helper holds the only one, in memory
        await emit(.videoProgress(VideoProgress(stage: "frames", step: frames.count, totalSteps: r.count, t: now(), childPID: pid)))
        let t1 = now()
        _ = try await outputs.videoResult(frames: frames, width: r.width, height: r.height, fps: Double(r.fps), audio: audio,
                                          info: info)
        await Self.noteFinal(emit: emit, outputs: outputs, streamed: false, afterFrames: now() - t1)
        await Self.noteRuntimeMetrics(emit: emit, seen.runtimeMetrics)
        return .completed
    }

    /// fix/t05-video (AT-290): the runtime's own stage metrics of a completed job (its `end` event: `encode_s`,
    /// `denoise_s` (LTX: `generate_s`), `decode_s`, the stage peaks, …), as one scheduler note in the job's event
    /// stream — the channel `videoGate` / `videoFinal` already use. `-Bench video` turns it into the row's
    /// `h_child_<key>` columns, which tools/perf/video-speed.py splits the speed table by. Timing only.
    static func noteRuntimeMetrics(emit: Emit, _ m: [String: Double]) async {
        guard !m.isEmpty else { return }
        await emit(.scheduler(SchedulerNote(action: "videoRuntimeMetrics", model: "video", seconds: m["total_s"] ?? 0,
                                            detail: m.mapValues { String(format: "%.4f", $0) })))
    }

    private func fetchAudio(_ client: VideoRuntimeClient, _ jobID: String) async throws -> Data? {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if let audioFetch { return try await audioFetch(client, jobID) }
        #endif
        return try await client.audio(jobID)
    }

    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// Tests (R2 review P2-1): replaces the sound-track fetch, e.g. with one that fails after the frames are in.
    private var audioFetch: (@Sendable (VideoRuntimeClient, String) async throws -> Data?)?
    func setAudioFetch(_ f: (@Sendable (VideoRuntimeClient, String) async throws -> Data?)?) { audioFetch = f }
    #endif

    /// The final stage's timing for the job's metrics (bench `notes`): seconds from the frames being in to the MP4
    /// written (`after_frames_s`: the rest of the check + the encode), the check's own span and the detector load.
    static func noteFinal(emit: Emit, outputs: MediaJobOutputs, streamed: Bool, afterFrames: Double) async {
        let check = await outputs.firstCheckSeconds ?? -1, load = await outputs.detectorLoadSeconds ?? -1
        await emit(.scheduler(SchedulerNote(action: "videoFinal", model: "video", seconds: afterFrames, detail: [
            "streamed": streamed ? "1" : "0", "check_s": String(format: "%.3f", check),
            "detector_load_s": String(format: "%.3f", load)])))
        await outputs.noteGateTiming(emit: emit)  // M9.T05 F7_VIDEO: the gate's time for this job
    }

    /// perf/t4-video: one job's frames pulled while the runtime decodes them, fed to the streamed final check
    /// (`VideoCheckStream`). Pulls run on the event consumer (between events), so a pull never races the next one.
    /// Any failure (an older runtime that serves frames only after `frames_ready`, a short or odd-sized pull) aborts the
    /// stream; `complete` then returns nil and the job takes the one-shot `videoResult` path.
    final class StreamedFrames: @unchecked Sendable {
        let client: VideoRuntimeClient
        let jobID: String
        let outputs: MediaJobOutputs
        let width: Int, height: Int
        let fps: Double
        private var stream: VideoCheckStream?
        private var failed = false
        /// Frames already pulled (and their sampled ones handed to the check) when `frames_ready` came.
        private(set) var pulledBeforeReady = 0

        init(client: VideoRuntimeClient, jobID: String, outputs: MediaJobOutputs, width: Int, height: Int, fps: Double) {
            self.client = client
            self.jobID = jobID
            self.outputs = outputs
            self.width = width
            self.height = height
            self.fps = fps
        }

        /// A decode progress event: `done` of `total` frames are in the runtime's store.
        func decoded(_ done: Int, of total: Int) async {
            guard !failed, total > 0, done > 0 else { return }
            if stream == nil {
                guard let s = await outputs.beginVideoCheck(frameCount: total, width: width, height: height, fps: fps) else {
                    failed = true
                    return
                }
                stream = s
            }
            await pull(upTo: done)
        }

        private func pull(upTo done: Int) async {
            guard let s = stream, !failed else { return }
            let have = s.count
            guard done > have, done <= s.frameCount else { return }
            do {
                let got = try await client.frames(jobID, start: have, count: done - have, width: width, height: height)
                guard !got.isEmpty else { throw AntiChatError.engine("video.frames", "none of \(have)..<\(done)") }
                try s.append(got)
            } catch {
                fail()
            }
        }

        /// `frames_ready`: pulls what is left and returns the stream when it holds the whole clip at the expected
        /// size; nil (stream aborted) otherwise.
        func complete(count: Int, width w: Int, height h: Int) async -> VideoCheckStream? {
            guard let s = stream, !failed, count == s.frameCount, w == width, h == height else {
                fail()
                return nil
            }
            pulledBeforeReady = s.count
            await pull(upTo: count)
            guard !failed, s.count == count else {
                fail()
                return nil
            }
            stream = nil  // handed to finishVideo, which closes it
            return s
        }

        private func fail() {
            failed = true
            stream?.abort()
            stream = nil
        }

        /// The job ended any other way: the open check (if any) is aborted; nobody applies its outcome.
        func abort() { fail() }
    }

    /// What the event stream of one job told the engine.
    struct EventOutcome: Sendable {
        var withheld = false
        var ready: (count: Int, width: Int, height: Int, fps: Int)?
        var endStatus = "failed"
        var errorCode: String?
        /// The `end` event's metrics (the runtime's stage clock), as sent.
        var runtimeMetrics: [String: Double] = [:]
    }

    /// Consumes a job's server events (the run's loop; tests feed it SSE fixtures). Progress goes to the card and the
    /// runner; previews of the steps `VideoPreviewPolicy` shows go to the gate (`outputs.preview`), earlier ones are
    /// dropped unseen (A-M5-07); after a cancel or a withheld output nothing more reaches the runner. `stop` is called
    /// when the gate withheld an output.
    static func consume<S: AsyncSequence & Sendable>(
        isolation: isolated (any Actor)? = #isolation, _ events: S, isCancelled: @escaping @Sendable () -> Bool, cancelled: CancelState, outputs: MediaJobOutputs,
        emit: Emit, governor: VideoJobGovernor?, metrics: inout [String: Double], pid: Int32, now: () -> Double,
        stop: () async -> Void, decoded: (_ done: Int, _ total: Int) async -> Void = { _, _ in }
    ) async throws -> EventOutcome where S.Element == VideoRuntimeClient.Event {
        var o = EventOutcome()
        for try await ev in events {
            // After a cancel (or a withheld output) nothing more is handed to the runner: outputs that were in flight
            // when the cancel came are dropped unchecked and unseen; only the terminal events are read.
            if cancelled.isMarked || isCancelled() || o.withheld {
                if case .end(let status, _) = ev { o.endStatus = status }
                continue
            }
            switch ev {
            case .progress(let stage, let step, let total):
                await emit(.videoProgress(VideoProgress(stage: stage, step: step, totalSteps: total, t: now(), childPID: pid)))
                if stage == "denoise", step > 0 {
                    if !(await outputs.progress(step: step, totalSteps: total)) { o.withheld = true }
                    // M5.T11 step boundary: `.serious` sleeps 2 s here, a hold (hot / other app) waits here.
                    if !o.withheld { await governor?.checkpoint(step: step, total: total, isCancelled: isCancelled) }
                } else if stage != "denoise" {
                    await governor?.leftDenoise()
                    if stage == "decode" { await decoded(step, total) }
                }
            case .preview(let frame, _, _, _, let jpeg, let step, let total):
                // A-M5-07: an early, still-noisy step's preview is never shown (the step's progress already went
                // out), so it is dropped here unseen and unwritten instead of being checked.
                guard VideoPreviewPolicy.shows(step: step, of: total) else { continue }
                if metrics["first_preview_s"] == nil { metrics["first_preview_s"] = now() }
                if !(await outputs.preview(jpeg, step: step, totalSteps: total, frame: frame)) { o.withheld = true }
            case .framesReady(let count, let width, let height, let fps):
                o.ready = (count, width, height, fps)
            case .error(let code):
                o.errorCode = code
            case .end(let status, let m):
                o.endStatus = status
                o.runtimeMetrics = m
                for (k, v) in m { metrics["runtime_\(k)"] = v }
            }
            if o.withheld {
                // The gate withheld a preview: stop the job; nothing more is shown or written.
                await stop()
            }
        }
        return o
    }

    /// The R-287 details of a job's MP4 (model id = the model folder's catalog key, e.g. `vid-5b`).
    static func info(_ req: VideoRequest, steps: Int) -> MP4Encoder.Info {
        MP4Encoder.Info(prompt: req.prompt, model: URL(fileURLWithPath: req.modelDir.isEmpty ? req.diffusionModel : req.modelDir).lastPathComponent,
                        seed: req.seed, steps: steps, operation: req.mode == .i2v ? "animate" : "generate")
    }

    /// The cancel did not end the job in time: kill the runtime's process group (NFR-VID3).
    func escalate(grace: Duration, emit: Emit, since: CancelState) async {
        guard runningJob != nil, let p = process, await p.isRunning else { return }
        let s = await p.kill(grace: grace)
        process = nil
        await emit(.scheduler(SchedulerNote(action: "videoRuntimeKilled", model: "video-runtime", seconds: s,
                                            detail: ["after_cancel_s": String(format: "%.3f", since.secondsSinceMark)])))
    }

    /// After a job: T0–T2 stop the server now (NFR-R4); T3+ keep it warm for `keepWarm`.
    public func afterJob(keepWarm: Duration?) async {
        guard let p = process else { return }
        guard let keepWarm else {
            await p.stop()
            process = nil
            return
        }
        keepWarmTask?.cancel()
        keepWarmTask = Task { [weak self] in
            try? await Task.sleep(for: keepWarm)
            guard !Task.isCancelled else { return }
            await self?.stopIdle()
        }
    }

    func stopIdle() async {
        guard runningJob == nil, let p = process else { return }
        await p.stop()
        process = nil
    }

    /// Pause / resume the running job between steps (T2 chat policy, NFR-B3/B5).
    public func pause() async -> Bool {
        guard let j = runningJob else { return false }
        return (try? await j.client.pause(j.id)) != nil
    }

    public func resume() async -> Bool {
        guard let j = runningJob else { return false }
        return (try? await j.client.resume(j.id)) != nil
    }

    public func shutdown() async {
        keepWarmTask?.cancel()
        if let p = process { await p.stop() }
        process = nil
    }
}

public final class PIDHint: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Int32 = 0
    public var value: Int32 {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}

final class CancelState: @unchecked Sendable {
    private let lock = NSLock()
    private var at: ContinuousClock.Instant?
    func mark() { lock.withLock { if at == nil { at = .now } } }
    var isMarked: Bool { lock.withLock { at != nil } }
    var secondsSinceMark: Double { lock.withLock { at.map { VideoChild.secs(ContinuousClock.now - $0) } ?? 0 } }
}
