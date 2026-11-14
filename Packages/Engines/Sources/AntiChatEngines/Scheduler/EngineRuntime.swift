// EngineRuntime (M2.T12 wiring; was the M0.T04/T06 SpikeScheduler). Owns the helper's engines — MLX, llama-server,
// ScriptedEngine, sd-server — and is the `ResidencyLoader` of the ModelScheduler, which is the single load authority
// (D-013): every chat load goes through `ModelScheduler.ensureLoaded`, every image / video job through
// `ModelScheduler.runJob` (same decision queue, `activeJob` set, room made by the E.2.7 order). What follows is the
// media job history, kept: the job bodies below still follow it, with eviction delegated to the scheduler.
//
// Fit-or-evict (P-shell-11). Ported from ollama/ollama@04088e7:server/sched.go — `processPending`
// (:268-408: loaded runner → use it; else load if it fits beside the loaded ones; else
// `findRunnerToUnload` (:1714-1743, idle runner first) → expire it → wait for the unload → retry) and
// `waitForVRAMRecovery` (:1485-1540, poll free memory until ~75% of the victim's size is back). Differences:
// one chat slot + one image slot instead of N runners; "fits" = catalog footprint arithmetic against B
// (never live free memory, which other apps share on unified memory); the recovery wait polls this
// process's `phys_footprint` until it is below `B − incoming footprint`, which is also the unload-time
// metric of NFR-M3.
// Chat ↔ image arbitration: design port of AtomicBot-ai/Atomic-Chat@29b01d8:web-app/src/lib/diffusion/arbiter.ts
// (`acquireGpuForDiffusion`: unload every chat session that does not coexist with the diffusion set, keep
// embeddings, evict voice last; `releaseGpuForChat`: unload the diffusion session only when the incoming chat
// model does not coexist; every decision serialised through one queue). M0 has no embedding/voice models
// in the helper, so only the chat rule applies.
// Vendored residency pieces (T14 closure, D-08): `ModelLease` (an evicted model must have no active
// generation lease), `MetalGate` (load and teardown are exclusive GPU producers) and the `ResidencyHost`
// hook that M1/M2's `ModelResidencyManager` wiring calls into.
import AntiChatEngineProtocol
import AntiChatFoundation
import CryptoKit
import Darwin
import Foundation
import OsaurusVendored

