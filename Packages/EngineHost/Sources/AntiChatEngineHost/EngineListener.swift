// Helper-side XPC entry (M1.T05 step 4; architecture §4.3, P-shell-10 Apple XPCListener), promoted from the
// M0.T04 spike Listener. Each app connection is one XPCSession served by a `SessionRouter`, which the listener
// creates with the still-inactive session (`accept { session in … }`), so no message can arrive before the
// router knows its session (CR-S-24). `EngineCore` holds what all sessions share: the scheduler (single load
// authority, D-013), the batch policy and the M0 media lanes.
import AntiChatEngineProtocol
import AntiChatEngines
import AntiChatFoundation
import Foundation
import os
import Synchronization
import XPC

public final class EngineListener: Sendable {
    public struct Paths: Sendable {
        public var llamaServer: String
        public var sdServer: String
        public var sdLog: String?
        public var sdModelDir: String
        public var kvDir: String
        public var llamaLog: String?
        public var selfExecutable: String
        /// `Contents/Helpers/llama-watchdog` (M1.T12 step 4); nil → the helper re-executes itself as the watchdog.
        public var watchdogTool: String?
        /// The orphan watchdog every child supervisor (llama-server, sd-server, video) spawns.
        public var watchdog: String { watchdogTool ?? selfExecutable }
        /// M0.T07: video child log (python driver / sd-cli stdout+stderr).
        public var videoLog: String?
        /// Per-process CocoaLumberjack log directory (AppLog).
        public var logDir: String?

        /// The per-build folder name under ~/Library/Logs and ~/Library/Caches (Release `AntiChat`, Debug `AntiChat-Dev`).
        public static var folderName: String {
            #if DEBUG || ANTICHAT_PERF_HARNESS
            "AntiChat-Dev"
            #else
            "AntiChat"
            #endif
        }

        /// `~/Library/Caches/<folderName>`.
        public static var cachesRoot: URL {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/\(folderName)")
        }

        /// M4.T15 `img-erase` (LaMa Core ML) compiled models: `<cachesRoot>/coreml-erase`. M9 review E6: it follows the
        /// build like every other helper cache (Release `~/Library/Caches/AntiChat`, which Uninstall and Remove everything
        /// list; Debug `AntiChat-Dev`, listed for Debug builds), never a hard-coded `AntiChat-Dev` (AT-NFR-D7 / AT-226).
        public static var eraserCacheDirectory: URL { cachesRoot.appendingPathComponent("coreml-erase", isDirectory: true) }

        /// Paths inside the installed bundle: `AntiChat.app/Contents/XPCServices/AntiChatEngine.xpc`.
        public static func fromBundle() -> Paths {
            let xpc = Bundle.main.bundleURL
            let contents = xpc.deletingLastPathComponent().deletingLastPathComponent()
            let tool = contents.appendingPathComponent("Helpers/llama-watchdog").path
            let home = FileManager.default.homeDirectoryForCurrentUser
            // The helper's logs and caches follow the build like the app's (DataPaths; review fix M8.T16: a
            // Release helper wrote the Debug `AntiChat-Dev` folders, which Uninstall did not list).
            let name = Self.folderName
            let logs = home.appendingPathComponent("Library/Logs/\(name)")
            try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            return Paths(
                llamaServer: contents.appendingPathComponent("Helpers/llama-server").path,
                sdServer: contents.appendingPathComponent("Helpers/sd-server").path,
                sdLog: logs.appendingPathComponent("sd-server.log").path,
                sdModelDir: home.appendingPathComponent("Library/Caches/\(name)/sd-empty-model-dir").path,
                kvDir: home.appendingPathComponent("Library/Caches/\(name)/kv").path,
                llamaLog: logs.appendingPathComponent("llama-server.log").path,
                selfExecutable: Bundle.main.executablePath ?? CommandLine.arguments[0],
                watchdogTool: FileManager.default.isExecutableFile(atPath: tool) ? tool : nil,
                videoLog: logs.appendingPathComponent("video.log").path,
                logDir: logs.appendingPathComponent("engine").path)
        }
    }

