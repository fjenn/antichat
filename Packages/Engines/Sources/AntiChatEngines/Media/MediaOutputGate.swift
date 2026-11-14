// MediaOutputGate: the single ChildSafetyCheck call site (D-006, R-241, R-285, architecture §3 rule 2).
// This is the ONLY file in the tree that may `import ChildSafetyCheck` (tools/ci/r241-audit.py rule 1), and its
// `check*` methods are called only from `MediaJobRunner.emitPreview/emitResult/emitVideoResult` (rule 2), before anything is written
// to disk or emitted. Every Photo/Video output goes through here; nothing else does (rule 5, R241PathTraceTests).
// Fail closed: no manifest, missing/damaged detectors ⇒ `.safetyMissing` for every call; a detector error or
// timeout while nude or unknown ⇒ `.block` (inside the package). No setting, launch argument or environment variable
// changes this; the only test seam (a forced verdict for the UI "blocked" state) compiles under
// `ANTICHAT_UI_TESTING`, which no Debug or Release configuration defines (audited, incl. an `nm` scan).
import AntiChatEngineProtocol
import AntiChatFoundation
import ChildSafetyCheck
import CoreGraphics
import CryptoKit
import Foundation

public actor MediaOutputGate {
    /// Invocation counter for the R-241 path rule (integration runtime trace; reset by tests).
    public static let trace = InvocationTrace()
    /// A trace scoped to one task tree (tests): every check is recorded in `trace` AND here when set, so a test counts
    /// exactly its own gate calls while other suites check in parallel (the process-wide `trace` is shared by them).
    @TaskLocal static var scopedTrace: InvocationTrace?

    /// Records one gate invocation in the process-wide trace and, when set, the task's scoped trace.
    static func recordInvocation(_ kind: MediaOutputKind) {
        trace.record(kind)
        scopedTrace?.record(kind)
    }

    private let manifestProvider: @Sendable () -> SafetyManifest?
    private let cacheDirectory: URL?
    private var checker: ChildSafetyCheck?
    /// The manifest `checker` was loaded from: a job with another manifest (or none) reloads (or fails closed).
    private var loadedFrom: SafetyManifest?
    /// This gate's own check count per kind (the static `trace` is process-wide; tests of one runner read this).
    public private(set) var calls: [MediaOutputKind: Int] = [:]
    /// A-M5-09: timeout re-checks per kind (ChildSafetyCheck re-checks a timed-out image once with a 10 s deadline).
    public private(set) var timeoutRetries: [MediaOutputKind: Int] = [:]
    /// M9 review E3: checks running now (the runner never releases the detectors at a job's end while one runs).
    public private(set) var checksInFlight = 0

    /// `manifestProvider` resolves the installed detector files (nil = not installed ⇒ `safetyMissing`).
    /// The checker loads at the first check (detectors are resident only around Photo/Video outputs, NFR-R4).
    public init(manifestProvider: @escaping @Sendable () -> SafetyManifest?, cacheDirectory: URL? = nil) {
        self.manifestProvider = manifestProvider
        self.cacheDirectory = cacheDirectory
    }

    /// The outcome for one live PREVIEW (M4 review P1-3 / P2-7): `withhold` = this preview is not shown and the job
    /// goes on (the check is not valid at its size, or it timed out / errored while nudity was true or unknown);
    /// `block` / `safetyMissing` stop the job as for a final output.
    public enum PreviewOutcome: Sendable, Equatable {
        case allow, withhold, block
        case safetyMissing(sizeBytes: Int64)
    }

    /// One live preview of a job.
    public func checkPreview(_ image: CGImage, job: MediaJobID) async -> PreviewOutcome {
        Self.recordInvocation(.preview)
        calls[.preview, default: 0] += 1
        checksInFlight += 1
        defer { checksInFlight -= 1 }
        #if ANTICHAT_UI_TESTING
        if let forced = ForcedVerdictCheck.current { return forced == .allow ? .allow : .block }
        #endif
        // fix/t05-video (NFR-F7): a preview below the shipped valid size is withheld by `evaluatePreview` without running
        // anything, so it does not load the detectors either (≈ 0.8–1.0 s inline on the job's step, and ≈ 4.3 GB
        // beside the generator on T0–T2, NFR-R1). Nothing installed still fails closed here, as before; a damaged
        // install is found by the next real check (the final one, which then withholds the output).
        if !Self.previewSizeShowable(width: image.width, height: image.height) {
            return manifestProvider() == nil ? .safetyMissing(sizeBytes: 0) : .withhold
        }
        switch loadChecker() {
        case .failure(let m): return .safetyMissing(sizeBytes: m.sizeBytes)
        case .success(let c):
            switch await c.evaluatePreview(image: image) {
            case .show: return .allow
            case .withhold: return .withhold
            case .block: return .block
            }
        }
    }

    /// fix/t05-video: the shortest preview side (px) at which a live preview can be shown at all (the shipped
    /// `preview_min_side_px`; 0 is never returned: unreadable thresholds ⇒ `Int.max`, no preview is showable).
    /// VideoEngine asks the runtime for previews at this size, or for none when the clip is smaller.
    public nonisolated static var previewMinSide: Int {
        let s = ChildSafetyCheck.shippedPreviewMinSide
        return s.isFinite && s >= 1 ? Int(s.rounded(.up)) : Int.max
    }

    /// True when a preview of this size can be shown under the shipped thresholds (the check still decides).
    public nonisolated static func previewSizeShowable(width: Int, height: Int) -> Bool {
        ChildSafetyCheck.previewSizeCheckable(width: width, height: height)
    }

    /// The final output of a job (image result; Remove background and other local edits too, M4.T15).
    public func checkResult(_ image: CGImage, job: MediaJobID) async -> GateOutcome {
        await check(image, kind: .result, job: job)
    }

    /// A whole video: frames are sampled at ≥ 2 fps + first + last + every preview; an incomplete stream blocks.
    /// The frame indices `checkVideo` must see for a clip (≥ 2 fps + first + last, D-014): the runner builds only
    /// these frames' images (M5.T14 review P2); any other non-preview frame is skipped by the check anyway.
    public nonisolated static func sampleIndices(frameCount: Int, fps: Double) -> [Int] {
        ChildSafetyCheck.sampleIndices(frameCount: frameCount, fps: fps)
    }

    public func checkVideo(frames: AsyncThrowingStream<MediaFrame, Error>, frameCount: Int, fps: Double,
                           job: MediaJobID) async -> GateOutcome {
        Self.recordInvocation(.video)
        calls[.video, default: 0] += 1
        checksInFlight += 1
        defer { checksInFlight -= 1 }
        #if ANTICHAT_UI_TESTING
        if let forced = ForcedVerdictCheck.current {
            // Drain the stream like a real check (an incomplete stream still blocks); the verdict is forced.
            do { for try await f in frames { _ = f.index } } catch { return .block }
            return forced
        }
        #endif
        switch loadChecker() {
        case .failure(let m): return .safetyMissing(sizeBytes: m.sizeBytes)
        case .success(let c):
            let mapped = AsyncThrowingStream<VideoFrame, Error> { cont in
                let t = Task {
                    do {
                        for try await f in frames { cont.yield(VideoFrame(index: f.index, image: f.image, isPreview: f.isPreview)) }
                        cont.finish()
                    } catch { cont.finish(throwing: error) }
                }
                cont.onTermination = { _ in t.cancel() }
            }
            let before = c.timeoutRetries
            let v = await c.evaluateVideo(frames: mapped, frameCount: frameCount, fps: fps)
            noteRetries(c.timeoutRetries - before, kind: .video, job: job)
            return v == .allow ? .allow : .block
        }
    }

    /// Drops the loaded detectors (the runner calls this 60 s after its queue drains, NFR-R4).
    public func release() {
        checker = nil
        loadedFrom = nil
    }

    public var isLoaded: Bool { checker != nil }

    /// Seconds the last detector load took (manifest verify + session create), nil before any load.
    public private(set) var lastLoadSeconds: Double?

    /// M4 lead decision (b): loads the detectors ahead of the first check (an image job was queued and memory allows
    /// them beside the generator). Evaluates nothing; a missing or damaged install stays unloaded (the check then
    /// fails closed as before). Returns the load's seconds (0 = already loaded, nil = could not load).
    @discardableResult
    public func preload() -> Double? {
        let wasLoaded = checker != nil && manifestProvider() == loadedFrom
        guard case .success = loadChecker() else { return nil }
        return wasLoaded ? 0 : lastLoadSeconds
    }

    private func check(_ image: CGImage, kind: MediaOutputKind, job: MediaJobID) async -> GateOutcome {
        Self.recordInvocation(kind)
        calls[kind, default: 0] += 1
        checksInFlight += 1
        defer { checksInFlight -= 1 }
        #if ANTICHAT_UI_TESTING
        if let forced = ForcedVerdictCheck.current { return forced }
        #endif
        switch loadChecker() {
        case .failure(let m): return .safetyMissing(sizeBytes: m.sizeBytes)
        case .success(let c):
            let before = c.timeoutRetries
            let v = await c.evaluate(image: image)
            noteRetries(c.timeoutRetries - before, kind: kind, job: job)
            return v == .allow ? .allow : .block
        }
    }

    /// Counts and logs timeout re-checks (no content, no verdict reason).
    private func noteRetries(_ n: Int, kind: MediaOutputKind, job: MediaJobID) {
        guard n > 0 else { return }
        timeoutRetries[kind, default: 0] += n
        AppLog.log(.media, .notice, "media gate: \(n) timeout re-check(s) on \(kind.rawValue) of job \(job) (A-M5-09)")
    }

    /// Compiled Core ML models of one detector set: `<cacheDirectory>/<key of the manifest's sha256s>/`, so a model
    /// change (new sha256) compiles into a fresh folder and an unchanged set always reuses its compiled form.
    static func compiledKey(_ m: SafetyManifest) -> String {
        let line = m.sha256.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.lowercased())" }.joined(separator: "\n")
        return SHA256.hash(data: Data(line.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func compiledDirectory(_ m: SafetyManifest, cacheDirectory: URL?) -> URL? {
        cacheDirectory?.appendingPathComponent(compiledKey(m), isDirectory: true)
    }

    func compiledDirectory(_ m: SafetyManifest) -> URL? {
        cacheDirectory?.appendingPathComponent(Self.compiledKey(m), isDirectory: true)
    }

    static let preparedMarker = "prepared.json"
    /// How long another detector set's compiled folder is kept after it was last prepared (shared cache root).
    static let otherSetsKeptFor: TimeInterval = 7 * 86_400

    /// True when neither `dir` nor its prepared marker changed within `age` seconds.
    static func untouched(_ dir: URL, for age: TimeInterval, now: Date = Date()) -> Bool {
        let fm = FileManager.default
        let dates = [dir, dir.appendingPathComponent(preparedMarker)].compactMap {
            (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        return dates.allSatisfy { now.timeIntervalSince($0) > age }
    }

    /// Install-time preparation (lead decision, M4): verifies `m` and compiles its detectors into their compiled
    /// cache folder, right after the Photo/Video pack's download verifies, so the first image does not pay the
    /// ≈ 170 s first compile. Idempotent: an already prepared set returns `.alreadyPrepared` without loading; other
    /// detector sets' folders are removed. The loaded detectors are dropped again (resident only around outputs,
    /// NFR-R4). Evaluates nothing.
    /// Review P2: the ≈ 170 s compile runs OFF the gate actor (a detached task), so checks are never stuck behind it.
    /// M9 review E2: it can therefore run beside the actor's `loadChecker` on the same folder. Both now compile only
    /// under the folder's lock (`withFolderLock`) and only through `compileAtomically` (a temp folder renamed into
    /// place, marked prepared last), so a folder is either absent, prepared, or a leftover that the next one replaces.
    public nonisolated func prepare(_ m: SafetyManifest) async -> PrepareOutcome {
        let cache = cacheDirectory
        return await Task.detached(priority: .utility) { Self.prepareBlocking(m, cacheDirectory: cache) }.value
    }

    static func prepareBlocking(_ m: SafetyManifest, cacheDirectory: URL?) -> PrepareOutcome {
        guard let dir = compiledDirectory(m, cacheDirectory: cacheDirectory) else { return .failed }
        let outcome: PrepareOutcome
        do {
            outcome = try withFolderLock(dir) { () throws -> PrepareOutcome in
                let marker = dir.appendingPathComponent(Self.preparedMarker)
                if FileManager.default.fileExists(atPath: marker.path) {
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: marker.path)  // in use
                    return .alreadyPrepared
                }
                let t0 = ContinuousClock.now
                _ = try compileAtomically(dir, key: Self.compiledKey(m)) { try Self.makeChecker(m, cacheDirectory: $0) }
                let d = ContinuousClock.now - t0
                return .prepared(seconds: Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
            }
        } catch {
            return .failed  // nothing marked: `isPrepared` stays false and the next prepare or check compiles again
        }
        // Other detector sets' folders go only once nobody has prepared them for a week: the cache root is shared by every
        // helper using these caches (a second app instance, test hosts of other checkouts), and one of them may be
        // checking with an older set right now (a missing set fails closed: blocked / safety missing).
        // M9 review E2: lock files are never removed (another helper may hold one: a new file would not exclude it).
        if let root = cacheDirectory, let others = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            for o in others where o != dir.lastPathComponent && !o.hasSuffix(Self.lockSuffix) {
                let u = root.appendingPathComponent(o)
                guard Self.untouched(u, for: Self.otherSetsKeptFor) else { continue }
                try? FileManager.default.removeItem(at: u)
            }
        }
        return outcome
    }

    static let lockSuffix = ".lock"

    /// M9 review E2: runs `body` holding the exclusive lock of one compiled folder: `<cache>/.<key>.lock`, a sibling of
    /// the folder so that the folder itself can be replaced by a rename. `flock` excludes other open descriptions, so
    /// it serialises the detached `prepare` against the gate actor's load in this helper and against other helpers on
    /// the same cache root. Throws when the lock file cannot be opened (the caller then fails closed).
    static func withFolderLock<T>(_ dir: URL, _ body: () throws -> T) throws -> T {
        let root = dir.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = root.appendingPathComponent(".\(dir.lastPathComponent)\(lockSuffix)")
        let fd = open(lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw CocoaError(.fileLocking) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// M9 review E2: compiles a detector set into `dir` atomically. Call only under `withFolderLock(dir)`.
    /// The first load compiles (and compacts the compiled form, CompiledModelCache) into a fresh temp folder next to
    /// `dir`; only a complete compile is renamed into place (a leftover `dir` without the prepared marker, torn by an
    /// earlier crash or failure, is replaced). The second load, at the final path, builds Core ML's on-device form of
    /// the compacted models, so the first check loads from warm caches. The prepared marker is written last: a folder
    /// without it is never loaded as is. Any error ⇒ throws, temp folder removed, nothing marked. Returns the second load.
    static func compileAtomically<T>(_ dir: URL, key: String, load: (URL) throws -> T) throws -> T {
        let fm = FileManager.default
        let root = dir.deletingLastPathComponent()
        let tmp = root.appendingPathComponent(".\(dir.lastPathComponent).compiling-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let t0 = ContinuousClock.now
        _ = try load(tmp)
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        try fm.moveItem(at: tmp, to: dir)
        let loaded = try load(dir)
        let d = ContinuousClock.now - t0
        let secs = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        let note = ["key": key, "seconds": String(format: "%.1f", secs)]
        try JSONSerialization.data(withJSONObject: note, options: [.sortedKeys])
            .write(to: dir.appendingPathComponent(preparedMarker), options: .atomic)
        return loaded
    }

    /// M9 review E2: the gate's load of a set's checker from its compiled folder. A prepared folder loads as is; any
    /// other state (absent, or a leftover without the marker) compiles atomically first. Serialised with `prepare`.
    static func loadCompiled<T>(_ dir: URL, key: String, load: (URL) throws -> T) throws -> T {
        try withFolderLock(dir) {
            let marker = dir.appendingPathComponent(preparedMarker)
            if FileManager.default.fileExists(atPath: marker.path) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: marker.path)  // in use
                return try load(dir)
            }
            return try compileAtomically(dir, key: key, load: load)
        }
    }

    /// True when `m`'s compiled form exists (prepared at install or by an earlier load).
    public nonisolated func isPrepared(_ m: SafetyManifest) -> Bool {
        Self.compiledDirectory(m, cacheDirectory: cacheDirectory)
            .map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(Self.preparedMarker).path) } ?? false
    }

    public enum PrepareOutcome: Sendable, Equatable {
        case prepared(seconds: Double)
        case alreadyPrepared
        /// Missing/damaged files or a load error: nothing compiled; the gate fails closed at the next check anyway.
        case failed
    }

    private static func makeChecker(_ m: SafetyManifest, cacheDirectory: URL?) throws -> ChildSafetyCheck {
        try ChildSafetyCheck(manifest: ModelManifest(
            nudity: URL(fileURLWithPath: m.nudityPath), age: URL(fileURLWithPath: m.agePath),
            ageBins: URL(fileURLWithPath: m.ageBinsPath),
            nudity2: m.nudity2Path.map { URL(fileURLWithPath: $0) }, sha256: m.sha256), cacheDirectory: cacheDirectory)
    }

    private func loadChecker() -> Result<ChildSafetyCheck, MissingOutcome> {
        let current = manifestProvider()
        if let checker, current == loadedFrom { return .success(checker) }
        release()
        guard let m = current else { return .failure(MissingOutcome(sizeBytes: 0)) }
        do {
            let t0 = ContinuousClock.now
            // M9 review E2: never beside a `prepare` of the same folder, never from a torn or unmarked one.
            let c = try compiledDirectory(m).map { dir in
                try Self.loadCompiled(dir, key: Self.compiledKey(m)) { try Self.makeChecker(m, cacheDirectory: $0) }
            } ?? Self.makeChecker(m, cacheDirectory: nil)
            let d = ContinuousClock.now - t0
            lastLoadSeconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            checker = c
            loadedFrom = m
            return .success(c)
        } catch {
            // Not cached: a repair (re-download) makes the next check load the detectors again.
            return .failure(MissingOutcome(sizeBytes: m.sizeBytes))
        }
    }

    public final class InvocationTrace: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [MediaOutputKind: Int] = [:]
        public var count: Int { lock.withLock { counts.values.reduce(0, +) } }
        public func count(_ kind: MediaOutputKind) -> Int { lock.withLock { counts[kind, default: 0] } }
        func record(_ kind: MediaOutputKind) { lock.withLock { counts[kind, default: 0] += 1 } }
        public func reset() { lock.withLock { counts = [:] } }
    }
}

/// The fail-closed outcome as a `Result` failure (repair size from the manifest; 0 when nothing is installed).
struct MissingOutcome: Error {
    let sizeBytes: Int64
}

#if ANTICHAT_UI_TESTING
/// UI-testing seam only (M4.T03 step 4): `-ScriptedSafetyVerdict block|allow` forces the verdict so the UI
/// "blocked" state is tested with a forced verdict, never with content. Never compiled into Debug or Release.
/// M4.T04: the AT-285 runner suites (built with `-DANTICHAT_UI_TESTING` into their own scratch path by
/// tools/at/at-285-runner.sh) set it directly.
enum ForcedVerdictCheck {
    nonisolated(unsafe) static var current: GateOutcome? = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-ScriptedSafetyVerdict"), i + 1 < a.count else { return nil }
        return a[i + 1] == "block" ? .block : a[i + 1] == "allow" ? .allow : nil
    }()
}
#endif