public actor EngineRuntime: ResidencyHost, ResidencyLoader {
    public let mlx = MLXAdapter()
    /// M2.T16: the search models (`embed*` / `rerank*` slots; loaded only through the scheduler, role embed/rerank).
    public let embeddings = EmbeddingService()
    /// AT-250 c2 (A-M7-T03c): the citation entailment model (Core ML, CPU + ANE; role `cite_check`).
    public let citeCheck = CiteCheckService()
    /// M3.T01: Core ML voice models (`EngineKind.coreml`); the voice backends read resident slots from here.
    public nonisolated let voiceModels = VoiceModelResidency()
    /// M6.T02: tokenizer-only counts (`CountTokens`; no weights load).
    public let tokenCounter = TokenCounter()
    /// M1.T05: JSONL replay engine (`ModelSlot.engine == .scripted`).
    public let scripted: ScriptedEngine
    public let llama: LlamaServerAdapter
    public let sd: SDServerSupervisor
    private var image: ImageModelSet?
    private let budget = Budget()
    /// M2.T13: KV prefix snapshots of chats whose model stepped aside (`<kvDir>/mlx`, never incognito).
    let snapshotDir: URL
    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// M2.T13: the scripted image engine (declared footprint as MTLBuffers; RL-006, the one copy).
    public let scriptedImage = ScriptedImageEngine()
    #endif
    /// The single load authority (set once by the host right after init).
    public private(set) weak var scheduler: ModelScheduler?

    /// `budgetBytes` must be readable synchronously (ResidencyHost); the actor mirrors it here.
    final class Budget: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        var bytes: UInt64 {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    public init(llamaBinary: String, kvDir: String, llamaLog: String?, watchdogExecutable: String?,
                sdBinary: String = "", sdLog: String? = nil, sdModelDir: String = NSTemporaryDirectory(),
                scripted: ScriptedEngine = ScriptedEngine()) {
        self.scripted = scripted
        snapshotDir = URL(fileURLWithPath: kvDir).appendingPathComponent("mlx")
        llama = LlamaServerAdapter(binary: llamaBinary, kvDir: kvDir, logFile: llamaLog, watchdogExecutable: watchdogExecutable)
        sd = SDServerSupervisor(config: .init(binary: sdBinary, logFile: sdLog, watchdogExecutable: watchdogExecutable, modelDir: sdModelDir))
    }

    public var budgetB: UInt64 { budget.bytes }
    public nonisolated var budgetBytes: UInt64 { budget.bytes }

    public func attach(_ s: ModelScheduler) { scheduler = s }

    var sched: ModelScheduler {
        get throws {
            guard let scheduler else { throw AntiChatError.engine("noScheduler", "EngineRuntime used before attach") }
            return scheduler
        }
    }

    public var imageKey: String? { image?.key }

    // MARK: - M2.T14: the running heavy job (pressure pause, thermal pacing)

    private var activeCancel: CancelFlag?
    private var activeEmit: Emit?
    private var activeKind: String?
    public private(set) var thermal: ThermalPolicy.State = .nominal
    /// Set once by the host: starts / stops its 2 s pressure sample around each job.
    public private(set) var pressureMonitor: PressureMonitor?

    public func attach(pressure: PressureMonitor) { pressureMonitor = pressure }

    /// M5.T11 (NFR-B3/B5): the running video job's heat / other-app pauses, and the GPU-share sampler feeding it.
    public let videoGovernor = VideoJobGovernor()
    public let gpuMonitor = GPUYieldMonitor()
    /// M9.T05 (NFR-B5): the pids of the connected clients (Hello.clientPID: the app, whose window draws the job card
    /// and its previews). The sampler never counts them as "another app".
    private var clientPIDs: Set<Int32> = []

    /// A client said hello with its pid (SessionRouter). Exited clients are dropped on the next registration.
    public func addClient(pid: Int32) {
        guard pid > 0 else { return }
        clientPIDs = clientPIDs.filter { kill($0, 0) == 0 || errno == EPERM }
        clientPIDs.insert(pid)
    }

    /// AntiChat's own pids for the GPU-yield sampler: the helper, the job's child and every connected client.
    func ownPIDs(child: Int32) -> Set<Int32> {
        var s = clientPIDs
        s.insert(getpid())
        if child > 0 { s.insert(child) }
        return s
    }

    /// [Resume] on a paused video card (`ClientMessage.mediaJobControl`).
    public func resumeVideo() async { await videoGovernor.userResume() }

    func beginJob(_ kind: String, cancel: CancelFlag, emit: @escaping Emit) async {
        activeCancel = cancel
        activeEmit = emit
        activeKind = kind
        await pressureMonitor?.jobStarted()
        // M5.T11: a video job is no longer cancelled at `.critical`; VideoJobGovernor pauses it (Resume keeps its work).
    }

    func endJob() async {
        activeCancel = nil
        activeEmit = nil
        activeKind = nil
        await pressureMonitor?.jobEnded()
    }

    /// CRITICAL pressure: the running image / video job stops with `sched.pausedLowMemory` [Resume]. False = none ran.
    public func pauseActiveJob() async -> Bool {
        guard activeCancel != nil else { return false }
        await pause(note: "pausedLowMemory", key: "sched.pausedLowMemory")
        return true
    }

    private func pause(note: String, key: String) async {
        guard let c = activeCancel, !c.isCancelled else { return }
        c.cancel()
        await activeEmit?(.scheduler(SchedulerNote(action: note, model: activeKind ?? "", detail: ["copyKey": key, "action": "resume"])))
    }

    /// NFR-B3: `.serious` paces heavy jobs (pause between steps) with `power.cooler`; `.critical` pauses video.
    public func setThermal(_ s: ThermalPolicy.State) async {
        let old = thermal
        thermal = s
        guard s != old else { return }
        if let key = ThermalPolicy.notice(s) {
            await activeEmit?(.scheduler(SchedulerNote(action: "thermal", model: s.rawValue, detail: ["copyKey": key])))
        }
        // M5.T11: the video job paces (serious) or pauses with [Resume] (critical) instead of being stopped.
        await videoGovernor.setThermal(s)
    }

    /// The adapter serving `kind`.
    public func adapter(_ kind: EngineKind) throws -> any EngineAdapter {
        switch kind {
        case .mlx: mlx
        case .llama: llama
        case .scripted: scripted
        // M3.T01: Core ML voice slots never reach a chat adapter (load/unload go to `voiceModels`).
        case .coreml: throw AntiChatError.engine("notAChatEngine", "coreml")
        }
    }

    // MARK: - ResidencyLoader (called by ModelScheduler only)

    public func load(_ slot: ModelSlot) async throws -> Double {
        if EmbeddingService.handles(slot) { return try await embeddings.load(slot) }
        if CiteCheckService.handles(slot) { return try await citeCheck.load(slot) }
        if VoiceModelResidency.handles(slot) { return try await voiceModels.load(slot) }
        if slot.engine == .scripted { return try await scripted.load(slot) }
        let t = try await adapter(slot.engine).load(slot)
        // M2.T13 step 2: a chat model back after a media job picks up its chats' KV prefixes (re-prefill otherwise).
        if slot.engine == .mlx { await mlx.restoreSnapshots(model: slot.key, from: snapshotDir) }
        return t
    }

    /// M2.T13 step 1: before the chat model steps aside, its open chats' KV prefixes go to disk (MLX prompt cache;
    /// llama-server saves its slot on session switch already, M1.T20). Incognito sessions are never written.
    public func snapshotKV(_ slot: ModelSlot) async {
        guard slot.engine == .mlx else { return }
        await mlx.snapshotSessions(model: slot.key, to: snapshotDir)
    }

    public func unload(_ slot: ModelSlot) async {
        if EmbeddingService.handles(slot) { return await embeddings.unload(slot.key) }
        if CiteCheckService.handles(slot) { return await citeCheck.unload(slot.key) }
        if VoiceModelResidency.handles(slot) { return voiceModels.unload(slot.key) }
        // M2.T15: MLX may hold a warm second variant; only the evicted container goes.
        if slot.engine == .mlx { await mlx.unload(key: slot.key) } else { await (try? adapter(slot.engine))?.unload() }
    }

    /// M2.T15 WarmVariant: the MLX container cap follows the scheduler's capacity (SetPolicy.warmSecondVariant).
    public func setCapacity(_ capacity: [EngineKind: Int]) async { await mlx.setMaxResident(capacity[.mlx] ?? 1) }

    /// llama-server: the child's phys_footprint; MLX / scripted: 0 (the catalog footprint is the floor).
    public func measuredBytes(_ slot: ModelSlot) async -> UInt64 {
        slot.engine == .llama ? Footprint.phys(await llama.serverPID) : 0
    }

    /// M1.T12: a llama-server that died (crash, OOM, kill -9) is no longer resident; in-process engines live as
    /// long as the helper, so only their loaded key matters.
    public func isAlive(_ slot: ModelSlot) async -> Bool {
        if EmbeddingService.handles(slot) { return await embeddings.holds(slot.key) }
        if CiteCheckService.handles(slot) { return await citeCheck.holds(slot.key) }
        if slot.engine == .mlx { return await mlx.holds(slot.key) }
        if VoiceModelResidency.handles(slot) { return voiceModels.holds(slot.key) }
        guard let key = await (try? adapter(slot.engine))?.loadedKey else { return false }
        guard key == slot.key else { return false }
        return slot.engine == .llama ? await llama.isAlive : true
    }

    /// Step 3: MLX memory limit = B (not relaxed), cache limit = B / 10.
    public func apply(budget bytes: UInt64) async {
        budget.bytes = bytes
        await mlx.setBudget(bytes)
    }

    /// fix/soak-engine: what `releaseJobResidue` drops besides MLX's pool (set by the host: the media runner's idle
    /// detectors). Returns whether it released anything.
    private var jobResidue: (@Sendable () async -> Bool)?
    public func setJobResidueRelease(_ release: @escaping @Sendable () async -> Bool) { jobResidue = release }

    /// ResidencyLoader (T0–T2, before every load): the idle safety detectors of a finished job (≈ 1.5 GB steady,
    /// 4.3 GB at a check; not a scheduler entry) and MLX's freed-buffer pool (indexing, an earlier prefill) leave the
    /// helper before the incoming model allocates. M9.T06 dry run: a chat reload right after an image job, beside both,
    /// peaked at 10.3 GB against B = 9.5 GB. The prefix-cache sessions stay (unlike `trimCache`).
    public func releaseJobResidue() async {
        if await jobResidue?() == true {
            AppLog.log(.engine, .info, "load on a low tier: idle safety detectors released first")
        }
        await mlx.clearBufferPool()
    }

    // MARK: - Chat (through the scheduler)

    /// Ensures `slot` is resident (a short lease, released at once). Returns the load time (nil if it was resident).
    public func ensureLoaded(_ slot: ModelSlot, role: ResidencyRole = .chat) async throws -> Double? {
        let s = try sched
        let t = try await s.ensureLoaded(role: role, model: slot)
        await s.release(t)
        return t.loadTime
    }

    public func needsLoad(_ slot: ModelSlot) async -> Bool { await scheduler?.needsLoad(slot) ?? true }

    public func evictAll() async {
        await scheduler?.evictAll()
        await mlx.trimCache()  // nothing resident: MLX's freed-buffer pool goes too (a lean helper after Evict all)
        _ = try? await scheduler?.runJob(key: "evict-image") { _ in
            await self.sd.stop()
            await self.clearImage()
        }
    }

    func clearImage() { image = nil }

    /// Chat generation holds a `ModelLease` for the whole stream so an eviction waits for it.
    public func generate(_ request: ChatRequest, context: GenerationContext) async throws -> AsyncStream<AdapterOutput> {
        let key = request.modelSlot.key
        // Lease first: an eviction between "generation started" and "lease taken" would unload a running model.
        await ModelLease.shared.acquire(key)
        let inner: AsyncStream<AdapterOutput>
        do {
            inner = try await adapter(request.modelSlot.engine).generate(request, context: context)
        } catch {
            await ModelLease.shared.release(key)
            throw error
        }
        return AsyncStream<AdapterOutput>(bufferingPolicy: .unbounded) { cont in
            let task = Task {
                for await x in inner { cont.yield(x) }
                await ModelLease.shared.release(key)
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - ResidencyHost (D-08 hook for the vendored residency/pressure code)

    /// M6.T03: pinned document prefixes in the MLX prefix cache (the probe; NFR-M4 release check).
    public func pinnedPrefixCount() async -> Int { await mlx.pinnedPrefixCount }

    public func residentModels() async -> [String] {
        (await scheduler?.residentKeys ?? []) + [image?.key].compactMap { $0 }
    }

    /// M8.T09 System report: resident bytes per scheduler entry (measured, else the catalog footprint) + the image set.
    public func residentBytes() async -> [String: UInt64] {
        var out: [String: UInt64] = [:]
        for e in await scheduler?.resident ?? [] { out[e.key] = e.bytes }
        if let image { out[image.key] = image.footprintBytes }
        return out
    }

    /// M8.T09 System report: the scheduler's last load times (ms).
    public func recentLoadTimesMs() async -> [Double] { await scheduler?.recentLoadTimesMs ?? [] }

    @discardableResult
    public func evict(_ modelName: String) async -> Bool {
        if await scheduler?.evict(modelName) == true { return true }
        guard image?.key == modelName else { return false }
        _ = try? await scheduler?.runJob(key: "evict-image") { _ in await self.sd.stop(); await self.clearImage() }
        return true
    }

    public func leaseCount(_ modelName: String) async -> Int { await ModelLease.shared.count(for: modelName) }

    public func trimCaches() async { await mlx.trimCache() }

    // MARK: - Image (M0.T06)

    /// Cooperative cancel flag for an image job (set by the listener on `Cancel`).
    public final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var set = false
        public var at: ContinuousClock.Instant?
        public init() {}
        public func cancel() { lock.withLock { if !set { set = true; at = .now } } }
        public var isCancelled: Bool { lock.withLock { set } }
    }

    public typealias Emit = @Sendable (MediaEvent) async -> Void

    /// One image job through the queue: fit-or-evict → sd-server load → generate with per-step progress →
    /// hand previews and the PNG to `outputs` (M4.T04: the MediaJobRunner's gate decides what is written; this
    /// code never writes a generated image) → restore the chat model when it had to go (NFR-M3).
    /// CR-S-26: upper bound of one image job (submit → final). (A cancel no longer waits for sd-server to report
    /// `cancelled`: the server is aborted at once, M9.T05.)
    static let imageJobTimeout = Duration.seconds(1800)

    public func runImage(_ req: ImageRequest, cancel: CancelFlag, outputs: MediaJobOutputs, emit: @escaping Emit) async throws {
        try await sched.runJob(key: req.model.key) { ctx in
            await self.beginJob("image", cancel: cancel, emit: emit)
            do {
                try await self.runImageLocked(req, ctx: ctx, cancel: cancel, outputs: outputs, emit: emit)
                await self.endJob()
            } catch {
                await self.endJob()
                throw error
            }
        }
    }

    func setImage(_ s: ImageModelSet?) { image = s }

    // MARK: - Media work outside the scheduler's entries (M4 review P2-4)

    /// The ChildSafetyCheck detectors' resident size for the step-aside maths: S-8's measured peak (4.3 GB during a
    /// check; 2.3 GB steady). They are not a scheduler entry, so a job that loads them reserves this much.
    public static let detectorBytes: UInt64 = 4_300_000_000

    /// The scheduler's tier rule (T0–T2: no job model stays resident, NFR-R4).
    public func lowTier() async -> Bool { await scheduler?.keepAlive.lowTier ?? false }

    /// M4 review P2-4: media work whose models the scheduler does not track (Erase's LaMa, Remove background's Vision,
    /// the detectors of its final check, the install-time detector compile) runs in the scheduler's job slot (so no
    /// load or other job runs beside it), after the media step-aside has made room for `bytes` — on T0–T2 the chat
    /// model steps aside as for an image job and reloads lazily at the next message. `body` gets the tier rule.
    public func runMediaWork<T: Sendable>(key: String, bytes: UInt64, emit: @escaping Emit,
                                          _ body: @escaping @Sendable (_ lowTier: Bool) async throws -> T) async throws -> T {
        try await sched.runJob(key: key) { ctx in
            var m: [String: Double] = [:]
            if let gone = await self.stepAsideForMedia(bytes: bytes, ctx: ctx, metrics: &m, emit: emit) {
                await emit(.scheduler(SchedulerNote(action: "chatReloadsLazily", model: gone.key, detail: ["reason": key])))
            }
            return try await body(await ctx.lowTier())
        }
    }

    /// The chat model resident now (the scheduler's newest chat entry).
    static func residentChat(_ ctx: ModelScheduler.JobContext) async -> ModelSlot? {
        await ctx.resident().filter { $0.role == .chat }.max { $0.lastUsed < $1.lastUsed }?.slot
    }

    func runImageLocked(_ req: ImageRequest, ctx: ModelScheduler.JobContext, cancel: CancelFlag, outputs: MediaJobOutputs,
                        emit: @escaping Emit) async throws {
        let tReq = ContinuousClock.now
        let b = budget.bytes
        let me = getpid()
        var m: [String: Double] = ["budget_b": Double(b), "image_footprint": Double(req.model.footprintBytes)]
        let sampler = PeakSampler()
        sampler.start { [sd] in
            let sdp = sd.pidUnsafe
            return Self.physFootprint(me) + (sdp > 0 ? Self.physFootprint(sdp) : 0)
        }
        defer { _ = sampler.stop() }

        // 1. acquireGpuForDiffusion (StepAside, M2.T13): the chat model (and what else must go, voice last) steps
        //    aside when it does not coexist with the image set; embeddings stay when they fit; T3+ co-resides.
        let evicted = await stepAsideForMedia(bytes: req.model.footprintBytes, ctx: ctx, metrics: &m, emit: emit)

        #if DEBUG || ANTICHAT_PERF_HARNESS
        if ScriptedImageEngine.isScripted(req.model) {
            image = req.model
            let pacing = thermal
            var r = try await scriptedImage.run(req, thermal: pacing, isCancelled: { cancel.isCancelled }, stop: { cancel.cancel() },
                                                outputs: outputs, emit: emit)
            image = nil
            r.metrics.merge(m) { a, _ in a }
            r.metrics["peak_helper_sd_bytes"] = Double(sampler.peak)
            r.metrics["first_check_s"] = await outputs.firstCheckSeconds ?? -1
            r.metrics["detector_load_s"] = await outputs.detectorLoadSeconds ?? -1
            await emit(.imageResult(r))
            // The scripted context is freed with the job (its buffers), whatever the tier.
            await emit(.scheduler(SchedulerNote(action: "imageUnloaded", model: req.model.key, detail: ["reason": "scripted"])))
            try await afterImageJob(req, evicted: evicted, ctx: ctx, peak: sampler.peak, emit: emit)
            return
        }
        #endif

        // 2. Image context (sd-server child). M9.T05 (AT-236 AC3): `image.loadStart` — the image model's load (or reuse)
        //    starts here; `image.final` = the job's final image below (metric `load_start_to_final_s`).
        let tLoadStart = ContinuousClock.now
        let genSignpost = Signposts.begin(.imageGen)
        let sdRunning = await sd.isRunning
        if image?.key != req.model.key || !sdRunning {
            image = nil
            let tl = try await sd.start(req.model)
            image = req.model
            m["image_load_s"] = tl
            await emit(.scheduler(SchedulerNote(
                action: "sdStarted", model: req.model.key, seconds: tl,
                detail: ["pid": "\(await sd.pid)", "socket": await sd.socketPath, "args": (await sd.lastArgs).joined(separator: " ")])))
        } else {
            m["image_load_s"] = 0
        }
        let sdPID = await sd.pid
        let client = await sd.client
        let sdIdle = Self.physFootprint(sdPID)
        m["sd_idle_footprint"] = Double(sdIdle)

        // 3. Generate with per-step progress. Without live previews (`preview: none`, T0–T2: lead decision, NFR-R1)
        //    sd-server still makes its cheap latent projection (`proj`, latent-sized) as the per-step signal, but the
        //    bytes are dropped here: never checked, written or shown — the job reports progress only.
        let livePreviews = req.preview != "none"
        let tSubmit = ContinuousClock.now
        let job = try await client.submit(
            prompt: req.prompt, width: req.width, height: req.height, steps: req.steps, seed: req.seed, cfg: req.cfgScale,
            sampleMethod: req.sampleMethod, preview: livePreviews ? req.preview : "proj", negativePrompt: req.negativePrompt,
            initImage: req.initImagePath.flatMap { FileManager.default.contents(atPath: $0) },
            maskImage: req.initImagePath == nil ? nil : req.maskImagePath.flatMap { FileManager.default.contents(atPath: $0) },
            refImages: (req.refImagePaths ?? []).compactMap { FileManager.default.contents(atPath: $0) }, strength: req.strength,
            loras: req.model.loras ?? [])
        var lastKey: (Int, Int)?
        var previews = 0
        var firstPreview: Double?
        var cancelSent = false
        var cancelStep = 0
        var maxStepSeen = 0
        var stepsAfterCancel = 0
        var final: SDServerClient.JobState?
        var aborted: (seconds: Double, at: ContinuousClock.Instant)?
        // CR-S-26: the poll has an overall deadline, and Task cancellation (the app's session went away) counts
        // as a cancel request.
        // M9.T05 (JOB_CANCEL_FREE, NFR-VID3 ≤ 2 s): a cancel no longer waits for sd.cpp's next step boundary (its only
        // cancel checkpoint; one step is ≈ 3.5 s at 1024² on S4, minutes on S1). The server is killed at once
        // (`abort`: SIGKILL to its group, reaped; the kernel frees weights + activations at exit) and the job ends
        // `cancelled`: its picture never left the server, so there is no partial output to gate, write or show.
        // The next job starts a fresh server (T0–T2 stop it after every job anyway, NFR-R4).
        let deadline = ContinuousClock.now + Self.imageJobTimeout
        while true {
            if Task.isCancelled { cancel.cancel() }
            if cancel.isCancelled, !cancelSent {
                cancelSent = true
                cancelStep = maxStepSeen
                let s = await sd.abort()
                aborted = (s, ContinuousClock.now)
                image = nil
                await emit(.scheduler(SchedulerNote(action: "imageUnloaded", model: req.model.key, seconds: s, detail: ["reason": "cancel"])))
                final = SDServerClient.JobState(status: "cancelled")
                break
            }
            if ContinuousClock.now > deadline {
                try? await client.cancel(job)
                throw mediaError("sdJobTimeout", "\(job)")
            }
            let st: SDServerClient.JobState
            do {
                st = try await client.job(job)
            } catch where cancel.isCancelled {
                continue  // a cancel raced this poll: the next pass aborts the server
            }
            if let s = st.previewStep, let p = st.previewPass, lastKey == nil || lastKey! != (p, s) {
                lastKey = (p, s)
                previews += 1
                maxStepSeen = max(maxStepSeen, s)
                if cancelSent { stepsAfterCancel = max(stepsAfterCancel, s - cancelStep) }
                let png = st.previewPNG ?? Data()
                if firstPreview == nil { firstPreview = Self.secs(ContinuousClock.now - tSubmit) }
                let total = st.previewTotal ?? req.steps
                // M4.T04: every preview passes the gate (one check per preview); a withheld one stops the job.
                let goOn = png.isEmpty || !livePreviews ? await outputs.progress(step: s, totalSteps: total)
                                                        : await outputs.preview(png, step: s, totalSteps: total)
                if !goOn { cancel.cancel() }
                await emit(.imageProgress(ImageProgress(
                    pass: p, step: s, totalSteps: total, previewBytes: livePreviews ? png.count : 0,
                    previewSHA256: String(Self.sha256(png).prefix(16)), sdServerPID: sdPID)))
            }
            if ["completed", "failed", "cancelled"].contains(st.status) { final = st; break }
            // A cancelled Task makes this sleep throw at once; the loop then turns it into a job cancel above.
            try? await Task.sleep(for: .milliseconds(15))
        }
        let tDone = ContinuousClock.now
        Signposts.end(.imageGen, genSignpost, meta: ["status": final?.status ?? "none"])
        m["load_start_to_final_s"] = Self.secs(tDone - tLoadStart)
        m["submit_to_final_s"] = Self.secs(tDone - tSubmit)
        m["request_to_final_s"] = Self.secs(tDone - tReq)
        m["first_preview_s"] = firstPreview ?? -1
        m["request_to_first_preview_s"] = firstPreview.map { $0 + Self.secs(tSubmit - tReq) } ?? -1
        m["previews"] = Double(previews)
        m["steps"] = Double(req.steps)
        if let a = final?.startedMS, let z = final?.completedMS { m["server_elapsed_s"] = Double(z - a) / 1000 }
        guard let final else { throw mediaError("sdNoResult") }
        if final.status == "failed" { throw mediaError("sdJobFailed", final.error) }

        var result = ImageResult(status: final.status, path: "", width: 0, height: 0, sha256: "", bytes: 0, metrics: [:])
        if final.status == "cancelled" {
            m["cancel_step"] = Double(cancelStep)
            m["steps_after_cancel"] = Double(stepsAfterCancel)
            let at = cancel.at ?? tDone
            m["cancel_to_stopped_s"] = Self.secs(tDone - at)
            if let aborted { m["cancel_abort_s"] = aborted.seconds }
            // NFR-VID3 (≤ 2 s), measured from the cancel request: the job's GPU memory is back when the server process
            // holds none of it — after `abort` it has exited and been reaped (the kernel frees its weights and Metal
            // buffers at exit). M9.T05 driver gap: this used to wait for the footprint to fall to `sdIdle`, the level
            // of a FRESH server before its lazily loaded weights; a cooperative cancel keeps the weights, so on T0–T2
            // (a fresh server per job) it never got there and recorded -1 on every run.
            var rec = -1.0
            while Self.secs(ContinuousClock.now - at) < 5 {
                if ProcessExit.exited(sdPID) || Self.physFootprint(sdPID) == 0 { rec = Self.secs(ContinuousClock.now - at); break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            m["cancel_mem_recover_s"] = rec
            m["sd_footprint_after_cancel"] = Double(Self.physFootprint(sdPID))
        } else if var png = final.imagePNG {
            // No live previews on a low tier: the generator leaves memory BEFORE the detectors load for the final
            // check (they were released at the job's start), so the two are never resident together (NFR-R1).
            // M9.T05 (IMAGE_TURN_OVERHEAD): the generator goes first and the detector load (verify-before-load
            // unchanged) starts right after it has exited, so it runs beside the composite and the PNG decode below
            // instead of after them. The picture is already in memory here (`png`); nothing is checked before the gate.
            if !livePreviews, await ctx.lowTier(), await sd.isRunning {
                let su = await sd.stop()
                image = nil
                await emit(.scheduler(SchedulerNote(action: "imageUnloaded", model: req.model.key, seconds: su, detail: ["reason": "beforeCheck"])))
                m["sd_stop_before_check_s"] = su
                // M9 review E3: final-check-only preload; the runner still releases the detectors at the job's end.
                await outputs.preloadDetectors(keepAfterJob: false)
            }
            // M4.T15 step 3 (R-034 AC4): a mask edit (inpaint) keeps every pixel outside the 8-px-dilated mask from the
            // source (MaskCompositor) — composited BEFORE the gate, so the checked picture is the written one.
            // The composite's source: the init image (inpaint / masked img2img) or the reference picture (a masked
            // img-edit edit, whose mask sd-server never sees).
            if let m = req.maskImagePath, let s = req.initImagePath ?? req.refImagePaths?.first,
               let maskData = FileManager.default.contents(atPath: m),
               let srcData = FileManager.default.contents(atPath: s),
               let composited = MaskCompositor.compositePNG(source: srcData, engine: png, mask: maskData) {
                png = composited
            }
            let (w, h) = Self.pngSize(png)
            let tc = ContinuousClock.now
            if let path = await outputs.result(png, metadata: ["width": "\(w)", "height": "\(h)", "seed": "\(req.seed)"]) {
                result = ImageResult(status: "completed", path: path, width: w, height: h, sha256: Self.sha256(png), bytes: png.count, metrics: [:])
            }
            m["result_check_s"] = Self.secs(ContinuousClock.now - tc)
            m["detector_load_s"] = await outputs.detectorLoadSeconds ?? -1
            m["live_previews"] = livePreviews ? 1 : 0
            m["first_check_s"] = await outputs.firstCheckSeconds ?? -1
            if let g = await outputs.gateTiming {  // M9.T05 (D-006 evidence): the real gate ran on this job's output
                m["gate_result_checks"] = Double(g.resultChecks)
                m["gate_preview_checks"] = Double(g.previewChecks)
                m["gate_s"] = g.addedSeconds
            }
        }
        if let w = await outputs.withheld { result = ImageResult(status: w.status, path: "", width: 0, height: 0, sha256: "", bytes: 0, metrics: [:]) }
        m["peak_helper_sd_bytes"] = Double(sampler.peak)
        result.metrics = m
        await emit(.imageResult(result))

        try await afterImageJob(req, evicted: evicted, ctx: ctx, peak: sampler.peak, emit: emit)
    }

    /// Step-aside for one media job; returns the chat model that went (nil = it co-resides or none was resident).
    func stepAsideForMedia(bytes: UInt64, ctx: ModelScheduler.JobContext, metrics m: inout [String: Double], emit: Emit) async -> ModelSlot? {
        let b = budget.bytes
        let me = getpid()
        guard let r = await Self.residentChat(ctx) else {
            // fix/soak-engine: no chat model to step aside, but MLX's freed-buffer pool (e.g. a project index's embedding
            // work, M9.T06 soak setup) still goes before the job allocates, as in the branches below.
            await mlx.clearBufferPool()
            return nil
        }
        let containerBefore = await mlx.containerID
        let footprintBefore = Self.physFootprint(me)
        let tEv = ContinuousClock.now
        let gone = await ctx.stepAside(bytes: bytes, enabled: FeatureFlag.mediaStepAside.isEnabled())
        let call = Self.secs(ContinuousClock.now - tEv)
        guard !gone.isEmpty else {
            // Co-resident: keep the weights, drop MLX's freed-buffer pool (up to B/10) before the job allocates.
            await mlx.trimCache()
            m["chat_kept"] = 1
            m["helper_footprint_after_trim"] = Double(Self.physFootprint(me))
            await emit(.scheduler(SchedulerNote(action: "kept", model: r.key, detail: ["budget": "\(b)", "container": containerBefore])))
            return nil
        }
        // The job needs the memory now: MLX's freed-buffer pool (up to B/10, filled by any earlier MLX work in this
        // helper, not only by the model that went) goes too, as in the co-resident branch. Without this, memory
        // unrelated to the evicted model kept the footprint above the target and the unload was never observed (-1).
        await mlx.trimCache()
        // waitForVRAMRecovery: footprint of this process below B − incoming set (the NFR-M3 unload time, measured from
        // the step-aside call). The 10 s window starts when the call returns and is sampled at least once, so a slow
        // call (lease wait, a loaded host) is still measured instead of skipping the loop.
        let target = b > bytes ? b - bytes : 0
        var dropped = -1.0
        let tCall = ContinuousClock.now
        repeat {
            if Self.physFootprint(me) <= target { dropped = Self.secs(ContinuousClock.now - tEv); break }
            try? await Task.sleep(for: .milliseconds(5))
        } while Self.secs(ContinuousClock.now - tCall) < 10
        m["unload_call_s"] = call
        m["unload_s"] = dropped
        m["helper_footprint_after_unload"] = Double(Self.physFootprint(me))
        await emit(.scheduler(SchedulerNote(
            action: "evicted", model: gone.map(\.key).joined(separator: ","), seconds: dropped,
            detail: ["budget": "\(b)", "target": "\(target)", "call_s": String(format: "%.4f", call),
                     "footprint_before": "\(footprintBefore)", "footprint_after": "\(Self.physFootprint(me))"])))
        return gone.contains { $0.key == r.key } ? r : nil
    }

    /// 4. releaseGpuForChat. NFR-R4: on T0–T2 the image context goes after every job. The chat model that stepped
    /// aside reloads lazily at the next user message (R-236; `status.loadingModel`), unless the request names a
    /// `restoreChat` (the NFR-M3 bench), which reloads now.
    func afterImageJob(_ req: ImageRequest, evicted: ModelSlot?, ctx: ModelScheduler.JobContext, peak: UInt64, emit: Emit) async throws {
        let b = budget.bytes
        let sdUp = await sd.isRunning
        if await ctx.lowTier(), image != nil || sdUp {
            let su = await sd.stop()
            image = nil
            await emit(.scheduler(SchedulerNote(action: "imageUnloaded", model: req.model.key, seconds: su, detail: ["reason": "NFR-R4"])))
        }
        guard let back = req.restoreChat, evicted != nil else {
            if let still = await Self.residentChat(ctx) {
                await emit(.scheduler(SchedulerNote(
                    action: "chatStillResident", model: still.key, detail: ["container": await mlx.containerID, "peak_bytes": "\(peak)"])))
            } else if let evicted {
                await emit(.scheduler(SchedulerNote(action: "chatReloadsLazily", model: evicted.key, detail: ["peak_bytes": "\(peak)"])))
            }
            return
        }
        let sdStill = await sd.isRunning
        if b > 0, req.model.footprintBytes + back.footprintBytes > b, sdStill {
            let su = await sd.stop()
            image = nil
            await emit(.scheduler(SchedulerNote(action: "imageUnloaded", model: req.model.key, seconds: su)))
        }
        let tr = ContinuousClock.now
        try await ctx.reload(back)
        await emit(.scheduler(SchedulerNote(
            action: "chatReloaded", model: back.key, seconds: Self.secs(ContinuousClock.now - tr), detail: ["peak_bytes": "\(peak)"])))
    }

    // MARK: - Video (M5.T03)

    /// One video job through the scheduler's job slot: StepAside makes room beside the job's footprint (T2: the chat
    /// model goes; T3+: it stays when chat + video fit B; the sd-server image context goes), then VideoEngine drives the
    /// runtime server with every preview and the final frames handed to `outputs` (the MediaJobRunner's gate).
    /// After the job: T0–T2 stop the runtime (NFR-R4), T3+ keep it warm for 5 min (architecture §4).
    public func runVideo(_ req: VideoRequest, cancel: CancelFlag, engine: VideoEngine, outputs: MediaJobOutputs,
                         emit: @escaping Emit) async throws -> MediaJobRunner.EngineEnd {
        try await sched.runJob(key: "video") { ctx in
            await self.beginJob("video", cancel: cancel, emit: emit)
            await self.beginVideoControl(req, emit: emit)
            do {
                let end = try await self.runVideoLocked(req, ctx: ctx, cancel: cancel, engine: engine, outputs: outputs, emit: emit)
                await self.endVideoControl(emit: emit)
                await engine.afterJob(keepWarm: await ctx.lowTier() ? nil : .seconds(300))
                await self.endJob()
                return end
            } catch {
                await self.endVideoControl(emit: emit)
                await engine.afterJob(keepWarm: nil)
                await self.endJob()
                throw error
            }
        }
    }

    /// M5.T11: the governor follows this job; the GPU-share sampler runs every 2 s beside it (our own pids excluded).
    func beginVideoControl(_ req: VideoRequest, emit: @escaping Emit) async {
        let gov = videoGovernor
        await gov.begin(emit: emit, yieldEnabled: req.yieldToOtherApps ?? true)
        let monitor = gpuMonitor
        AppLog.log(.engine, .info, "gpuYield start own=\(ownPIDs(child: 0).sorted()) setting=\(req.yieldToOtherApps ?? true)")
        await monitor.start(excluding: { [weak self] in await self?.ownPIDs(child: await gov.childPID) ?? [getpid()] },
                            ownIdle: { await gov.isIdle }, onChange: { busy in
            await gov.setOtherAppBusy(busy)
            let r = await monitor.report
            // M9.T05: the busiest process and its share go to the engine log and the app (its log, the B5 artefact).
            AppLog.log(.engine, .notice, "gpuYield \(r.logLine)")
            await emit(.scheduler(SchedulerNote(action: "gpuYield", model: "video", detail: r.detail)))
        }, onSample: { r in
            // While paused: who keeps the job paused (a resume that never comes names the process); while running:
            // who is busy on the GPU (a pause that never comes names it too).
            let action = r.yielding ? "gpuYieldHold" : "gpuYieldBusy"
            AppLog.log(.engine, .info, "\(action) \(r.logLine)")
            await emit(.scheduler(SchedulerNote(action: action, model: "video", detail: r.detail)))
        })
    }

    func endVideoControl(emit: Emit) async {
        let r = await gpuMonitor.report
        await gpuMonitor.stop()
        await videoGovernor.end()
        // M9.T05: the job's summary (mode, busiest other process and its peak share, samples) in the log and the note.
        AppLog.log(.engine, .notice, "gpuYieldMode \(r.logLine)")
        await emit(.scheduler(SchedulerNote(action: "gpuYieldMode", model: "video", detail: r.detail)))
    }

    func runVideoLocked(_ req: VideoRequest, ctx: ModelScheduler.JobContext, cancel: CancelFlag, engine: VideoEngine,
                        outputs: MediaJobOutputs, emit: @escaping Emit) async throws -> MediaJobRunner.EngineEnd {
        let me = getpid()
        let sampler = PeakSampler()
        sampler.start {
            let child = engine.pidHint.value
            return Self.physFootprint(me) + (child > 0 ? Self.physFootprint(child) : 0)
        }
        defer { _ = sampler.stop() }
        var vm: [String: Double] = [:]
        // perf/t4-video (NFR-VID1): T3+ loads the ChildSafetyCheck detectors beside the generator, during the job, so
        // the final check does not start with their load (M4 lead decision (b), as image jobs with previews do); the
        // step-aside makes room for both. T0–T2 keep them released until the final check (decision (a), NFR-R1).
        let preload = await !ctx.lowTier()
        _ = await stepAsideForMedia(bytes: req.footprintBytes + (preload ? Self.detectorBytes : 0), ctx: ctx, metrics: &vm,
                                    emit: emit)
        if preload { await outputs.preloadDetectors() }
        #if DEBUG || ANTICHAT_PERF_HARNESS
        let scripted = ScriptedVideoEngine.isScripted(req)
        #else
        let scripted = false
        #endif
        // M5.T10: I2V runs on the sd-server child (SDVideoEngine, vid-i2v set); T2V on the video runtime. Any other
        // sd-server context (an image set) goes first.
        let i2v = req.mode == .i2v && !scripted
        let i2vSet = SDVideoEngine.modelSet(req)
        if await sd.isRunning, !(i2v && image?.key == i2vSet.key) {
            let su = await sd.stop()
            image = nil
            await emit(.scheduler(SchedulerNote(action: "imageUnloaded", model: "sd-server", seconds: su)))
        }
        let end: MediaJobRunner.EngineEnd
        if scripted {
            #if DEBUG || ANTICHAT_PERF_HARNESS
            end = try await ScriptedVideoEngine.run(req, isCancelled: { cancel.isCancelled }, outputs: outputs, emit: emit,
                                                    governor: videoGovernor)
            #else
            end = .cancelled
            #endif
        } else if i2v {
            if !(await sd.isRunning) {
                let tl = try await sd.start(i2vSet)
                image = i2vSet
                await emit(.scheduler(SchedulerNote(action: "sdStarted", model: i2vSet.key, seconds: tl, detail: ["pid": "\(await sd.pid)"])))
            }
            let client = await sd.client
            let pid = await sd.pid
            // The I2V context is not kept warm beside the video runtime: it goes with the job, also when the run throws
            // (M5.T14 review P1-3; images reload their own set).
            let governor = videoGovernor
            end = try await Self.runReleasing {
                try await SDVideoEngine.run(req, client: client, isCancelled: { cancel.isCancelled }, outputs: outputs,
                                            emit: emit, pid: pid, governor: governor, stopServer: { [sd] in _ = await sd.stop() })
            } release: {
                let su = await self.sd.stop()
                self.clearImage()
                await emit(.scheduler(SchedulerNote(action: "imageUnloaded", model: i2vSet.key, seconds: su)))
            }
        } else {
            end = try await engine.run(req, isCancelled: { cancel.isCancelled }, outputs: outputs, emit: emit, governor: videoGovernor)
        }
        await emit(.scheduler(SchedulerNote(action: "videoJobEnded", model: "video", detail: [
            "peak_helper_child_bytes": "\(sampler.peak)", "end": end == .cancelled ? "cancelled" : "completed"])))
        return end
    }

    // MARK: - helpers

    /// Runs `body`, then `release` — also when `body` throws (M5.T14 review P1-3: the I2V sd-server context goes with
    /// the job on every path).
    static func runReleasing<T: Sendable>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T,
                                          release: () async -> Void) async throws -> T {
        let result: Result<T, any Error>
        do { result = .success(try await body()) } catch { result = .failure(error) }
        await release()
        return try result.get()
    }

    static func secs(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    public static func physFootprint(_ pid: pid_t) -> UInt64 { Footprint.phys(pid) }

    static func sha256(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// Width/height from the PNG IHDR chunk (bytes 16–23).
    static func pngSize(_ d: Data) -> (Int, Int) {
        guard d.count >= 24 else { return (0, 0) }
        let b = [UInt8](d.prefix(24))
        let w = Int(b[16]) << 24 | Int(b[17]) << 16 | Int(b[18]) << 8 | Int(b[19])
        let h = Int(b[20]) << 24 | Int(b[21]) << 16 | Int(b[22]) << 8 | Int(b[23])
        return (w, h)
    }
}

/// Max of a sampled value every 50 ms on a detached task.
final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var task: Task<Void, Never>?
    var peak: UInt64 { lock.withLock { value } }

    func start(_ sample: @escaping @Sendable () -> UInt64) {
        task = Task.detached { [self] in
            while !Task.isCancelled {
                let v = sample()
                lock.withLock { value = max(value, v) }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func stop() -> UInt64 {
        task?.cancel()
        return peak
    }
}
