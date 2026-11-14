// ChildSafetyCheck (D-005, D-006, R-285): the single content check in AntiChat. It withholds generated
// Photo/Video outputs that are sexual AND appear to involve a minor; nothing else is checked.
// Rule: DecisionRule.swift (model-matrix §10.3), values: Resources/thresholds.json. Fail closed: missing or
// damaged models ⇒ init throws; any runtime error or timeout while nudity is true or unknown ⇒ .block.
// A final class rather than the spec's actor (M4.T01 step 3): it holds only immutable state, and an actor
// would serialise the per-image work that runs on its own queue anyway.
import CoreGraphics
import Foundation
import os

public final class ChildSafetyCheck: Sendable {
    package struct Detectors: Sendable {
        package var nudity: any NudityScoring
        package var nudity2: (any NudityScoring)?
        package var people: any PeopleDetecting
        package var age: any AgeEstimating
        /// SigLIP2 age bins, consulted for people without a usable face (body-only); can only add blocks.
        package var ageBins: (any AgeBinScoring)?
        package init(nudity: any NudityScoring, nudity2: (any NudityScoring)?,
                     people: any PeopleDetecting, age: any AgeEstimating, ageBins: (any AgeBinScoring)? = nil) {
            self.nudity = nudity
            self.nudity2 = nudity2
            self.people = people
            self.age = age
            self.ageBins = ageBins
        }
    }

    /// What one evaluation saw. Package-internal (bench + tests); never leaves the package.
    package struct Trace: Sendable {
        package var verdict: Verdict
        package var nudity: Double?
        package var nudity2: Double?
        package var nude: Bool?
        package var faceAges: [Double] = []
        package var bodyOnlyAges: [Double] = []
        /// Age-bin P(Child) + P(Teen) per body-only query (empty when the signal is off).
        package var bodyOnlyYoung: [Double] = []
        package var minor: Bool?
        package var failure: DetectorError?
        /// Wall time per stage in ms (csc-bench diagnostics; never leaves the package). `mivolo` and `bins` overlap.
        package var stageMs = StageTimes()
    }

    package struct StageTimes: Sendable {
        package var nudity: Double?
        package var people: Double?
        /// The whole age stage (MiVOLO and the age bins, which run side by side).
        package var ageStage: Double?
        package var mivolo: Double?
        package var bins: Double?
    }

    package let detectors: Detectors
    package let thresholds: Thresholds
    /// A-M5-09 (lead decision): deadline of the ONE re-check after a timeout (the first deadline stays
    /// `thresholds.timeout`, 2 s). Not a calibration value and not in thresholds.json.
    package let retryTimeout: Double
    package static let timeoutRetrySeconds = 10.0
    private static let log = Logger(subsystem: "app.antichat.childsafety", category: "check")
    private let retryCount = OSAllocatedUnfairLock(initialState: 0)
    /// Timeout re-checks made by this instance (counted for the logs; no content, no verdict reason).
    public var timeoutRetries: Int { retryCount.withLock { $0 } }

