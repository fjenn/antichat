// M8.T01 (R-301, G-059; architecture §5.2): the one launch path of an on-disk database, run before the writable
// `DatabasePool` exists. guard → backup → migrate → restore-on-throw:
//   0. A restore the user staged in Settings (BackupService.stageRestore) is applied first, with no pool open.
//   1. Newer-data guard on a *clone* of the file triple (`.sqlite`, `-wal`, `-shm`; APFS clonefile, outside the
//      container): a read-only open of a WAL file still writes read marks into `-shm`, so the live files are never
//      opened for it. An identifier this build does not know (Migrations.unknownIdentifiers) → `.newerData`, and
//      nothing at all was written (no backup, no checkpoint, no log row).
//   2. Pending migrations (or, with eraseOnSchemaChange, a schema change) → disk-space check, then
//      `Backups/pre-<head id>-<yyyyMMdd-HHmmss>.sqlite` via SQLite's online backup, fsync, `integrity_check = ok`.
//   3. Migrate. On any throw: close the pool, move the live triple to `Backups/failed-<ts>.sqlite…`, copy the
//      pre-migration backup back, and report `.failed` (the app shows MigrationFailedWindow; nothing is lost).
// M6.T01's `AppDatabase.backupBeforeMigrating` is absorbed here (one code path).
import AntiChatFoundation
import Foundation
import GRDB

/// What the app shows after opening its database (S-25): the chats, or a blocking window.
public enum AppLaunchState: Equatable, Sendable {
    case ready
    /// The file was migrated by a newer AntiChat (R-301 AC3). `unknown` = the identifiers this build lacks.
    case newerData(unknown: [String])
    /// A migration threw; the pre-migration backup is back in place (R-301 AC1).
    case migrationFailed(code: String, backup: String?)
    /// Not enough free space for the pre-migration copy; nothing was migrated.
    case backupNoSpace(neededBytes: Int64)

    /// The blocking window for an error the on-disk open threw. Never `.ready`: a launch whose database cannot be
    /// opened shows S-25 and never runs silently on an in-memory store (the owner's chats would be lost).
    public static func blocking(for error: any Error) -> AppLaunchState {
        switch error {
        case StorageError.launchBlocked(let state) where state != .ready: state
        case StorageError.supersededByNewerVersion: .newerData(unknown: [])
        default: .migrationFailed(code: "storage.migrationFailed", backup: nil)
        }
    }
}

public struct MigrationRunner: Sendable {
    public enum Outcome: Sendable {
        case opened(DatabasePool, Report)
        case blocked(AppLaunchState)
    }

    public struct Report: Sendable, Equatable {
        /// Identifiers recorded in the file before this launch (empty for a new file).
        public var applied: [String] = []
        public var head: String = Migrations.head
        /// The pre-migration copy (nil: nothing was pending, or a new file).
        public var backup: URL?
        /// A staged restore was applied before opening (the backup it came from).
        public var restoredFrom: URL?
        public var durationMs: Double = 0
    }

    #if DEBUG
    /// AT-301 (b): a run of THIS runner applies every migration before this identifier, then throws as if it had failed
    /// (`-MigrationFailAt <id>` on the app's command line does the same, for vq-11). Per runner, not a process-wide
    /// static: Swift Testing runs suites concurrently, and a static hook made other suites' database opens fail.
    public var testHook_failAt: String?
    #endif

    public var eraseOnSchemaChange: Bool
    public var now: @Sendable () -> Date
    /// Free bytes on the volume holding `url` (nil = unknown, the backup is tried anyway).
    public var freeSpace: @Sendable (URL) -> Int64?

    /// The default `eraseOnSchemaChange`: Debug builds only (the dev "edit a migration, relaunch" convenience, as
    /// `Migrations.migrator()`). M9.T05: not the optimized perf-harness build (`ANTICHAT_PERF_HARNESS`, where
    /// `isDebugBuild` is true for the dev container): the check migrates two in-memory databases from scratch (the
    /// probe's `hasSchemaChanges` and GRDB's own check in `migrate`), ~50 ms of every launch (U1 `migration` interval
    /// 62–80 ms vs 16 ms for a new file) that Release never pays, so U1 measured a cost the product does not have.
    public static var erasesOnSchemaChangeByDefault: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    public init(eraseOnSchemaChange: Bool = MigrationRunner.erasesOnSchemaChangeByDefault, now: @escaping @Sendable () -> Date = { Date() },
                freeSpace: @escaping @Sendable (URL) -> Int64? = MigrationRunner.volumeFreeSpace) {
        self.eraseOnSchemaChange = eraseOnSchemaChange
        self.now = now
        self.freeSpace = freeSpace
    }