    /// The primary job's Mach service name (the standby job passes its own, M1.T12).
    public static let defaultServiceName = EngineProtocolVersion.serviceName

    let core: EngineCore
    let lifecycle: HelperLifecycle
    private let listener = Mutex<XPCListener?>(nil)

    public init(paths: Paths, idleExitSeconds: Double = 60) {
        if let d = paths.logDir { AppLog.bootstrap(process: "engine", directory: URL(fileURLWithPath: d)) }
        let core = EngineCore(paths: paths)
        self.core = core
        lifecycle = HelperLifecycle(idleSeconds: idleExitSeconds) {
            // M4.T04: never idle out while a media job runs or waits (its row would read `lost`).
            let busy = await core.mediaJobs.isBusy
            guard !busy else { return false }
            return await core.runtime.residentModels().isEmpty
        }
    }

    public func start(service: String = EngineProtocolVersion.serviceName) throws {
        let core = core, lifecycle = lifecycle
        let l = try XPCListener(service: service) { request in
            request.accept { session in
                SessionRouter(session: session, core: core, lifecycle: lifecycle)
            }
        }
        listener.withLock { $0 = l }
        Task { await lifecycle.start() }
    }
}

/// State shared by every session of this helper process.
final class EngineCore: Sendable {
    /// M2.T12: the single load authority; `runtime` owns the engines and is its loader.
    let scheduler: ModelScheduler
    let runtime: EngineRuntime
    /// M0.T05 voice spike: one session (resident voice set) per helper.
    let voice: SpikeVoiceSession
    /// M3.T01: the voice front door (dictation, files, sessions, read aloud; `VoiceRouting.swift`).
    let voiceService: VoiceService
    /// M5.T03: video jobs (the video runtime server, a supervised child over a unix socket).
    let videoEngine: VideoEngine
    let batch = Mutex(BatchPolicy.standard)
    /// M2.T14: the helper's memory-pressure response (OS source + job-time sample + Debug injection).
    let pressure: PressureMonitor
    /// M2.T15: hover hints (ModeSwitch → the other mode's chat slot; mic → the registered voice roles).
    let predictive: PredictiveWarmup
    /// M4.T04: the one heavy-job runner and the only path a generated image takes to disk or the app (via the gate).
    let mediaJobs: MediaJobRunner
    /// M4.T15: the loaded `img-erase` (LaMa Core ML), compiled into the helper's model cache.
    let erasers = EraserCache(cacheDirectory: EngineListener.Paths.eraserCacheDirectory)

    init(paths: EngineListener.Paths) {
        let jobs = MediaJobRunner(cacheDirectory: EngineListener.Paths.cachesRoot.appendingPathComponent("csc-coreml"))
        mediaJobs = jobs
        let runtime = EngineRuntime(
            llamaBinary: paths.llamaServer, kvDir: paths.kvDir, llamaLog: paths.llamaLog,
            watchdogExecutable: paths.watchdog, sdBinary: paths.sdServer, sdLog: paths.sdLog,
            sdModelDir: paths.sdModelDir)
        let scheduler = ModelScheduler(loader: runtime)
        self.runtime = runtime
        self.scheduler = scheduler
        let pressure = PressureMonitor(scheduler: scheduler, pauseJob: { await runtime.pauseActiveJob() },
                                       trimCaches: { await runtime.trimCaches() })
        self.pressure = pressure
        let predictive = PredictiveWarmup(scheduler: scheduler)
        self.predictive = predictive
        // M3.T03: dictation leases its models through the scheduler (Core ML built inside the load, NFR-V10).
        // M3.T04: Basic voice read aloud (AVSpeechSynthesizer) until the Voice pack verifies.
        let voiceModels = SchedulerVoiceModels(scheduler: scheduler, residency: runtime.voiceModels)
        VoiceTemp.sweep(VoiceTemp.transcribe)  // M3 review P2-6: decoded audio a crashed helper left in $TMPDIR
        // M3.T10: hands-free / push-to-talk conversations (VoiceSession), models through the same scheduler.
        voiceService = VoiceService(stt: STTService(provider: voiceModels), tts: TTSService.helper(provider: voiceModels),
                                    sessions: VoiceSessionService.helper(provider: voiceModels), predictive: predictive)
        Task {
            await runtime.attach(scheduler)
            await runtime.attach(pressure: pressure)
            // fix/soak-engine (NFR-R4/R1): a load on T0–T2 first drops a finished job's idle safety detectors.
            await runtime.setJobResidueRelease { await jobs.releaseDetectorsIfNoJobRuns() }
            await pressure.start()
        }
        let caches = EngineListener.Paths.cachesRoot
        videoEngine = VideoEngine(logFile: paths.videoLog, watchdogExecutable: paths.watchdog)
        voice = SpikeVoiceSession(scheduler: runtime, linkRoot: caches.appendingPathComponent("fluid-tts"))
        VoiceEnvironment.lockDown()
    }

