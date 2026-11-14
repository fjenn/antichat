// M4.T04 (R-291; P-media-10 design port of osaurus `MediaJobStore` to GRDB and Atomic-Chat `lost-job.ts` engine-instance
// semantics): the app side of the durable media job queue and the sole writer of `media_job` rows.
//   * enqueue → a `queued` row with its `position`; at most ONE job is `running` (submitted to the helper) at a time
//     (R-291 AC1); the others wait and show `job.waitingPosition`. Positions recompute on every state change
//     (0 = running, 1… = waiting in order; NULL once finished).
//   * The helper stamps the job with its launch's `engineInstanceID`; a `running` row of another instance is `lost`
//     (`job.interrupted` · [Restart]) — at app launch (RecoveryRepository sweep) and, without a relaunch, when the helper
//     dies mid-job (the stream ends with `engine.restarted` and no job terminal) or reconnects as a new instance.
//   * Restart re-enqueues the same spec as a new job id; the old row stays `lost`.
//   * Terminal events map to rows: result → `done`; `jobBlocked` → `blocked` and `local_counter.child_safety_blocks`
//     += 1 (the only record of a block, D-006); `safetyMissing` → `failed`/`safety.missing`; cancel → `cancelled`.
//   * `hasRunning` (synchronous snapshot) feeds the quit prompt (AppDelegate). Closing a window never stops a job.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import GRDB
import Synchronization

/// How the queue reaches the helper (EngineClient / EngineSupervisorClient; fakes in tests).
public protocol MediaJobTransport: Sendable {
    /// Connects if needed; the helper launch's instance id (`HelloAck.engineInstanceID`).
    func engineInstanceID() async throws -> String
    func submit(_ job: MediaJobSubmit) -> AsyncStream<EngineBatch>
    func cancel(_ requestID: UUID)
    /// M5.T11: a control message for the running job of stream `requestID` ([Resume] on a paused video).
    func control(_ requestID: UUID, _ action: MediaJobControl.Action)
}

public extension MediaJobTransport {
    func control(_ requestID: UUID, _ action: MediaJobControl.Action) {}
}

extension EngineClient: MediaJobTransport {
    public func engineInstanceID() async throws -> String { try await ensureConnected().engineInstanceID }
    public func submit(_ job: MediaJobSubmit) -> AsyncStream<EngineBatch> { batches(job.requestID, sending: .mediaJob(job)) }
    public func control(_ requestID: UUID, _ action: MediaJobControl.Action) {
        mediaJobControl(MediaJobControl(requestID: requestID, action: action))
    }
}

extension EngineSupervisorClient: MediaJobTransport {
    public func engineInstanceID() async throws -> String { try await ensureConnected().engineInstanceID }
    public func submit(_ job: MediaJobSubmit) -> AsyncStream<EngineBatch> { current.submit(job) }
    public func control(_ requestID: UUID, _ action: MediaJobControl.Action) { current.control(requestID, action) }
}

