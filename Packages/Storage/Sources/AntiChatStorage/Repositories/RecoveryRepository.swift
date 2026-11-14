// Launch-recovery writes (M1.T12 step 6; R-208 AC2/AC4). One transaction at DB open, before any UI reads:
// messages left `pending`/`streaming` → `interrupted`, media jobs left `running` or `queued` → `lost`, downloads left
// `downloading` → `queued` (the M2 coordinator resumes them from their chunk map). Called by
// `AntiChatHarness.LaunchRecovery`.
import Foundation
import GRDB

public struct RecoveryRepository: Sendable {
    public struct Result: Sendable, Equatable {
        public var interruptedMessages: [String] = []
        public var lostJobs: [String] = []
        public var requeuedDownloads: [String] = []
        public var isEmpty: Bool { interruptedMessages.isEmpty && lostJobs.isEmpty && requeuedDownloads.isEmpty }
        public init() {}
    }

    public let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    /// The crash sweep. Idempotent: a second run on the same file changes nothing.
    public func sweepAfterCrash(now: Date = Date()) throws -> Result {
        try database.write { db in
            var r = Result()
            r.interruptedMessages = try String.fetchAll(db, sql: "SELECT id FROM message WHERE status IN ('pending', 'streaming')")
            try db.execute(sql: "UPDATE message SET status = 'interrupted' WHERE status IN ('pending', 'streaming')")
            // M4 review P2-3: a job still waiting (`queued`) has no caller left either (its turn ended with the
            // process), so it is settled the same way — `lost`, with Retry on its card — instead of running unattended
            // ahead of the next job with a result nobody stores.
            r.lostJobs = try String.fetchAll(db, sql: "SELECT id FROM media_job WHERE state IN ('running', 'queued') ORDER BY created_at")
            try db.execute(sql: "UPDATE media_job SET state = 'lost', position = NULL, finished_at = ? WHERE state IN ('running', 'queued')",
                           arguments: [now.timeIntervalSince1970])
            r.requeuedDownloads = try String.fetchAll(db, sql: "SELECT id FROM download WHERE state = 'downloading'")
            try db.execute(sql: "UPDATE download SET state = 'queued', updated_at = ? WHERE state = 'downloading'",
                           arguments: [now.timeIntervalSince1970])
            return r
        }
    }
}