    var capabilities: EngineCapabilities {
        EngineCapabilities(
            engines: [.mlx, .llama, .scripted], reasoning: true, toolCalls: true, vision: true, contextTokens: nil,
            grammar: true, batch: batch.withLock { $0 }, lanes: ["voice.spike", "voice.service", "image.sdserver", "video.runtime"])
    }

    typealias Emit = @Sendable (_ items: [StreamItem], _ tokens: Int) -> Void

    static func map(_ error: Error) -> AntiChatError {
        (error as? AntiChatError) ?? AntiChatError.engine("internal", "\(error)")
    }

    /// One chat turn: load if needed → adapter stream → DeltaBatcher → `emit`. Always ends with exactly one
    /// terminal event.
    func runChat(_ request: ChatRequest, emit: @escaping Emit) async {
        let received = ContinuousClock.now
        // tool_choice none = no tools reach any engine's template (OpenAI semantics). llama-server otherwise renders
        // them and, not parsing calls under `none`, streams the model's call syntax as text (M1.T13 conformance).
        var req = request
        if req.toolChoice == ToolChoice.none { req.tools = [] }
        let batcher = DeltaBatcher(policy: batch.withLock { $0 }, sink: emit)
        do {
            await runtime.attach(scheduler)
            let needsLoad = await scheduler.needsLoad(req.modelSlot)
            if needsLoad { await batcher.item(.lifecycle(.loadState(.loading))) }
            // M2.T12: the turn holds a scheduler lease for its whole stream (an active lease is never evicted).
            let lease = try await scheduler.ensureLoaded(role: .chat, model: req.modelSlot)
            defer { Task { await scheduler.release(lease) } }
            let lt = lease.loadTime
            // M2.T13 (NFR-R5): the scheduler loaded a lighter fallback; the turn runs on it and says so.
            if let used = lease.slot, used.key != req.modelSlot.key {
                await batcher.item(.lifecycle(.usingLighter(from: req.modelSlot.key, to: used.key)))
                req.modelSlot = used
            }
            if needsLoad { await batcher.item(.lifecycle(.loadState(.ready))) }
            try Task.checkCancellation()
            // M1.T13 step 3: raw tool syntax never reaches textDelta (RawToolSyntaxScrubber, all engines).
            let stream = ToolSyntaxFilterStream.wrap(
                try await runtime.generate(req, context: GenerationContext(receivedAt: received, loadTime: lt)),
                toolsOffered: !req.tools.isEmpty, nativeLazyGrammar: req.modelSlot.engine == .llama)
            var terminal = false
            // M1.T25 (R-234 "tok/s of the partial"): a cancelled turn whose engine sent no usage gets one counted
            // here (deltas = tokens, rate over first → last delta) right before its done(cancelled).
            var partial = PartialUsage(received: received)
            for await out in stream {
                switch out {
                case .event(let e):
                    partial.observe(e)
                    if case .done(.cancelled) = e, let u = partial.synthesized() { await batcher.item(.engine(.usage(u))) }
                    if e.isDelta { await batcher.delta(e) } else { await batcher.item(.engine(e)) }
                    terminal = e.isTerminal
                case .lifecycle(let l):
                    await batcher.item(.lifecycle(l))
                }
                if terminal { break }
            }
            if !terminal {
                if Task.isCancelled, let u = partial.synthesized() { await batcher.item(.engine(.usage(u))) }
                await batcher.item(.engine(Task.isCancelled ? .done(.cancelled) : .error(.engine("noTerminal", req.modelSlot.key))))
            }
        } catch is CancellationError {
            await batcher.item(.engine(.done(.cancelled)))
        } catch {
            await batcher.item(.engine(Task.isCancelled ? .done(.cancelled) : .error(Self.map(error))))
        }
    }