    public static func volumeFreeSpace(_ url: URL) -> Int64? {
        let v = try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    func migrator() -> DatabaseMigrator {
        var m = Migrations.migrator()
        m.eraseDatabaseOnSchemaChange = eraseOnSchemaChange
        return m
    }

    /// Opens (creating if needed) the database at `url` through guard → backup → migrate.
    public func run(at url: URL, configuration: Configuration) throws -> Outcome {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let started = DispatchTime.now().uptimeNanoseconds
        let signpost = Signposts.begin(.migration, on: Signposts.signposter(.store))
        defer { Signposts.end(.migration, signpost, on: Signposts.signposter(.store)) }
        var report = Report()
        let backups = BackupService(databaseURL: url, now: now)
        report.restoredFrom = try backups.applyStagedRestore()

        let migrator = migrator()
        var pending = false
        if fm.fileExists(atPath: url.path) {
            let probe = try Self.probe(url, configuration: configuration, migrator: migrator, schemaCheck: eraseOnSchemaChange)
            report.applied = probe.applied
            let unknown = Migrations.unknownIdentifiers(in: Set(probe.applied))
            if !unknown.isEmpty {
                AppLog.log(.store, .notice, "migration: refused, data from a newer build (\(unknown.sorted().joined(separator: ",")))")
                return .blocked(.newerData(unknown: unknown.sorted()))
            }
            let resolved = Set(probe.applied.map { id in Migrations.renamed.first { $0.value.contains(id) }?.key ?? id })
            let renamedPresent = probe.applied.contains { id in Migrations.renamed.values.contains { $0.contains(id) } }
            pending = !probe.applied.isEmpty
                && (!Set(Migrations.identifiers).isSubset(of: resolved) || renamedPresent || probe.schemaChanged)
        }

        let pool = try DatabasePool(path: url.path, configuration: configuration)
        if pending {
            let need = Self.fileSize(url) + Self.fileSize(Self.sidecar(url, "-wal")) + 64 << 20
            if let free = freeSpace(url), free < need {
                try? pool.close()
                AppLog.log(.store, .error, "migration: not run, \(free) bytes free, \(need) needed for the backup")
                return .blocked(.backupNoSpace(neededBytes: need))
            }
            report.backup = try backups.preMigration(pool: pool, head: Migrations.head)
        }
        do {
            try pool.write { try ChunkTables.ensureVectorTable($0) }
            #if DEBUG
            if let failAt = testHook_failAt ?? AppDefaults.standard.string(forKey: "MigrationFailAt"), let i = Migrations.identifiers.firstIndex(of: failAt) {
                if i > 0 { try migrator.migrate(pool, upTo: Migrations.identifiers[i - 1]) }
                throw StorageError.migrationFailed("test hook: \(failAt)")
            }
            #endif
            try migrator.migrate(pool)
        } catch {
            try? pool.close()
            guard let backup = report.backup else { throw error }  // nothing was pending: not a migration failure
            let code = Self.restore(url, from: backup, stamp: backups.stamp())
            AppLog.log(.store, .error, "migration: failed (\(String(describing: error).prefix(200))); backup restored: \(code)")
            return .blocked(.migrationFailed(code: "storage.migrationFailed", backup: backup.lastPathComponent))
        }
        report.durationMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        if pending || report.applied.isEmpty {
            AppLog.log(.store, .notice, "migration: \(report.applied.last ?? "new file") → \(report.head) in \(Int(report.durationMs)) ms, backup \(report.backup?.lastPathComponent ?? "none")")
        }
        return .opened(pool, report)
    }

    struct Probe { var applied: [String]; var schemaChanged: Bool }

    /// Reads the applied identifiers from an APFS clone of the file triple (the live files stay untouched).
    static func probe(_ url: URL, configuration: Configuration, migrator: DatabaseMigrator, schemaCheck: Bool) throws -> Probe {
        let fm = FileManager.default
        let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent(url.lastPathComponent)
        for suffix in ["", "-wal", "-shm"] {
            let src = sidecar(url, suffix)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: sidecar(copy, suffix)) }
        }
        var config = configuration
        config.label = "MigrationRunner.probe"
        let queue = try DatabaseQueue(path: copy.path, configuration: config)
        defer { try? queue.close() }
        return try queue.read { db in
            let applied = try db.tableExists("grdb_migrations")
                ? try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid") : []
            var changed = false
            if schemaCheck, !applied.isEmpty, Migrations.unknownIdentifiers(in: Set(applied)).isEmpty {
                changed = try migrator.hasSchemaChanges(db)
            }
            return Probe(applied: applied, schemaChanged: changed)
        }
    }

    /// After a failed migration: the live triple goes to `Backups/failed-<stamp>.sqlite…`, the backup comes back.
    static func restore(_ url: URL, from backup: URL, stamp: String) -> String {
        let fm = FileManager.default
        let failed = backup.deletingLastPathComponent().appendingPathComponent("failed-\(stamp).sqlite")
        do {
            for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: sidecar(url, suffix).path) {
                try fm.moveItem(at: sidecar(url, suffix), to: sidecar(failed, suffix))
            }
            try fm.copyItem(at: backup, to: url)
            return "ok"
        } catch {
            return "error \(error)"
        }
    }

    static func sidecar(_ url: URL, _ suffix: String) -> URL {
        suffix.isEmpty ? url : url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + suffix)
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