    /// Loads the detectors from `modelDirectory`, which holds the catalog entries at
    /// `csc-nudity/onnx/model.onnx`, `csc-age/mivolo_v2_age.onnx`, `csc-age-bins/model.safetensors` and,
    /// optionally, `csc-nudity2/marqo-nsfw-384.onnx` (a second nudity signal that can only add blocks).
    /// The age bins are required whenever the thresholds enable them (`T_age_bins` set).
    /// Throws if a required model is missing or any present model fails to load (fail closed:
    /// the caller disables Photo/Video). `cacheDirectory` holds compiled Core ML models so later
    /// loads skip compilation (any writable app cache folder; nil = compile on every load).
    public convenience init(modelDirectory: URL, provider: ExecutionProvider = .coreml,
                            cacheDirectory: URL? = nil) throws {
        let marqoPath = modelDirectory.appending(path: MarqoNudity.relativePath).path
        let nudity2: (any NudityScoring)? = FileManager.default.fileExists(atPath: marqoPath)
            ? try MarqoNudity(modelDirectory: modelDirectory, provider: provider, cacheDirectory: cacheDirectory) : nil
        let thresholds = try Thresholds.bundled()
        let binsPath = modelDirectory.appending(path: SigLIPAgeBins.relativePath)
        let ageBins: (any AgeBinScoring)? = thresholds.tAgeBins.isFinite
            || FileManager.default.fileExists(atPath: binsPath.path) ? try SigLIPAgeBins(path: binsPath) : nil
        let nudity = try FreepikNudity(modelDirectory: modelDirectory, provider: provider, cacheDirectory: cacheDirectory)
        let age = try MiVOLOAge(modelDirectory: modelDirectory, provider: provider, cacheDirectory: cacheDirectory)
        // M9 review E1: an unreadable weight file fails the load (closed); no marker, so the next load retries.
        if let cacheDirectory { try CompiledModelCache.compact(cacheDirectory) }
        self.init(detectors: Detectors(
            nudity: nudity,
            nudity2: nudity2,
            people: VisionPeople(),
            age: age,
            ageBins: ageBins
        ), thresholds: thresholds)
    }

    /// Production entry point: verifies every file of `manifest` against its sha256, then loads the
    /// detectors and the thresholds. Throws `.modelsMissing` (a file is absent) or `.modelsDamaged`
    /// (wrong hash, unreadable thresholds, or a model that fails to load); the caller then disables
    /// Photo/Video output and offers the repair (fail closed, R-285 AC6).
    public convenience init(manifest: ModelManifest, provider: ExecutionProvider = .coreml,
                            cacheDirectory: URL? = nil) throws(CheckError) {
        try manifest.verifyPresence()
        // The detectors are independent: each one's pipeline (sha256 of its file, then its load and warm-up run)
        // runs on its own lane, so the load costs the slowest detector rather than the sum (T1 final check, NFR-P1).
        // A file is loaded only after its own hash matched; any mismatch or load error ⇒ modelsDamaged.
        let loaded = Self.inParallel([
            { () throws -> any Sendable in
                try manifest.verifyFile(ModelManifest.nudityKey, manifest.nudity)
                return try FreepikNudity(path: manifest.nudity, provider: provider, cacheDirectory: cacheDirectory)
            },
            { () throws -> any Sendable in
                try manifest.verifyFile(ModelManifest.ageKey, manifest.age)
                return try MiVOLOAge(path: manifest.age, provider: provider, cacheDirectory: cacheDirectory)
            },
            { () throws -> any Sendable in
                try manifest.verifyFile(ModelManifest.ageBinsKey, manifest.ageBins)
                return try SigLIPAgeBins(path: manifest.ageBins)
            },
            { () throws -> any Sendable in
                guard let url = manifest.nudity2 else { return Optional<MarqoNudity>.none }
                try manifest.verifyFile(ModelManifest.nudity2Key, url)
                return Optional(try MarqoNudity(path: url, provider: provider, cacheDirectory: cacheDirectory))
            },
            { () throws -> any Sendable in
                try manifest.thresholds.map { try Thresholds.decode(Data(contentsOf: $0)) } ?? Thresholds.bundled()
            },
        ])
        guard case .success(let n as FreepikNudity) = loaded[0], case .success(let a as MiVOLOAge) = loaded[1],
              case .success(let b as SigLIPAgeBins) = loaded[2], case .success(let n2 as MarqoNudity?) = loaded[3],
              case .success(let t as Thresholds) = loaded[4] else { throw .modelsDamaged }
        // The compiled cache's immediate weights → weight files (once per install; bit-identical, CompiledModelCache).
        // M9 review E1: an unreadable weight file ⇒ modelsDamaged (fail closed); no marker, so the next load retries.
        if let cacheDirectory {
            do { try CompiledModelCache.compact(cacheDirectory) } catch { throw .modelsDamaged }
        }
        self.init(detectors: Detectors(nudity: n, nudity2: n2, people: VisionPeople(), age: a, ageBins: b), thresholds: t)
    }

