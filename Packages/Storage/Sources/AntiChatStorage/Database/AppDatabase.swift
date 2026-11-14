// The app's one database (architecture §5, §6 "DB: one writer"). On disk: one GRDB `DatabasePool` (WAL,
// many readers, one serialized writer) at `~/Library/Application Support/AntiChat/antichat.sqlite` (Release; Debug
// builds use `…/AntiChat-Dev/`), or under `-ANTICHAT_DEV_CONTAINER <path>` in DEBUG (M1.md convention 10). Incognito: an in-memory `DatabaseQueue`
// with the same migrations and `PRAGMA temp_store=MEMORY` (architecture §5.4). The helper never opens it.
import AntiChatFoundation
import Foundation
import GRDB

public enum StorageError: Error, Equatable, Sendable {
    /// The file was migrated by a newer AntiChat (architecture §5.2 newer-version guard).
    case supersededByNewerVersion
    case notFound(String)
    case invalidTree(String)
    case invalidExport(String)
    /// M8.T01: a migration threw (the message is for logs only, never shown).
    case migrationFailed(String)
    /// M8.T01: the on-disk database cannot be opened for chats; the app shows the state's window (S-25).
    case launchBlocked(AppLaunchState)
}

public final class AppDatabase: Sendable {
    /// The single writer. Use `write` for every mutation; reads may go through `reader`.
    public let writer: any DatabaseWriter
    public var reader: any DatabaseReader { writer }
    /// True for the incognito / test database (nothing reaches disk).
    public let isInMemory: Bool
    /// The file of an on-disk database (nil in memory): backups live next to it (M8.T01).
    public var fileURL: URL? {
        guard !isInMemory, let p = (writer as? DatabasePool)?.path ?? (writer as? DatabaseQueue)?.path, !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p)
    }

    /// Wraps `writer` and runs the migrations. Refuses a database migrated by a newer build. On-disk files go
    /// through `MigrationRunner` first (`onDisk(at:)`: guard → backup → migrate), so this only finishes the job.
    public init(_ writer: any DatabaseWriter, isInMemory: Bool = false) throws {
        self.writer = writer
        self.isInMemory = isInMemory
        let migrator = Migrations.migrator()
        let applied = try writer.read { try migrator.appliedIdentifiers($0) }
        if !Migrations.unknownIdentifiers(in: applied).isEmpty { throw StorageError.supersededByNewerVersion }
        // M2.T16: `chunk_vec` is a rebuildable index outside the frozen DDL (plain SQLite tools have no vec0), so a
        // file written from that DDL (tools/fixtures/gen-chats.py) gets it here, before the DEBUG schema-change check.
        try writer.write { try ChunkTables.ensureVectorTable($0) }
        try migrator.migrate(writer)
    }

    /// True in a Debug build (`swift test`, `make build`, `antichat-cli` via `swift run`).
    public static var isDebugBuild: Bool {
        #if DEBUG || ANTICHAT_PERF_HARNESS
            true
        #else
            false
        #endif
    }

    /// The default container's folder name: the owner's real data (`AntiChat`) only in Release; every Debug build uses
    /// the separate dev container (`AntiChat-Dev`, environment.md §3 step 12) — a Debug run's schema change can never
    /// touch the real chats (lead decision A, M2 review).
    public static func defaultContainerName(debug: Bool = isDebugBuild) -> String { debug ? "AntiChat-Dev" : "AntiChat" }

    /// Container directory: `<dev container>`, else `~/Library/Application Support/AntiChat` (Release) or
    /// `…/AntiChat-Dev` (Debug).
    public static func containerURL(options: LaunchOptions = .current, debug: Bool = isDebugBuild) -> URL {
        if let dev = options.devContainer { return URL(fileURLWithPath: dev, isDirectory: true) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(defaultContainerName(debug: debug), isDirectory: true)
    }

    public static func defaultURL(options: LaunchOptions = .current) -> URL {
        containerURL(options: options).appendingPathComponent("antichat.sqlite")
    }

    /// The app database at its default location (creating the container directory).
    public static func openDefault(options: LaunchOptions = .current) throws -> AppDatabase {
        try onDisk(at: defaultURL(options: options))
    }

    /// A WAL `DatabasePool` at `url` (`foreign_keys=ON`, `synchronous=NORMAL`), opened through `MigrationRunner`.
    /// Throws `StorageError.launchBlocked` for newer data, a failed (and rolled back) migration or no backup space.
    public static func onDisk(at url: URL, runner: MigrationRunner = MigrationRunner()) throws -> AppDatabase {
        try open(at: url, runner: runner).0
    }

    /// `onDisk(at:)` plus the runner's report (versions, backup, duration).
    public static func open(at url: URL, runner: MigrationRunner = MigrationRunner()) throws -> (AppDatabase, MigrationRunner.Report) {
        switch try runner.run(at: url, configuration: diskConfiguration()) {
        case .opened(let pool, let report): return (try AppDatabase(pool), report)
        case .blocked(let state): throw StorageError.launchBlocked(state)
        }
    }

    static func diskConfiguration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try VecLoader.load(db)  // M2.T16: vec0 on every connection (P-media-15)
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        return config
    }

    /// The incognito / test database: in memory, same migrations, temp files in memory too.
    public static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try VecLoader.load(db)
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
        }
        return try AppDatabase(DatabaseQueue(configuration: config), isInMemory: true)
    }

    // MARK: Access

    /// One serialized write transaction.
    public func write<T>(_ updates: (Database) throws -> T) throws -> T { try writer.write(updates) }

    public func read<T>(_ value: (Database) throws -> T) throws -> T { try writer.read(value) }

    /// Enqueues one write transaction on the writer and returns at once. For the main thread: `write` waits for
    /// whatever holds the writer (a streaming save, the indexer), which under CPU load stalled the UI for seconds
    /// (AT-NFR-S3). Writes keep their order on the writer's serial queue, so a later `write` or `read` on a queue
    /// sees it; a pool reader started before it commits may not. A failure is logged with `what` and passed to
    /// `completion` (called on the writer's queue).
    public func writeLater(_ what: String, _ updates: @escaping @Sendable (Database) throws -> Void,
                           completion: (@Sendable (Result<Void, Error>) -> Void)? = nil) {
        writer.asyncWrite(updates) { _, result in
            if case .failure(let error) = result {
                AppLog.log(.store, .error, "\(what) failed: \(String(describing: error))")
            }
            completion?(result)
        }
    }

    /// A `ValueObservation` over `fetch` (sidebar, chat list; architecture §6). Start it with `start(in:)`.
    public func observation<T>(_ fetch: @escaping @Sendable (Database) throws -> T)
        -> ValueObservation<ValueReducers.Fetch<T>>
    {
        ValueObservation.tracking(fetch)
    }

    // MARK: Maintenance

    /// FTS5 external-content drift check; rebuilds both indexes when it fails (M1.T04 failure mode 2).
    /// Returns true when a rebuild ran.
    @discardableResult
    public func repairFullTextIfNeeded() throws -> Bool {
        try writer.write { db in
            do {
                // AT-092: while an import's FTS backlog is pending the index is short by design (not drift).
                let backlog = try Int.fetchOne(db, sql: "SELECT count(*) FROM message_fts_backlog") ?? 0
                if backlog == 0 { try db.execute(sql: "INSERT INTO message_fts(message_fts, rank) VALUES('integrity-check', 1)") }
                try db.execute(sql: "INSERT INTO chat_fts(chat_fts, rank) VALUES('integrity-check', 1)")
                return false
            } catch {
                try db.execute(sql: "INSERT INTO message_fts(message_fts) VALUES('rebuild')")
                try db.execute(sql: "DELETE FROM message_fts_backlog")  // the rebuild indexed every row
                try db.execute(sql: "INSERT INTO chat_fts(chat_fts) VALUES('rebuild')")
                return true
            }
        }
    }
}