    func runWarmup(_ w: Warmup, emit: @escaping Emit) async {
        // M2.T15 (R-206 AC5): a hover hint is accepted at once and loads in the background (.utility, cancellable);
        // the reply is the acceptance, not the load.
        if w.predictive == true {
            await runtime.attach(scheduler)
            let pack = w.pack ?? "chat"
            await predictive.hint(pack: pack, mode: w.mode, slot: pack == "chat" ? w.modelSlot : nil)
            emit([.engine(.done(.stop))], 0)
            return
        }
        do {
            await runtime.attach(scheduler)
            let needsLoad = await scheduler.needsLoad(w.modelSlot)
            if needsLoad { emit([.lifecycle(.loadState(.loading))], 0) }
            let t = try await runtime.ensureLoaded(w.modelSlot)
            let usage = Usage(promptTokens: 0, completionTokens: 0, loadTime: t ?? 0, mtlAllocatedBytes: MemoryProbe.mtlAllocatedBytes)
            emit([.lifecycle(.loadState(.ready)), .engine(.usage(usage)), .engine(.done(.stop))], 0)
        } catch {
            emit([.engine(.error(Self.map(error)))], 0)
        }
    }

    /// M2.T16: embeddings / rerank scores under a scheduler lease (role embed / rerank, 2 min idle keep-alive).
    func runEmbed(_ r: EmbedRequest) async -> SearchReply {
        await runtime.attach(scheduler)
        do {
            let token = try await scheduler.ensureLoaded(role: .embed, model: r.modelSlot)
            defer { Task { await scheduler.release(token) } }
            return SearchReply(vectors: try await runtime.embeddings.embed(r.texts, kind: r.kind, key: token.key))
        } catch {
            return SearchReply(error: error as? AntiChatError ?? AntiChatError.engine("searchFailed", "\(error)"))
        }
    }

    func runRerank(_ r: RerankRequest) async -> SearchReply {
        await runtime.attach(scheduler)
        do {
            let token = try await scheduler.ensureLoaded(role: .rerank, model: r.modelSlot)
            defer { Task { await scheduler.release(token) } }
            // AT-250 c2 (A-M7-T03c): a `cite*` slot is the citation entailment model (query = claim, documents = sources).
            if CiteCheckService.handles(r.modelSlot) {
                return SearchReply(scores: try await runtime.citeCheck.score(
                    pairs: CiteCheckService.pairs(query: r.query, documents: r.documents), key: token.key))
            }
            return SearchReply(scores: try await runtime.embeddings.rerank(query: r.query, documents: r.documents, key: token.key))
        } catch {
            return SearchReply(error: error as? AntiChatError ?? AntiChatError.engine("searchFailed", "\(error)"))
        }
    }

    func runEvict(_ e: Evict, emit: @escaping Emit) async {
        await runtime.attach(scheduler)
        if let key = e.key { _ = await runtime.evict(key) } else { await runtime.evictAll() }
        emit([.lifecycle(.loadState(.evicted)), .engine(.done(.stop))], 0)
    }

