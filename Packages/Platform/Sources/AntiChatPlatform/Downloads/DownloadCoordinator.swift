// M2.T08 (R-204 AC2–AC4, R-220 AC3, NFR-D6; blueprint E §E.2.5): the one download queue. An actor that owns the
// `download` rows, runs at most `maxFiles` files at once (E.2.5: 2), each through a `TransferEngine` (4 lanes ×
// 64 MB), and commits every verified file into the content-addressed store (`BlobStore.commit`).
//   * jobs are keyed by sha256: a blob already in the store, or a file already queued, is never fetched twice
//     (R-204 AC7, NFR-D5; InstallQueue dedups across packs and modes on top of this);
//   * pause keeps the part and its bitmap; cancel deletes both; a relaunch resumes queued, running and
//     system-paused jobs from their bitmaps (`restore()`); a user pause stays paused;
//   * errors carry copy keys: `download.unavailable` (every source 404/410), `download.verifyFailed` (first
//     mismatch, re-fetching), `download.failed` (second mismatch), `download.pausedConnection` (connection retries
//     exhausted; DownloadPolicy backs off), `network.blockedByOfflineOnly`.
// Policy (preflight, path, backoff, wake, power, order) is M2.T09's `DownloadPolicy`, which drives this actor.
import AntiChatFoundation
import AntiChatStorage
import Foundation