public actor MediaJobQueue {
    /// What the UI observes for one job (the card: waiting position, progress, preview, result, terminal state).
    public struct Update: Sendable, Equatable {
        public var job: String
        public var state: MediaJobState
        public var position: Int?
        public var progress: Double
        public var previewPath: String?
        public var resultPath: String?
        public var errorCode: String?
        /// M5.T11: a video job's stage, preview set and pause state (nil for picture jobs / before its first event).
        public var video: VideoJobStatus?

        public init(job: String, state: MediaJobState, position: Int?, progress: Double, previewPath: String?, resultPath: String?,
                    errorCode: String?, video: VideoJobStatus? = nil) {
            self.job = job; self.state = state; self.position = position; self.progress = progress
            self.previewPath = previewPath; self.resultPath = resultPath; self.errorCode = errorCode; self.video = video
        }
    }

    public static let safetyMissingCode = "safety.missing"
    /// The helper never acknowledged the job (`jobStarted`) within `startTimeout`: the job fails with this code
    /// (the card shows the error with Retry) instead of sitting at 0 % forever (M4.T16 real-model journey 5).
    public static let notStartedCode = "job.notStarted"

    private let database: AppDatabase
    private let transport: any MediaJobTransport
    private let safety: @Sendable () async -> SafetyManifest?
    private let xferRoot: URL
    private let now: @Sendable () -> Date
    /// Upper bound from submit to the helper's `jobStarted` (the helper answers it before any model load).
    private let startTimeout: Duration
    private var runningJob: (id: String, requestID: UUID)?
    private var cancelRequested: Set<String> = []
    private var pumpTask: Task<Void, Never>?
    private let (updateStream, updateCont) = AsyncStream<Update>.makeStream(bufferingPolicy: .unbounded)
    private let running = Mutex(false)
    /// Callers of `finished(_:)` waiting for a job's terminal state.
    private var waiters: [String: [CheckedContinuation<Update, Never>]] = [:]

    private static let sharedQueue = Mutex<MediaJobQueue?>(nil)
    /// The process's queue (set by the app at launch; the quit prompt reads it).
    public static var shared: MediaJobQueue? {
        get { sharedQueue.withLock { $0 } }
        set { sharedQueue.withLock { $0 = newValue } }
    }

    /// `xferRoot` = `~/Library/Caches/AntiChat/xfer` (each job: `<root>/<job>/`, previews + result before they move to Media/).
    public init(database: AppDatabase, transport: any MediaJobTransport, xferRoot: URL,
                safety: @escaping @Sendable () async -> SafetyManifest?, now: @escaping @Sendable () -> Date = { Date() },
                parent: ObjectIdentifier? = nil, startTimeout: Duration = .seconds(60)) {
        self.init(database: database, transport: transport, xferRoot: xferRoot, safety: safety, now: now, parent: parent,
                  startTimeout: startTimeout, slot: MediaJobSlot())
    }

    private init(database: AppDatabase, transport: any MediaJobTransport, xferRoot: URL,
                 safety: @escaping @Sendable () async -> SafetyManifest?, now: @escaping @Sendable () -> Date,
                 parent: ObjectIdentifier?, startTimeout: Duration, slot: MediaJobSlot) {
        self.slot = slot
        self.startTimeout = startTimeout
        self.database = database
        self.transport = transport
        self.xferRoot = xferRoot
        self.safety = safety
        self.now = now
        self.parent = parent
    }

    public static func defaultXferRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/AntiChat/xfer")
    }

    // MARK: - Incognito queues (M5.T14 review P1-1)

    /// An incognito session's own queue: its in-memory database (no `media_job` row on disk, the prompt never persists),
    /// its temp dir as the xfer root (the helper writes the gated files there), the same helper transport and detectors.
    public nonisolated func ephemeral(database: AppDatabase, xferRoot: URL) -> MediaJobQueue {
        MediaJobQueue(database: database, transport: transport, xferRoot: xferRoot, safety: safety, now: now,
                      parent: ObjectIdentifier(self), startTimeout: startTimeout, slot: slot)
    }

    /// M5 review P2-3 / M4 review P2-1: the one running-job slot this queue shares with its parent and every queue
    /// derived from it (one helper, one heavy job at a time app-wide). A queue whose next job waits for another
    /// queue's job keeps it `queued` (the card shows waiting) and submits only once it holds the slot, so the
    /// helper never queues a second job and the start watchdog counts from the real submission.
    private nonisolated let slot: MediaJobSlot

    /// The slot was freed by another queue: start this queue's next job if it is this queue's turn.
    fileprivate func slotFreed() { pump() }

    /// The queue this one was derived from (`ephemeral`), nil for an app queue.
    private nonisolated let parent: ObjectIdentifier?

    /// The registered incognito queues derived from this one (the quit prompt and Quit anyway cover them).
    private nonisolated var derived: [MediaJobQueue] {
        let me = ObjectIdentifier(self)
        return Self.ephemeralQueues.withLock { $0.values.filter { $0.parent == me } }
    }

    private static let ephemeralQueues = Mutex<[ObjectIdentifier: MediaJobQueue]>([:])

    /// A store an incognito session owns (weakly held: an identifier reused after the store is gone never matches).
    private struct IncognitoStore: @unchecked Sendable { weak var database: AppDatabase? }
    private static let incognitoStores = Mutex<[ObjectIdentifier: IncognitoStore]>([:])

    /// Marks `database` as an incognito session's store for its whole life (also after the session closed): its media
    /// tool calls never reach the app's persistent queue. `IncognitoSession` marks its store before anything runs.
    public static func markIncognito(_ database: AppDatabase) {
        incognitoStores.withLock { map in
            map = map.filter { $0.value.database != nil }
            map[ObjectIdentifier(database)] = IncognitoStore(database: database)
        }
    }

    /// Whether `database` is an incognito session's store (decided by the session, not by the store being in memory:
    /// Normal chats may use in-memory stores, e.g. in tests).
    public static func isIncognito(_ database: AppDatabase) -> Bool {
        incognitoStores.withLock { $0[ObjectIdentifier(database)]?.database === database }
    }

    /// Registers an incognito session's queue for its store (the media tools pick it for calls of that store).
    public static func register(_ queue: MediaJobQueue, for database: AppDatabase) {
        markIncognito(database)
        ephemeralQueues.withLock { $0[ObjectIdentifier(database)] = queue }
    }

    public static func unregister(database: AppDatabase) {
        _ = ephemeralQueues.withLock { $0.removeValue(forKey: ObjectIdentifier(database)) }
    }

    /// The queue a media tool call of `database` uses: the app's queue for a Normal chat's store (or no turn store);
    /// the session's own queue for an incognito session's store, and none when that session has no queue (closed, or
    /// none was derived: fail closed, never the persistent queue).
    public static func serving(_ database: AppDatabase?, app: MediaJobQueue) -> MediaJobQueue? {
        guard let database, isIncognito(database) else { return app }
        return ephemeralQueues.withLock { $0[ObjectIdentifier(database)] }
    }

    /// Every queue of this process (the app's first): the job cards find their call's job in any of them.
    public static var all: [MediaJobQueue] {
        (shared.map { [$0] } ?? []) + ephemeralQueues.withLock { Array($0.values) }
    }

    private static let jobless = Mutex<[String: String]>([:])
    /// R-285 AC6 (Q-015 r5): a call that ended without queueing a job (missing detectors) records its result here, so
    /// its card, which waits for the call's job, settles at once instead of waiting for the attach bound.
    public static func endedWithoutJob(call callID: String?, resultJSON: String) {
        guard let callID else { return }
        jobless.withLock { $0[callID] = resultJSON }
    }
    /// The result of call `callID` when it ended without a job (nil = it has or may still get one).
    public static func joblessResult(forCall callID: String) -> String? { jobless.withLock { $0[callID] } }

    /// The queue holding the job of tool call `callID`, and that job (nil = none in this process).
    public static func job(forCall callID: String) async -> (queue: MediaJobQueue, job: String)? {
        for q in all { if let j = await q.job(forCall: callID) { return (q, j) } }
        return nil
    }

    // MARK: - Stored results (M5.T14 review P1-2; the job files rules: see Job files)

    /// The tool stored the gated result as an artifact (`path`): observers get the stored path and the job's xfer
    /// files go (no duplicate left in the cache; a Library delete removes the only copy).
    public func resultStored(_ id: String, at path: String) {
        lastResult[id] = path
        publish(id, resultPath: path)
        removeFiles(id)
    }

    public nonisolated var updates: AsyncStream<Update> { updateStream }

    /// M4.T08: a stream of its own per observer (each job card), so cards never take updates from each other.
    public func subscribe() -> AsyncStream<Update> {
        let (stream, cont) = AsyncStream<Update>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let key = UUID()
        subscribers[key] = cont
        cont.onTermination = { [weak self] _ in Task { await self?.unsubscribe(key) } }
        return stream
    }

    private var subscribers: [UUID: AsyncStream<Update>.Continuation] = [:]
    private func unsubscribe(_ key: UUID) { subscribers[key] = nil }
    /// Synchronous snapshot for `applicationShouldTerminate` (its incognito session queues included, M4 review P1-3).
    public nonisolated var hasRunning: Bool { running.withLock { $0 } || derived.contains { $0.hasRunning } }
    /// M5.T11 (NFR-VID3): a video job runs — the app stays open after its last window closes (incognito ones included).
    public nonisolated var hasRunningVideo: Bool { runningVideo.withLock { $0 } || derived.contains { $0.hasRunningVideo } }
    private let runningVideo = Mutex(false)
    /// M5.T11: the running / last video job's status (the card's re-attach snapshot).
    private var videoStatus: [String: VideoJobStatus] = [:]

    /// M9.T05 (NFR-B5): the helper's GPU-yield notes (`gpuYield` on a change, `gpuYieldHold` while paused,
    /// `gpuYieldBusy` while another process holds ≥ 30 %, `gpuYieldMode` = the job's summary) into the app's
    /// diagnostics log and the perf log, so a pause that never ends (or never comes) names the process.
    nonisolated static func logGPUYield(_ n: SchedulerNote, job: String) {
        let d = n.detail
        AppLog.log(.media, n.action == "gpuYield" ? .notice : .info,
                   "\(n.action) job=\(job) yielding=\(d["yielding"] ?? "-") busiest=\(d["process"].flatMap { $0.isEmpty ? nil : $0 } ?? "-") "
                   + "share=\(d["share"] ?? "-") quiet_s=\(d["quiet_s"] ?? "-") mode=\(d["mode"] ?? "-") "
                   + "peak=\(d["peak_process"].flatMap { $0.isEmpty ? nil : $0 } ?? "-")@\(d["peak_share"] ?? "-")")
        var meta = d
        meta["action"] = n.action
        meta["job"] = job
        Signposts.event(.gpuYield, on: Signposts.harness, meta: meta)
    }

    /// [Resume] on a paused video job (thermal critical; the helper's governor resumes it).
    public func resume(_ id: String) {
        guard let r = runningJob, r.id == id else { return }
        transport.control(r.requestID, .resume)
    }

    // MARK: - Enqueue / cancel / restart

    /// Queues a job (the spec is the image request; its `outputPath` is set to the job's xfer dir when empty).
    @discardableResult
    /// `maskPNG` (M4 review P1-5): an input the job owns (Erase's brush mask), kept in the job's dir as
    /// `input-mask.png` — so a restart of a lost job still has it — and deleted with the job.
    public func enqueue(chatID: String, messageID: String? = nil, kind: MediaJobKind = .image, image: ImageRequest,
                        callID: String? = nil, maskPNG: Data? = nil) throws -> String {
        try refuseIfClosed()
        let id = StorageID.make()
        if let callID { jobsByCall[callID] = id }
        var spec = image
        spec.safety = nil
        if spec.outputPath.isEmpty { spec.outputPath = xferRoot.appendingPathComponent(id).appendingPathComponent("result.png").path }
        if let maskPNG {
            let dir = jobDir(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(Self.inputPrefix + "mask.png")
            try maskPNG.write(to: url, options: .atomic)
            spec.maskImagePath = url.path
        }
        let json = String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
        try database.write { db in
            let next = (try Int.fetchOne(db, sql: "SELECT MAX(position) FROM media_job WHERE state IN ('queued', 'running')") ?? 0) + 1
            try MediaJobRecord(id: id, chatID: chatID, messageID: messageID, kind: kind.rawValue, specJSON: json, createdAt: now(),
                               position: next).insert(db)
        }
        try renumber()
        pump()
        return id
    }

    /// M5.T10: queues a video job (the same durable queue, one heavy job at a time, the same helper runner and gate).
    /// The spec is the `VideoRequest`; its `outputPath` is set to `<xfer>/<job>/result.mp4` when empty (the poster
    /// lands beside it as `result.poster.jpg`, written by the helper only after the gate allowed the clip).
    @discardableResult
    public func enqueue(chatID: String, messageID: String? = nil, video: VideoRequest, callID: String? = nil) throws -> String {
        try refuseIfClosed()
        let id = StorageID.make()
        if let callID { jobsByCall[callID] = id }
        var spec = video
        spec.safety = nil
        spec.previewDir = nil
        if spec.outputPath.isEmpty { spec.outputPath = xferRoot.appendingPathComponent(id).appendingPathComponent("result.mp4").path }
        if spec.scratchDir.isEmpty { spec.scratchDir = xferRoot.appendingPathComponent(id).path }
        let json = String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
        try database.write { db in
            let next = (try Int.fetchOne(db, sql: "SELECT MAX(position) FROM media_job WHERE state IN ('queued', 'running')") ?? 0) + 1
            try MediaJobRecord(id: id, chatID: chatID, messageID: messageID, kind: MediaJobKind.video.rawValue, specJSON: json,
                               createdAt: now(), position: next).insert(db)
        }
        try renumber()
        pump()
        return id
    }

    /// Cancels a waiting job at once, or asks the helper to stop the running one (→ `cancelled` on its terminal).
    public func cancel(_ id: String) throws {
        if let r = runningJob, r.id == id {
            cancelRequested.insert(id)
            transport.cancel(r.requestID)
            return
        }
        try finish(id, state: .cancelled, only: [.queued])
        pump()
    }

    /// Quit prompt "Quit anyway": cancel the running job and every waiting one.
    public func cancelAll() throws {
        let waiting = try database.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM media_job WHERE state = 'queued'")
        }
        for id in waiting { try finish(id, state: .cancelled, only: [.queued]) }
        if let r = runningJob { try cancel(r.id) }
    }

    /// Quit prompt "Quit anyway" (M4.T04 step 6): everything is cancelled and the running row is written `cancelled`
    /// now, since the app exits before the helper's terminal arrives (else the launch sweep would read it `lost`).
    public func cancelForQuit() throws {
        for q in derived { Task { try? await q.cancelForQuit() } }
        let r = runningJob
        try cancelAll()
        if let r {
            try database.write { db in
                try db.execute(sql: "UPDATE media_job SET state = 'cancelled', position = NULL, finished_at = ? WHERE id = ? AND state = 'running'",
                               arguments: [now().timeIntervalSince1970, r.id])
            }
            publish(r.id)
        }
    }

    /// `job.restart`: the same spec as a new job (the old row stays as it is).
    @discardableResult
    /// The newest `lost` picture job of reply `messageID` (R-291 AC2: the card's Restart after a quit, crash or helper
    /// exit, when this process never saw the job). nil = none.
    public func lostJob(messageID: String) throws -> String? {
        try database.read { db in
            try String.fetchOne(db, sql: """
                SELECT id FROM media_job WHERE message_id = ? AND state = 'lost' AND kind IN ('image', 'edit')
                ORDER BY created_at DESC LIMIT 1
                """, arguments: [messageID])
        }
    }

    /// The queue (of this process's queues) holding a lost picture job of `messageID`, and that job.
    public static func lostJob(messageID: String) async -> (queue: MediaJobQueue, job: String)? {
        for q in all { if let j = try? await q.lostJob(messageID: messageID) { return (q, j) } }
        return nil
    }

    /// The store this queue writes (the restarted call saves its picture there).
    public nonisolated var store: AppDatabase { database }

    /// R-291 AC2 [Restart]: the same request as a new job; `callID` (the card's key) attaches the card to it.
    public func restart(_ id: String, callID: String?) throws -> String {
        let new = try restart(id)
        if let callID { jobsByCall[callID] = new }
        return new
    }

    public func restart(_ id: String) throws -> String {
        guard let row = try database.read({ db in try MediaJobRecord.fetchOne(db, key: id) }) else {
            throw AntiChatError.engine("noSuchJob", id)
        }
        if row.kind == MediaJobKind.video.rawValue {
            var v = try JSONDecoder().decode(VideoRequest.self, from: Data(row.specJSON.utf8))
            v.requestID = UUID()
            v.outputPath = ""
            v.scratchDir = ""
            let new = try enqueue(chatID: row.chatID, messageID: row.messageID, video: v)
            removeFiles(id)  // the old job's dir goes (as for pictures)
            return new
        }
        var spec = try JSONDecoder().decode(ImageRequest.self, from: Data(row.specJSON.utf8))
        spec.requestID = UUID()
        spec.outputPath = ""
        // Inputs the old job owned (Erase mask) move to the new job; the old job's dir goes. M4 review P2-6: a lost job's
        // inputs last only until the next launch's sweep; a restart after that has nothing to erase with and refuses.
        let ownsMask = spec.maskImagePath.map { $0.hasPrefix(jobDir(id).path) } ?? false
        let oldMask = ownsMask ? spec.maskImagePath.flatMap { FileManager.default.contents(atPath: $0) } : nil
        if ownsMask, oldMask == nil { throw AntiChatError.engine("inputGone", id) }
        if oldMask != nil { spec.maskImagePath = nil }
        let new = try enqueue(chatID: row.chatID, messageID: row.messageID, kind: MediaJobKind(rawValue: row.kind) ?? .image,
                              image: spec, maskPNG: oldMask)
        removeFiles(id)
        return new
    }

    /// R-291 AC2: `running` rows not stamped with the current helper launch are `lost` (never resubmitted).
    @discardableResult
    public func reconcile(engineInstanceID current: String) throws -> [String] {
        let lost = try database.write { db -> [String] in
            let ids = try String.fetchAll(db, sql: """
                SELECT id FROM media_job WHERE state = 'running' AND (engine_instance_id IS NULL OR engine_instance_id != ?)
                """, arguments: [current])
            for id in ids where id != runningJob?.id {
                try db.execute(sql: "UPDATE media_job SET state = 'lost', position = NULL, finished_at = ? WHERE id = ?",
                               arguments: [now().timeIntervalSince1970, id])
            }
            return ids.filter { $0 != runningJob?.id }
        }
        for id in lost { publish(id) }
        try renumber()
        pump()
        return lost
    }

    public func positions() throws -> [String: Int] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, position FROM media_job WHERE position IS NOT NULL")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as String, $0["position"] as Int) })
        }
    }

    public func row(_ id: String) throws -> MediaJobRecord? { try database.read { db in try MediaJobRecord.fetchOne(db, key: id) } }

    /// Waits for `id` to leave `queued`/`running` (the tool call of a turn waits for its job).
    /// M4 review P1-2: cancelling the waiting task (the turn was stopped, the incognito session closed) cancels the job;
    /// the wait still ends with the job's terminal state (`cancelled`, or a result that raced the cancel and is then
    /// discarded by the caller, which checks `Task.isCancelled`).
    public func finished(_ id: String) async -> Update {
        if let r = try? row(id), ![MediaJobState.queued, .running].contains(r.state) {
            return Update(job: id, state: r.state, position: r.position, progress: r.progress, previewPath: nil,
                          resultPath: r.state == .done ? lastResult[id] : nil, errorCode: r.errorCode)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiters[id, default: []].append($0) }
        } onCancel: {
            Task { try? await self.cancel(id) }
        }
    }

    // MARK: - Close (M4 review P1-2)

    /// The queue's session ended (an incognito chat closed): no new job, every job is cancelled, and once the running one
    /// has ended its xfer root (the session's temp dir) is removed, so a late helper write leaves nothing behind.
    public private(set) var isClosed = false

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        try? cancelAll()
        // The shared slot (M5 review P2-3): a closed queue leaves the line at once; if its job still runs, `ended`
        // releases the slot when that job's terminal arrives (never later), and `pump` never takes it again.
        if runningJob == nil {
            slot.withdraw(self)
            removeRoot()
        }
    }

    private func refuseIfClosed() throws {
        if isClosed { throw AntiChatError.engine("queueClosed", "the session of this queue has ended") }
    }

    private func removeRoot() { try? FileManager.default.removeItem(at: xferRoot) }

    private var lastResult: [String: String] = [:]
    /// M4.T08: tool call id → its job (the card under that call's line finds its job).
    private var jobsByCall: [String: String] = [:]

    /// The job a tool call queued (nil = none in this process).
    public func job(forCall callID: String) -> String? { jobsByCall[callID] }

    /// The job's current state as an update (the card's first frame; nil = unknown job).
    public func snapshot(_ id: String) -> Update? {
        guard let r = try? row(id) else { return nil }
        return Update(job: id, state: r.state, position: r.position, progress: r.progress, previewPath: lastPreview[id],
                      resultPath: r.state == .done ? lastResult[id] : nil, errorCode: r.errorCode, video: videoStatus[id])
    }
    private var lastPreview: [String: String] = [:]

    /// Waits until nothing runs or waits (tests, quit).
    public func drain() async {
        while let t = pumpTask { await t.value }
    }

    // MARK: - Running

    /// Starts the next waiting job when none runs (one heavy GPU job at a time).
    private func pump() {
        guard runningJob == nil, pumpTask == nil else { return }
        guard !isClosed else {  // M4 review P1-2: a closed session's queue starts nothing and never holds the slot
            slot.withdraw(self)
            return
        }
        guard let next = try? database.read({ db in
            try MediaJobRecord.fetchOne(db, sql: "SELECT * FROM media_job WHERE state = 'queued' ORDER BY position, created_at LIMIT 1")
        }) else {
            slot.withdraw(self)  // nothing waits here any more: the turn passes on
            return
        }
        guard slot.acquire(self) else { return }  // another queue's job runs: this one waits (`slotFreed` re-pumps)
        let previewDir = xferRoot.appendingPathComponent(next.id).path
        let submit: MediaJobSubmit
        if next.kind == MediaJobKind.video.rawValue, var video = try? JSONDecoder().decode(VideoRequest.self, from: Data(next.specJSON.utf8)) {
            video.requestID = UUID()
            submit = MediaJobSubmit(job: next.id, video: video, previewDir: previewDir, safety: nil)
        } else if next.kind != MediaJobKind.video.rawValue,
                  var spec = try? JSONDecoder().decode(ImageRequest.self, from: Data(next.specJSON.utf8)) {
            spec.requestID = UUID()
            submit = MediaJobSubmit(job: next.id, kind: MediaJobKind(rawValue: next.kind) ?? .image, image: spec,
                                    previewDir: previewDir, safety: nil)
        } else {
            try? finish(next.id, state: .failed, code: "badSpec", only: [.queued])
            slot.release(self)
            pump()
            return
        }
        runningJob = (next.id, submit.requestID)
        running.withLock { $0 = true }
        runningVideo.withLock { $0 = submit.kind == .video }
        if submit.kind == .video { videoStatus[next.id] = VideoJobStatus() }
        pumpTask = Task { [weak self] in await self?.execute(submit) }
    }

    private func execute(_ job: MediaJobSubmit) async {
        var submit = job
        submit.safety = await safety()
        let id = submit.job
        let instance: String
        do {
            instance = try await transport.engineInstanceID()
        } catch {
            if cancelRequested.contains(id) { ended(id, state: .cancelled) } else {
                ended(id, state: .failed, code: (error as? AntiChatError)?.code ?? "engine")
            }
            return
        }
        // M5 review P2-2 / M4 review P2-2: a ■ pressed while the safety files and the helper were awaited ended
        // nowhere (the helper ignores a cancel for a request it has not seen): the job ends here, never sent.
        if cancelRequested.contains(id) {
            ended(id, state: .cancelled)
            return
        }
        do {
            try database.write { db in
                try db.execute(sql: """
                    UPDATE media_job SET state = 'running', started_at = ?, engine_instance_id = ? WHERE id = ? AND state = 'queued'
                    """, arguments: [now().timeIntervalSince1970, instance, id])
            }
            try renumber()
        } catch { AppLog.log(.harness, .error, "media job \(id): \(error)") }
        publish(id)
        // The stream is read in a child task so a helper that never acknowledges the job (no `jobStarted` within
        // `startTimeout`: it hangs, never got the message, or serves another build) cannot hold the job — and the
        // queue behind it — at 0 % forever: the read is abandoned, the helper is told to cancel, the job fails.
        let started = Mutex(false)
        let transport = transport
        let stream = transport.submit(submit)  // sent now, in order with the `running` row (as before the bound)
        // (`submit` registers the stream synchronously, so a ■ from here on reaches the helper through `cancel`.)
        let reader = Task { () -> (MediaJobEvent?, AntiChatError?) in
            var terminal: MediaJobEvent?
            var engineError: AntiChatError?
            for await batch in stream {
                for item in batch.items {
                    switch item {
                    case .media(.job(let e)) where e.job == id:
                        started.withLock { $0 = true }
                        if e.isTerminal { terminal = e } else { self.progressed(e) }
                    case .media(.imageResult(let r)) where submit.kind != .video:
                        // M9.T05 (AT-236 AC3): the helper's image.loadStart → image.final for this job, as an interval
                        // of the app's perf log (the helper's own perf log is off: launchd starts it without our env).
                        if let s = r.metrics["load_start_to_final_s"], s >= 0 {
                            // M9.T05: the helper's own split of the turn's non-generation time travels with the mark
                            // (its perf log is off), so the overhead can be broken down per run: step-aside unload,
                            // the low-tier generator stop and the final check (detector load included).
                            var meta = ["source": "queue", "job": id]
                            for k in ["image_load_s", "unload_s", "unload_call_s", "request_to_final_s", "sd_stop_before_check_s",
                                      "result_check_s", "detector_load_s", "first_check_s"] {
                                meta[k] = String(r.metrics[k] ?? -1)
                            }
                            Signposts.mark(.imageGen, durationNs: UInt64(s * 1e9), on: Signposts.harness, meta: meta)
                        }
                    case .media(let e) where submit.kind == .video:
                        // M5.T11: the helper's stage and governor notes for the card (P-media-10 fan-out); the helper
                        // is working on the job, so it counts as started.
                        started.withLock { $0 = true }
                        if case .scheduler(let n) = e, n.action.hasPrefix("gpuYield") { Self.logGPUYield(n, job: id) }
                        if self.videoStatus[id, default: VideoJobStatus()].apply(e) { self.publish(id) }
                    case .engine(.error(let err)):
                        engineError = err
                    default:
                        break
                    }
                }
            }
            return (terminal, engineError)
        }
        let limit = startTimeout
        let watchdog = Task { () -> Bool in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, !started.withLock({ $0 }) else { return false }
            reader.cancel()
            return true
        }
        let (terminal, engineError) = await reader.value
        watchdog.cancel()
        if await watchdog.value, terminal == nil {
            AppLog.log(.harness, .error, "media job \(id): the helper did not start it within \(limit); failing it")
            transport.cancel(submit.requestID)
            let cancelled = cancelRequested.contains(id)  // the user's ■ before the helper ever took the job
            ended(id, state: cancelled ? .cancelled : .failed, code: cancelled ? nil : Self.notStartedCode)
            return
        }
        switch terminal {
        case .jobResult(_, let path, _)?:
            // M5.T14 review P1-4: a cancel the user asked for wins over a result that raced it (the files go).
            if cancelRequested.contains(id) { ended(id, state: .cancelled) } else { ended(id, state: .done, resultPath: path) }
        case .jobBlocked?: ended(id, state: .blocked, countBlock: true)
        case .safetyMissing?: ended(id, state: .failed, code: Self.safetyMissingCode)
        case .jobCancelled?: ended(id, state: .cancelled)
        case .jobFailed(_, let code)?: ended(id, state: cancelRequested.contains(id) ? .cancelled : .failed, code: code)
        default:
            // No job terminal: the helper went away mid-job (crash → NFR-S4 restart) or never ran it.
            if engineError == nil || engineError!.is(.engineRestarted) {
                ended(id, state: cancelRequested.contains(id) ? .cancelled : .lost)
            } else {
                ended(id, state: .failed, code: engineError?.code)
            }
        }
    }

    private func progressed(_ e: MediaJobEvent) {
        guard case .jobProgress(let id, let step, let total, let preview) = e else { return }
        let p = total > 0 ? Double(step) / Double(total) : 0
        if videoStatus[id] != nil { videoStatus[id]?.apply(.job(e)) }
        try? database.write { db in try db.execute(sql: "UPDATE media_job SET progress = ? WHERE id = ?", arguments: [p, id]) }
        publish(id, previewPath: preview)
    }

    private func ended(_ id: String, state: MediaJobState, code: String? = nil, resultPath: String? = nil, countBlock: Bool = false) {
        do {
            try database.write { db in
                try db.execute(sql: """
                    UPDATE media_job SET state = ?, position = NULL, finished_at = ?, error_code = ?, progress = CASE WHEN ? THEN 1 ELSE progress END
                    WHERE id = ?
                    """, arguments: [state.rawValue, now().timeIntervalSince1970, code, state == .done, id])
                if countBlock { try ChildSafetyCounter.recordBlock(in: db) }
            }
        } catch { AppLog.log(.harness, .error, "media job \(id): \(error)") }
        // M4 review P1-2: nothing stays in the job's xfer dir once it ended — except a done result until its caller
        // stored it (`discardFiles` after the artifact copy) and a lost job's own inputs (its restart needs them).
        switch state {
        case .done: break
        case .lost: removeFiles(id, keepInputs: true)
        default: removeFiles(id)
        }
        cancelRequested.remove(id)
        runningJob = nil
        running.withLock { $0 = false }
        runningVideo.withLock { $0 = false }
        if var v = videoStatus[id] {
            v.paused = nil  // a finished job is not paused
            v.notice = nil
            videoStatus = [id: v]  // keep only the last job's status (re-attach of a finished card)
        }
        pumpTask = nil
        slot.release(self)
        publish(id, resultPath: resultPath)
        try? renumber()
        if isClosed {  // M4 review P1-2: the session is gone; nothing of its jobs stays (no further job starts)
            removeRoot()
            return
        }
        pump()
    }

    private func finish(_ id: String, state: MediaJobState, code: String? = nil, only: Set<MediaJobState>) throws {
        let changed = try database.write { db -> Bool in
            try db.execute(sql: """
                UPDATE media_job SET state = ?, position = NULL, finished_at = ?, error_code = ? WHERE id = ? AND state IN (\(only.map { "'\($0.rawValue)'" }.joined(separator: ",")))
                """, arguments: [state.rawValue, now().timeIntervalSince1970, code, id])
            return db.changesCount > 0
        }
        if changed {
            publish(id)
            try renumber()
        }
    }

    // MARK: - Job files (M4 review P1-2)

    static let inputPrefix = "input-"

    nonisolated func jobDir(_ id: String) -> URL { xferRoot.appendingPathComponent(id, isDirectory: true) }

    /// Deletes a job's xfer dir (previews, result; `keepInputs`: its `input-*` files stay, the dir only if it has any).
    nonisolated func removeFiles(_ id: String, keepInputs: Bool = false) {
        let dir = jobDir(id)
        guard keepInputs else { try? FileManager.default.removeItem(at: dir); return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where !name.hasPrefix(Self.inputPrefix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        // No inputs to keep (a lost video job): nothing of the job stays (M5.T14 review P1-2).
        if !names.contains(where: { $0.hasPrefix(Self.inputPrefix) }) { try? FileManager.default.removeItem(at: dir) }
    }

    /// The caller stored the result (artifact copy): the job's files go.
    public func discardFiles(_ id: String) { removeFiles(id) }

    /// Launch sweep: the dir of every job of this queue (a row in its database) that is not queued or running goes —
    /// a lost job's too, inputs included (M4 review P2-6: nothing restarts a job of an earlier run, so an Erase mask
    /// kept "for its restart" would stay forever). A dir with no row here is never touched: the root can be shared (dev, try-out
    /// and release builds, test hosts), and "unknown to my database" is not "abandoned" (2026-11-08: every in-memory
    /// test environment swept ~/Library/Caches/AntiChat/xfer). Remove everything still clears the whole root.
    @discardableResult
    public func sweepFiles() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: xferRoot.path)) ?? []
        var removed = 0
        for name in names {
            let state = (try? row(name))??.state
            switch state {
            case .queued?, .running?: continue
            case nil: continue  // another queue's (another database, build or test)
            default: removeFiles(name); removed += 1
            }
        }
        return removed
    }

    /// 0 = running, 1… = waiting (creation order); finished rows have none.
    private func renumber() throws {
        let changed = try database.write { db -> [String] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, position FROM media_job WHERE state IN ('queued', 'running')
                ORDER BY CASE state WHEN 'running' THEN 0 ELSE 1 END, position, created_at
                """)
            let hasRunning = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_job WHERE state = 'running'") ?? 0) > 0
            var out: [String] = []
            for (i, r) in rows.enumerated() {
                let want = hasRunning ? i : i + 1
                let id: String = r["id"]
                if (r["position"] as Int?) != want {
                    try db.execute(sql: "UPDATE media_job SET position = ? WHERE id = ?", arguments: [want, id])
                    out.append(id)
                }
            }
            return out
        }
        for id in changed { publish(id) }
    }

    private func publish(_ id: String, previewPath: String? = nil, resultPath: String? = nil) {
        guard let r = try? row(id) else { return }
        if let resultPath { lastResult[id] = resultPath }
        if let previewPath { lastPreview[id] = previewPath }
        let u = Update(job: id, state: r.state, position: r.position, progress: r.progress, previewPath: previewPath,
                       resultPath: resultPath, errorCode: r.errorCode, video: videoStatus[id])
        updateCont.yield(u)
        for c in subscribers.values { c.yield(u) }
        if ![MediaJobState.queued, .running].contains(r.state), let w = waiters.removeValue(forKey: id) {
            var done = u
            done.resultPath = lastResult[id]
            w.forEach { $0.resume(returning: done) }
        }
    }
}

/// M5 review P2-3 / M4 review P2-1: the app-wide running-job slot of a queue family (the app queue and the incognito
/// queues derived from it). At most one queue holds it; queues that want it wait in arrival order, and a freed slot
/// goes to the longest-waiting queue first (the queue that just finished queues up behind it), so no family member
/// starves and two jobs never reach the helper together.
final class MediaJobSlot: Sendable {
    private struct Weak: @unchecked Sendable { weak var queue: MediaJobQueue? }
    private struct State { var holder: ObjectIdentifier?; var waiting: [(id: ObjectIdentifier, ref: Weak)] = [] }
    private let state = Mutex(State())

    /// True when `queue` holds the slot (now or already); else it is queued for it and woken on release.
    func acquire(_ queue: MediaJobQueue) -> Bool {
        let me = ObjectIdentifier(queue)
        return state.withLock { s in
            if s.holder == me { return true }
            s.waiting.removeAll { $0.ref.queue == nil }
            if s.holder == nil, (s.waiting.first?.id ?? me) == me {
                s.holder = me
                s.waiting.removeAll { $0.id == me }
                return true
            }
            if !s.waiting.contains(where: { $0.id == me }) { s.waiting.append((me, Weak(queue: queue))) }
            return false
        }
    }

    /// `queue` ended its job: the slot is free and the first waiting queue is told.
    func release(_ queue: MediaJobQueue) {
        let next = state.withLock { s -> MediaJobQueue? in
            guard s.holder == ObjectIdentifier(queue) else { return nil }
            s.holder = nil
            return Self.first(&s)
        }
        if let next { Task { await next.slotFreed() } }
    }

    /// `queue` has nothing waiting any more: it leaves the line (and passes a free slot on).
    func withdraw(_ queue: MediaJobQueue) {
        let next = state.withLock { s -> MediaJobQueue? in
            let me = ObjectIdentifier(queue)
            guard s.waiting.contains(where: { $0.id == me }) else { return nil }
            s.waiting.removeAll { $0.id == me }
            return s.holder == nil ? Self.first(&s) : nil
        }
        if let next { Task { await next.slotFreed() } }
    }

    private static func first(_ s: inout State) -> MediaJobQueue? {
        s.waiting.removeAll { $0.ref.queue == nil }
        return s.waiting.first?.ref.queue
    }
}