    /// Install-time compile of the detectors (`ClientMessage.prepareSafety`). M4 review P2-4: on T0–T2 it runs in the
    /// scheduler's job slot after the media step-aside (the chat model does not stay resident beside the two detector
    /// loads); an already prepared set returns at once without a job.
    func prepareSafety(_ m: SafetyManifest) async -> MediaOutputGate.PrepareOutcome {
        if await mediaJobs.safetyPrepared(m) { return await mediaJobs.prepareSafety(m) }  // marker touch, no load
        await runtime.attach(scheduler)
        let jobs = mediaJobs
        guard await runtime.lowTier() else { return await jobs.prepareSafety(m) }
        do {
            return try await runtime.runMediaWork(key: "prepareSafety", bytes: EngineRuntime.detectorBytes, emit: { _ in }) { _ in
                await jobs.prepareSafety(m)
            }
        } catch {
            return .failed
        }
    }

    /// The M0 bench lane (`ClientMessage.image`): the same runner and gate as a queue job (no ungated output path).
    func runImage(_ req: ImageRequest, cancel: EngineRuntime.CancelFlag, emit: @escaping Emit) async {
        let submit = MediaJobSubmit(job: req.requestID.uuidString, kind: .image, image: req, safety: req.safety)
        await runMediaJob(submit, cancel: cancel, emit: emit)
    }

    /// M4.T04: one media job → `MediaJobRunner` (one at a time, sleep assertion, gate before any write) → engine.
    /// The stream carries `MediaEvent.job` events, the engine's own progress/scheduler notes, then one terminal.
    func runMediaJob(_ submit: MediaJobSubmit, cancel: EngineRuntime.CancelFlag, emit: @escaping Emit) async {
        // M5.T10: a queued video job runs the video lane under the queue's job id (same runner, same gate).
        if submit.kind == .video, var video = submit.video {
            video.safety = submit.safety
            video.previewDir = submit.previewDir
            await runVideo(video, job: submit.job, cancel: cancel, emit: emit)
            return
        }
        let failure = Mutex<AntiChatError?>(nil)
        let runtime = runtime, scheduler = scheduler
        if submit.kind == .local {
            // M4.T15: Remove background / Erase run here (Vision, Core ML LaMa); the result still goes through the gate.
            // M4 review P2-4: in the scheduler's job slot after the media step-aside (LaMa / Vision + the detectors of
            // the final check), so on T0–T2 the chat model is not resident beside them; LaMa leaves memory after the
            // job on T0–T2 (NFR-R4).
            let erasers = erasers
            let bytes = submit.image.model.footprintBytes + EngineRuntime.detectorBytes
            await mediaJobs.run(submit, isCancelled: { cancel.isCancelled }, emit: { ev in emit([.media(.job(ev))], 0) }) { outputs in
                await runtime.attach(scheduler)
                do {
                    return try await runtime.runMediaWork(key: "local", bytes: bytes, emit: { ev in emit([.media(ev)], 0) }) { lowTier in
                        do {
                            let end = try await LocalImageJob.run(submit.image, outputs: outputs, eraser: { await erasers.eraser($0) },
                                                                  isCancelled: { cancel.isCancelled })
                            if lowTier { await erasers.unloadAll() }
                            return end
                        } catch {
                            if lowTier { await erasers.unloadAll() }
                            throw error
                        }
                    }
                } catch {
                    failure.withLock { $0 = Self.map(error) }
                    throw error
                }
            }
            if let e = failure.withLock({ $0 }) { emit([.engine(.error(e))], 0) } else {
                emit([.engine(.done(cancel.isCancelled ? .cancelled : .stop))], 0)
            }
            return
        }
        await mediaJobs.run(submit, isCancelled: { cancel.isCancelled }, emit: { ev in emit([.media(.job(ev))], 0) }) { outputs in
            await runtime.attach(scheduler)
            do {
                try await runtime.runImage(submit.image, cancel: cancel, outputs: outputs) { ev in emit([.media(ev)], 0) }
            } catch {
                failure.withLock { $0 = Self.map(error) }
                throw error
            }
            return cancel.isCancelled ? .cancelled : .completed
        }
        if let e = failure.withLock({ $0 }) {
            emit([.engine(.error(e))], 0)
        } else {
            emit([.engine(.done(cancel.isCancelled ? .cancelled : .stop))], 0)
        }
    }