    /// Runs `jobs` concurrently (one lane each) and returns their results in order.
    static func inParallel(_ jobs: [@Sendable () throws -> any Sendable]) -> [Result<any Sendable, Error>] {
        let out = OSAllocatedUnfairLock(initialState: [Result<any Sendable, Error>?](repeating: nil, count: jobs.count))
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let r = Result { try jobs[i]() }
            out.withLock { $0[i] = r }
        }
        return out.withLock { $0 }.map { $0! }
    }

    /// Longest wait for the inference lane before a check starts (M4 review P1-1); see `withDeadline`.
    package let queueWait: Double
    public static let defaultQueueWait: Double = 4

    /// The lane this instance's evaluations run on: the process-wide `inference` lane; tests that time a single
    /// instance pass their own so another suite's deliberately hung detector cannot queue them.
    let lane: DispatchQueue

    package init(detectors: Detectors, thresholds: Thresholds, queueWait: Double = ChildSafetyCheck.defaultQueueWait,
                 retryTimeout: Double = ChildSafetyCheck.timeoutRetrySeconds, lane: DispatchQueue = ChildSafetyCheck.inference) {
        self.detectors = detectors
        self.thresholds = thresholds
        self.queueWait = queueWait
        self.retryTimeout = retryTimeout
        self.lane = lane
    }

    /// Evaluates one generated image (a final output or a preview frame). A-M5-09: when the check hits its deadline
    /// (2 s), the same image is checked once more with a `retryTimeout` (10 s) deadline; a second timeout blocks, as
    /// before. Only a timeout is retried: a verdict or any other detector error is final. The rule, detectors and
    /// thresholds are unchanged; the caller shows or writes nothing until this returns `.allow`.
    public func evaluate(image: CGImage) async -> Verdict {
        await evaluateWithRetry(image: image).verdict
    }

    /// M4 review P1-3 / P2-7: checks one live PREVIEW. A preview whose shorter side is below `preview_min_side_px`
    /// (where the minor branch of the rule was not shown valid: faces fall under `face_min_side_px`, bodies are a few
    /// dozen pixels) is withheld without running anything. Otherwise one check runs with the normal deadline and no
    /// re-check: a rule block stops the job; a timeout or detector error while nudity is true or unknown withholds only
    /// this preview (still fail closed: nothing unchecked is shown). Finals use `evaluate`, unchanged.
    public func evaluatePreview(image: CGImage) async -> PreviewVerdict {
        guard Self.previewCheckable(width: image.width, height: image.height, thresholds) else { return .withhold }
        return Self.previewVerdict(await evaluateTracked(image: image, deadline: nil).trace)
    }

    package static func previewCheckable(width: Int, height: Int, _ t: Thresholds) -> Bool {
        Double(min(width, height)) >= t.previewMinSide
    }

    /// fix/t05-video: the shipped thresholds' `preview_min_side_px` (`.infinity` when the bundled file is missing or
    /// invalid: then no preview is ever checkable, fail closed). Lets the caller skip work for a preview that
    /// `evaluatePreview` would withhold anyway (no detector load, no preview decode); it never lets anything through:
    /// a preview at or above this size still goes through `evaluatePreview`, whose own thresholds decide.
    public static let shippedPreviewMinSide: Double = (try? Thresholds.bundled().previewMinSide) ?? .infinity

    /// True when a preview of this size could be shown under the shipped thresholds (`evaluatePreview` still decides).
    public static func previewSizeCheckable(width: Int, height: Int) -> Bool {
        Double(min(width, height)) >= shippedPreviewMinSide
    }

    package static func previewVerdict(_ trace: Trace) -> PreviewVerdict {
        guard trace.failure == nil else { return trace.verdict == .allow ? .show : .withhold }
        return trace.verdict == .allow ? .show : .block
    }

    /// `evaluate` with its trace (package: tests + bench). `retried` = the first attempt timed out.
    /// The re-check never runs beside the timed-out analysis (still running on its queue): it first waits for that run
    /// to finish, and the wait counts inside the `retryTimeout` budget (M5.T14 review). A first run that does not end
    /// within the budget, or a re-check that hits what is left of it, blocks.
    package func evaluateWithRetry(image: CGImage) async -> (verdict: Verdict, trace: Trace, retried: Bool) {
        let (first, firstDone) = await evaluateTracked(image: image, deadline: nil)
        guard first.failure == .timeout else { return (first.verdict, first, false) }
        retryCount.withLock { $0 += 1 }
        let start = DispatchTime.now()
        let finished = await firstDone.wait(seconds: retryTimeout)
        let left = retryTimeout - Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        let second: Trace
        if finished, left > 0 {
            second = await evaluateTracked(image: image, deadline: left).trace
        } else {
            second = Trace(verdict: .block, failure: .timeout)
        }
        Self.log.notice("timeout re-check: \(second.failure == .timeout ? "timed out again, blocked" : "completed", privacy: .public)")
        return (second.verdict, second, true)
    }

    /// Evaluates already-sampled frames of one video (≥ 2 fps + first/last frame + every preview, NFR-F9).
    /// Prefer `evaluateVideo(frames:frameCount:fps:)`, which samples and checks coverage itself. Blocks as soon as one frame blocks. An empty stream blocks (nothing
    /// was checked, so nothing may be shown).
    public func evaluateVideo(frames: AsyncStream<CGImage>) async -> Verdict {
        var checked = false
        for await frame in frames {
            checked = true
            if await evaluate(image: frame) == .block { return .block }
        }
        // Cancellation ends the stream early: the remaining frames were never checked ⇒ block.
        if Task.isCancelled { return .block }
        return checked ? .allow : .block
    }

    /// `forceFullPath` runs face/body/age detection even when the image is not nude (latency bench
    /// worst case); the verdict is unaffected.
    package func evaluateDetailed(image: CGImage, forceFullPath: Bool = false, deadline: Double? = nil) async -> Trace {
        await evaluateTracked(image: image, forceFullPath: forceFullPath, deadline: deadline).trace
    }

    /// `evaluateDetailed` plus a signal that fires when the analysis itself ends (after a timeout it keeps running).
    func evaluateTracked(image: CGImage, forceFullPath: Bool = false, deadline: Double?) async -> (trace: Trace, done: DoneSignal) {
        let detectors = self.detectors, t = self.thresholds
        let done = DoneSignal()
        let result = await Self.withDeadline(deadline ?? t.timeout, queueWait: queueWait, lane: lane, done: done) {
            Self.analyze(image, detectors, t, forceFullPath: forceFullPath)
        }
        switch result {
        case .success(let trace):
            return (trace, done)
        case .failure(let error):
            // Timeout: nudity unknown or true at this point ⇒ fail closed.
            return (Trace(verdict: .block, failure: error as? DetectorError ?? .timeout), done)
        }
    }

    static func analyze(_ image: CGImage, _ d: Detectors, _ t: Thresholds, forceFullPath: Bool) -> Trace {
        var trace = Trace(verdict: .block)
        let t0 = DispatchTime.now()
        do {
            trace.nudity = try d.nudity.nudityScore(image)
            if let n2 = d.nudity2 { trace.nudity2 = try n2.nudityScore(image) }
            // A NaN/inf score compares false against every threshold (would read as "not nude").
            guard trace.nudity!.isFinite, trace.nudity2?.isFinite ?? true else {
                throw DetectorError.inference("non-finite nudity score")
            }
        } catch {
            trace.failure = error as? DetectorError ?? .inference("\(error)")
            return trace  // nudity unknown ⇒ block
        }
        let nude = DecisionRule.isNude(n: trace.nudity!, n2: trace.nudity2, t)
        trace.nude = nude
        trace.stageMs.nudity = ms(since: t0)
        guard nude || forceFullPath else {
            trace.verdict = .allow
            return trace
        }
        do {
            let t1 = DispatchTime.now()
            let people = try d.people.detect(image)
            trace.stageMs.people = ms(since: t1)
            let queries = DecisionRule.ageQueries(people, t)
            // Body-only queries also get the age-bin signal when the thresholds enable it; enabled but not
            // loaded is a broken install ⇒ error ⇒ block while nude (fail closed).
            let useBins = t.tAgeBins.isFinite
            if useBins, d.ageBins == nil, queries.contains(where: { $0.kind == .bodyOnly }) {
                throw DetectorError.modelMissing("age bins")
            }
            // A requested crop that fails must not silently become MiVOLO's black "no crop".
            let inputs = try queries.map { q -> AgeInput in
                let face = q.face.flatMap { ImageTensor.crop(image, $0) }
                let body = q.body.flatMap { ImageTensor.crop(image, $0) }
                if (q.face != nil && face == nil) || (q.body != nil && body == nil) { throw DetectorError.preprocessing }
                return AgeInput(face: face, body: body)
            }
            let binCrops: [CGImage] = useBins ? zip(queries, inputs).compactMap { $0.kind == .bodyOnly ? $1.body : nil } : []
            let t2 = DispatchTime.now()
            let (ages, young) = try Self.ageStage(inputs, binCrops: binCrops, d, times: &trace.stageMs)
            trace.stageMs.ageStage = ms(since: t2)
            guard ages.count == queries.count, young.count == binCrops.count else {
                throw DetectorError.inference("age stage: result count")
            }
            for (q, a) in zip(queries, ages) {
                guard a.isFinite else { throw DetectorError.inference("non-finite age") }
                switch q.kind {
                case .face: trace.faceAges.append(a)
                case .bodyOnly: trace.bodyOnlyAges.append(a)
                }
            }
            for y in young {
                guard y.isFinite else { throw DetectorError.inference("non-finite age bins") }
                trace.bodyOnlyYoung.append(y)
            }
            let minor = DecisionRule.isMinor(faceAges: trace.faceAges, bodyOnlyAges: trace.bodyOnlyAges,
                                             bodyOnlyYoung: trace.bodyOnlyYoung, t)
            trace.minor = minor
            trace.verdict = DecisionRule.verdict(nude: nude, minor: minor)
        } catch {
            trace.failure = error as? DetectorError ?? .inference("\(error)")
            trace.verdict = nude ? .block : .allow  // error while nude ⇒ block
        }
        return trace
    }

    /// The age stage of one image (F7 tail, A-M9-T05-F7): MiVOLO for every query in ONE `ages` call (its runs one after
    /// another, `InferenceLock.onnx`) and, beside it, the age bins for every body-only crop in ONE `youngProbabilities`
    /// call (CPU/Accelerate, `InferenceLock.accelerate`). The two are independent (different models, engines and
    /// inputs) and each is serial, so each result is what it would be alone; only the wall time changes (the
    /// bins used to add ≈ 43 ms per body-only person after the MiVOLO runs). Both always finish before this returns,
    /// so nothing outlives the evaluation, and an error from either fails the stage (⇒ block while nude).
    static func ageStage(_ inputs: [AgeInput], binCrops: [CGImage], _ d: Detectors,
                         times: inout StageTimes) throws -> (ages: [Double], young: [Double]) {
        let start = DispatchTime.now()
        guard !binCrops.isEmpty, let bins = d.ageBins else {
            let ages = try inputs.isEmpty ? [] : d.age.ages(inputs)
            times.mivolo = ms(since: start)
            return (ages, [])
        }
        let binsResult = SlotBox<(Result<[Double], Error>, Double)>(count: 1)
        let group = DispatchGroup()
        let crops = binCrops.map(SendableImage.init)
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            let b0 = DispatchTime.now()
            let r = Result { try bins.youngProbabilities(crops.map(\.image)) }
            binsResult.set(0, (r, ms(since: b0)))
        }
        let ages = Result { try d.age.ages(inputs) }
        times.mivolo = ms(since: start)
        group.wait()  // always joined, also when MiVOLO failed: nothing outlives the evaluation
        let (young, binsMs) = binsResult.values()[0]
        times.bins = binsMs
        return (try ages.get(), try young.get())
    }

    /// The one lane every evaluation runs on, process-wide (all instances): two evaluations never run at the same time,
    /// so a verdict cannot depend on what else is being checked (inside one evaluation only the age bins run beside
    /// MiVOLO, on another engine: `ageStage`, `InferenceLock`). (Diagnosis, 1676-row calibration set:
    /// the scores themselves are reproducible in any order or concurrency; what differed between runs were checks
    /// that hit the deadline under contention and failed closed. One lane keeps checks from slowing each other.)
    package static let inference = DispatchQueue(label: "app.antichat.ChildSafetyCheck.inference", qos: .userInitiated)

    /// Runs synchronous detector work on the inference lane. It gives up `seconds` after the work STARTS (a check
    /// queued behind another is not charged for that wait) and, whatever happens, `seconds + queueWait` after it was
    /// ENQUEUED (M4 review P1-1: a detector call that never returns holds the lane; without this cap every later check
    /// would wait forever and the media queue would die); either way the caller gets `.timeout` (⇒ block). A timed-out evaluation still holds the lane
    /// until it finishes, so no two inferences ever overlap; queued work whose caller already gave up is skipped.
    /// `done` fires when the work has finished on the lane, or was skipped (A-M5-09: the timeout re-check waits for it).
    static func withDeadline<T: Sendable>(_ seconds: Double, queueWait: Double = ChildSafetyCheck.defaultQueueWait,
                                          lane: DispatchQueue = ChildSafetyCheck.inference, done: DoneSignal? = nil,
                                          _ work: @Sendable @escaping () -> T) async -> Result<T, Error> {
        let cap = seconds + queueWait
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<T, Error>, Never>) in
            let once = ResumeOnce(cont)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + cap) {
                once.resume(.failure(DetectorError.timeout))
            }
            lane.async {
                guard !once.isResumed else { done?.fire(); return }  // the caller gave up while queued: do not run it
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                    once.resume(.failure(DetectorError.timeout))
                }
                let value = work()
                done?.fire()
                once.resume(.success(value))
            }
        }
    }
}