public actor DownloadCoordinator {
    public enum Event: Sendable, Equatable {
        case progress(id: String, bytesDone: Int64, total: Int64)
        case state(DownloadJob)
    }

    public nonisolated let models: ModelsDirectory
    public nonisolated let blobs: BlobStore
    public nonisolated let config: TransferConfig
    public nonisolated let maxFiles: Int
    private let database: AppDatabase?
    private let makeSession: TransferEngine.SessionFactory
    private let onBytes: (@Sendable (Int) -> Void)?
    private let sleep: @Sendable (Double) async throws -> Void
    private nonisolated let observers = DownloadObservers()

    private var jobs: [String: DownloadJob] = [:]
    private var running: [String: (engine: TransferEngine, task: Task<Void, Never>)] = [:]
    private var waiters: [String: [CheckedContinuation<DownloadJob, Never>]] = [:]
    /// Resumed on the job's next state change (waitOutcome across a retry).
    private var changeWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var lastPersist: [String: Date] = [:]
    /// Tasks of paused or cancelled jobs still unwinding: a restart of the same file waits for them, so two engines
    /// never write one part.
    private var draining: [String: Task<Void, Never>] = [:]
    /// False = nothing new starts (the policy holds the queue: offline, disk short, low battery…).
    public private(set) var isHeld = false

    public init(models: ModelsDirectory, database: AppDatabase?, config: TransferConfig = .standard, maxFiles: Int = 2,
                makeSession: @escaping TransferEngine.SessionFactory = TransferEngine.gateSessions,
                onBytes: (@Sendable (Int) -> Void)? = nil,
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.models = models
        blobs = BlobStore(models: models)
        self.database = database
        self.config = config
        self.maxFiles = max(1, maxFiles)
        self.makeSession = makeSession
        self.onBytes = onBytes
        self.sleep = sleep
    }

    // MARK: Observation

    @discardableResult
    public nonisolated func observe(_ f: @escaping @Sendable (Event) -> Void) -> UUID { observers.add(f) }
    public nonisolated func removeObserver(_ id: UUID) { observers.remove(id) }

    // MARK: Reads

    public func job(_ id: String) -> DownloadJob? { jobs[id] }
    public var allJobs: [DownloadJob] { jobs.values.sorted { ($0.request.priority, $0.createdAt) < ($1.request.priority, $1.createdAt) } }
    public func job(sha256: String) -> DownloadJob? { jobs.values.first { $0.sha256 == sha256 && $0.state != .cancelled } }
    /// The sha256 of every job not yet done, failed for good or cancelled (GC keeps their parts, T10).
    public var activeSHA256s: Set<String> { Set(jobs.values.filter { !$0.state.isTerminal || $0.state == .failed }.map(\.sha256)) }

    /// What a GC sweep must keep on top of the installs and slots (M2 review #1/#2): every open job (`activeSHA256s`)
    /// and every verified (`done`) file whose model has no install view yet — file 1 of 2 of a model, or an update
    /// waiting for its flip. `releasing` = model ids being removed: their done files may go. A done job without a
    /// model id is kept (nothing says it is unused).
    public func retainedSHA256s(releasing: Set<String> = []) -> Set<String> {
        var out = activeSHA256s
        for j in jobs.values where j.state == .done {
            if let id = j.request.modelID {
                if releasing.contains(id) { continue }
                if FileManager.default.fileExists(atPath: models.install(id).appending(path: "manifest.json").path) { continue }
            }
            out.insert(j.sha256)
        }
        return out
    }

    // MARK: Queue

    /// Queues one file. Returns the existing job when the same sha256 is already queued or running, and a `done` job
    /// (nothing fetched) when the blob is already in the store.
    @discardableResult
    public func enqueue(_ request: DownloadRequest) -> DownloadJob {
        if blobs.contains(request.sha256) {
            if let j = job(sha256: request.sha256), j.state == .done { return j }
            return DownloadJob(id: "present-\(request.sha256)", request: request, state: .done, pauseReason: nil,
                               bytesDone: request.size, retries: 0, errorKey: nil, createdAt: Date())
        }
        if var j = job(sha256: request.sha256) {
            if j.request.priority > request.priority { j.request.priority = request.priority }
            if j.state == .failed || j.state == .done {
                j.state = .queued
                j.errorKey = nil
            }
            update(j)
            pump()
            return j
        }
        let j = DownloadJob(id: StorageID.make(), request: request, state: .queued, pauseReason: nil, bytesDone: 0, retries: 0,
                            errorKey: nil, createdAt: Date())
        update(j)
        pump()
        return j
    }

    /// Queues every file of `model` (catalog order) for `pack`.
    @discardableResult
    public func enqueue(model: CatalogModel, pack: String, priority: Int = 0) -> [DownloadJob] {
        model.files.map { enqueue(DownloadRequest(file: $0, model: model, pack: pack, priority: priority)) }
    }

    /// Relaunch: reloads the `download` rows; queued, running, verifying and system-paused jobs go back in the queue
    /// and resume from their bitmaps. User-paused jobs stay paused.
    public func restore() throws {
        guard let database else { return }
        let rows = try database.read { try DownloadRecord.fetchAll($0) }
        for r in rows {
            var j = DownloadJob(record: r)
            guard jobs[j.id] == nil else { continue }
            switch j.state {
            case .running, .verifying, .queued: j.state = .queued
            case .paused where j.pauseReason != .user: j.state = .queued; j.pauseReason = nil
            default: break
            }
            if j.state == .queued, blobs.contains(j.sha256) { j.state = .done; j.bytesDone = j.bytesTotal }
            if let b = ChunkBitmap.load(models.bitmap(j.sha256)) { j.bytesDone = b.bytesDone }
            jobs[j.id] = j
            persist(j, force: true)
        }
        pump()
    }

    public func pause(_ id: String, reason: DownloadJob.PauseReason = .user) {
        guard var j = jobs[id], !j.state.isTerminal, j.state != .paused || reason == .user else { return }
        stopRunning(id)
        j.state = .paused
        j.pauseReason = reason
        update(j)
        pump()
    }

    public func resume(_ id: String) {
        guard var j = jobs[id], j.state == .paused || j.state == .failed else { return }
        j.state = .queued
        j.pauseReason = nil
        j.errorKey = nil
        update(j)
        pump()
    }

    /// M8.T10 Remove everything: cancels every open job.
    public func cancelAll() {
        for id in jobs.keys.sorted() { cancel(id) }
    }

    /// Cancels and deletes the part and its bitmap.
    public func cancel(_ id: String) {
        guard var j = jobs[id], j.state != .done, j.state != .cancelled else { return }
        stopRunning(id)
        try? FileManager.default.removeItem(at: models.part(j.sha256))
        try? FileManager.default.removeItem(at: models.bitmap(j.sha256))
        j.state = .cancelled
        j.bytesDone = 0
        update(j)
        pump()
    }

    /// Holds the queue (running jobs pause with reason `system`) or releases it (system-paused jobs resume).
    public func setHeld(_ held: Bool) {
        guard held != isHeld else { return pump() }
        isHeld = held
        if held {
            for id in running.keys { pause(id, reason: .system) }
        } else {
            for j in jobs.values where j.state == .paused && j.pauseReason == .system { resume(j.id) }
        }
        pump()
    }

    /// Waits until the job reaches done, failed or cancelled (or is paused, when `orPaused`).
    public func wait(_ id: String, orPaused: Bool = false) async -> DownloadJob? {
        guard let j = jobs[id] else { return nil }
        if j.state.isTerminal || (orPaused && j.state == .paused) { return j }
        let key = orPaused ? "p:" + id : id
        return await withCheckedContinuation { waiters[key, default: []].append($0) }
    }

    /// Error keys DownloadPolicy backs off and retries (connection trouble). Every other failure is final:
    /// `download.unavailable` (every source 404/410) and `download.failed` (second mismatch) — M2 review #8.
    public static let retryableErrors: Set<String> = ["download.pausedConnection"]

    /// Waits for the job's outcome across the policy's retries (M2 review #4): a `failed` job whose error key the
    /// policy retries is waited on again; returns done, cancelled or failed for good.
    public func waitOutcome(_ id: String, retrying: Set<String> = DownloadCoordinator.retryableErrors) async -> DownloadJob? {
        while true {
            guard let j = jobs[id] else { return nil }
            if j.state == .failed, let k = j.errorKey, retrying.contains(k) {
                await withCheckedContinuation { changeWaiters[id, default: []].append($0) }
                continue
            }
            if j.state.isTerminal { return j }
            _ = await wait(id)
        }
    }

    /// Waits until every job is terminal or paused.
    public func waitForIdle() async {
        while let j = jobs.values.first(where: { !$0.state.isTerminal && $0.state != .paused }) {
            _ = await wait(j.id, orPaused: true)
        }
    }

    // MARK: Running

    private func stopRunning(_ id: String) {
        guard let r = running.removeValue(forKey: id), let sha = jobs[id]?.sha256 else { return }
        r.engine.pause()
        r.task.cancel()
        draining[sha] = r.task
    }

    private func pump() {
        guard !isHeld else { return }
        let queued = jobs.values.filter { $0.state == .queued }
            .sorted { ($0.request.priority, $0.createdAt, $0.id) < ($1.request.priority, $1.createdAt, $1.id) }
        for j in queued where running.count < maxFiles { start(j) }
    }

    private func start(_ job: DownloadJob) {
        var j = job
        j.state = .running
        update(j)
        let engine = TransferEngine(models: models, config: config, makeSession: makeSession, onBytes: onBytes, sleep: sleep)
        let id = j.id
        let request = j.request
        let prior = draining.removeValue(forKey: j.sha256)
        let task = Task.detached { [weak self] in
            await prior?.value
            let weakSelf = WeakCoordinator(self)
            do {
                let part = try await engine.download(request, progress: { bytes in
                    Task { await weakSelf.value?.progress(id, bytes, engine) }
                }, phase: { p in
                    Task { await weakSelf.value?.phase(id, p, engine) }
                })
                try await weakSelf.value?.commit(id, part: part, engine)
            } catch {
                await weakSelf.value?.failed(id, error, engine)
            }
        }
        running[id] = (engine, task)
    }

    private func progress(_ id: String, _ bytes: Int64, _ engine: TransferEngine) {
        guard running[id]?.engine === engine, var j = jobs[id], j.state == .running || j.state == .verifying else { return }
        j.bytesDone = bytes
        jobs[id] = j
        observers.send(.progress(id: id, bytesDone: bytes, total: j.bytesTotal))
        persist(j, force: false)
    }

    private func phase(_ id: String, _ p: TransferPhase, _ engine: TransferEngine) {
        guard var j = jobs[id], running[id]?.engine === engine else { return }
        switch p {
        case .verifying: j.state = .verifying
        case .transferring: j.state = .running
        case .refetching:
            j.state = .running
            j.errorKey = "download.verifyFailed"
            j.bytesDone = 0
        }
        update(j)
    }

    private func commit(_ id: String, part: URL, _ engine: TransferEngine) throws {
        guard var j = jobs[id], running[id]?.engine === engine else { return }
        try blobs.commit(partial: part, sha256: j.sha256)
        running[id] = nil
        j.state = .done
        j.bytesDone = j.bytesTotal
        j.errorKey = nil
        j.pauseReason = nil
        update(j)
        pump()
    }

    private func failed(_ id: String, _ error: any Error, _ engine: TransferEngine) {
        // Only the engine that is current for the job: a paused or cancelled one (or its predecessor) is ignored.
        guard var j = jobs[id], running[id]?.engine === engine else { return }
        running[id] = nil
        switch error {
        case TransferError.paused:
            j.state = .paused
            j.pauseReason = j.pauseReason ?? .system
        case TransferError.blocked:
            j.state = .paused
            j.pauseReason = .system
            j.errorKey = "network.blockedByOfflineOnly"
        case TransferError.unavailable:
            j.state = .failed
            j.errorKey = "download.unavailable"
            j.retries += 1
        case TransferError.checksum:
            j.state = .failed
            j.errorKey = "download.failed"
            j.retries += 1
        default:
            // Connection-type failure after the per-chunk retries: DownloadPolicy backs off and retries (R-204 AC5).
            j.state = .failed
            j.errorKey = "download.pausedConnection"
            j.retries += 1
        }
        AppLog.log(.download, .error, "download \(j.sha256.prefix(12)): \(j.state.rawValue) (\(error))")
        update(j)
        pump()
    }

    private func update(_ j: DownloadJob) {
        let old = jobs[j.id]
        jobs[j.id] = j
        if old?.state != j.state || old?.errorKey != j.errorKey || old?.pauseReason != j.pauseReason || old?.request.priority != j.request.priority {
            persist(j, force: true)
            observers.send(.state(j))
        }
        if j.state.isTerminal, let ws = waiters.removeValue(forKey: j.id) { ws.forEach { $0.resume(returning: j) } }
        if old?.state != j.state, let ws = changeWaiters.removeValue(forKey: j.id) { ws.forEach { $0.resume() } }
        if j.state.isTerminal || j.state == .paused, let ws = waiters.removeValue(forKey: "p:" + j.id) {
            ws.forEach { $0.resume(returning: j) }
        }
    }

    private func persist(_ j: DownloadJob, force: Bool) {
        guard let database else { return }
        let now = Date()
        if !force, let last = lastPersist[j.id], now.timeIntervalSince(last) < 1 { return }
        lastPersist[j.id] = now
        let map = ChunkBitmap.load(models.bitmap(j.sha256)).map { String(decoding: $0.encoded(), as: UTF8.self) }
        let rec = j.record(chunkMap: map)
        do { try database.write { try rec.save($0) } } catch {
            AppLog.log(.download, .error, "download: persisting \(j.id) failed: \(error)")
        }
    }
}

struct WeakCoordinator: Sendable {
    weak var value: DownloadCoordinator?
    init(_ v: DownloadCoordinator?) { value = v }
}

/// Lock-guarded observer list (called from the actor; observers must not block).
final class DownloadObservers: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [UUID: @Sendable (DownloadCoordinator.Event) -> Void] = [:]
    func add(_ f: @escaping @Sendable (DownloadCoordinator.Event) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = f }
        return id
    }
    func remove(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }
    func send(_ e: DownloadCoordinator.Event) { for f in lock.withLock({ Array(observers.values) }) { f(e) } }
}