    /// M5.T03: one video job → the same `MediaJobRunner` as images (one heavy job at a time, sleep assertion, every
    /// preview and the final frames through the gate before anything is written or shown) → EngineRuntime → VideoEngine.
    /// The M0 bench (`-Bench video`) uses this path too, so no ungated video path exists.
    func runVideo(_ req: VideoRequest, job: MediaJobID? = nil, cancel: EngineRuntime.CancelFlag, emit: @escaping Emit) async {
        let failure = Mutex<AntiChatError?>(nil)
        let runtime = runtime, scheduler = scheduler, engine = videoEngine
        await mediaJobs.run(job: job ?? req.requestID.uuidString, safety: req.safety, previewDir: req.previewDir, outputPath: req.outputPath,
                            isCancelled: { cancel.isCancelled }, emit: { ev in emit([.media(.job(ev))], 0) }) { outputs in
            await runtime.attach(scheduler)
            do {
                return try await runtime.runVideo(req, cancel: cancel, engine: engine, outputs: outputs) { ev in emit([.media(ev)], 0) }
            } catch {
                failure.withLock { $0 = Self.map(error) }
                throw error
            }
        }
        if let e = failure.withLock({ $0 }) {
            emit([.engine(.error(e))], 0)
        } else {
            emit([.engine(.done(cancel.isCancelled ? .cancelled : .stop))], 0)
        }
    }

    func runVoice(_ req: VoiceRequest, emit: @escaping Emit) async {
        let report = await voice.run(req)
        emit([.media(.voiceReport(report)), .engine(.done(.stop))], 0)
    }
}

/// Usage of a cancelled turn when the adapter reported none (MLX stops before its `.info`; M1.T25).
struct PartialUsage {
    let received: ContinuousClock.Instant
    var tokens = 0
    var first: ContinuousClock.Instant?
    var last: ContinuousClock.Instant?
    var sawUsage = false

    init(received: ContinuousClock.Instant) { self.received = received }

    mutating func observe(_ e: EngineEvent, at now: ContinuousClock.Instant = .now) {
        switch e {
        case .textDelta, .reasoningDelta:
            tokens += 1
            if first == nil { first = now }
            last = now
        case .usage:
            sawUsage = true
        default:
            break
        }
    }

    func synthesized() -> Usage? {
        guard !sawUsage else { return nil }
        let gen = first.flatMap { f in last.map { Self.secs($0 - f) } } ?? 0
        let ttft = first.map { Self.secs($0 - received) * 1000 } ?? 0
        return Usage(
            promptTokens: 0, completionTokens: tokens, tokPerSec: gen > 0 ? Double(max(0, tokens - 1)) / gen : 0, ttftMs: ttft,
            generateTime: gen)
    }

    static func secs(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
}

/// M4.T15: one `LaMaEraser` per `img-erase` package path (loaded on the first Erase, kept for the next).
actor EraserCache {
    let cacheDirectory: URL
    private var byPath: [String: LaMaEraser] = [:]
    init(cacheDirectory: URL) { self.cacheDirectory = cacheDirectory }

    /// M4 review P2-4: drops the loaded LaMa (T0–T2 after every Erase; the next one loads it again from the compiled cache).
    func unloadAll() async {
        for e in byPath.values { await e.unload() }
        byPath = [:]
    }

    func eraser(_ path: String) -> LaMaEraser? {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        if let e = byPath[path] { return e }
        let e = LaMaEraser(modelPackage: URL(fileURLWithPath: path), cacheDirectory: cacheDirectory)
        byPath = [path: e]
        return e
    }
}