/// Fires once when a detector run ends; `wait` returns true when it fired within `seconds`.
final class DoneSignal: Sendable {
    private let state = OSAllocatedUnfairLock<(fired: Bool, waiters: [@Sendable (Bool) -> Void])>(initialState: (false, []))

    func fire() {
        let waiters = state.withLock { s -> [@Sendable (Bool) -> Void] in
            s.fired = true
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0(true) }
    }

    var isFired: Bool { state.withLock { $0.fired } }

    func wait(seconds: Double) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let once = OnceBool(c)
            let fired = state.withLock { s -> Bool in
                if !s.fired { s.waiters.append { once.resume($0) } }
                return s.fired
            }
            if fired { once.resume(true); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, seconds)) { once.resume(false) }
        }
    }
}

/// Resumes a Bool continuation once (the fire and the timeout race).
private final class OnceBool: Sendable {
    private let state: OSAllocatedUnfairLock<CheckedContinuation<Bool, Never>?>
    init(_ c: CheckedContinuation<Bool, Never>) { state = OSAllocatedUnfairLock(initialState: c) }
    func resume(_ v: Bool) {
        let c = state.withLock { s -> CheckedContinuation<Bool, Never>? in
            defer { s = nil }
            return s
        }
        c?.resume(returning: v)
    }
}

private final class ResumeOnce<T: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<CheckedContinuation<Result<T, Error>, Never>?>
    init(_ c: CheckedContinuation<Result<T, Error>, Never>) { state = OSAllocatedUnfairLock(initialState: c) }
    var isResumed: Bool { state.withLock { $0 == nil } }
    func resume(_ value: Result<T, Error>) {
        let c = state.withLock { s -> CheckedContinuation<Result<T, Error>, Never>? in
            defer { s = nil }
            return s
        }
        c?.resume(returning: value)
    }
}

/// Milliseconds since `start` (stage diagnostics).
func ms(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
}
