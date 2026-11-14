// M8.T01 (R-301 AC1/AC2): backups of the app database in `<container>/Backups/`.
//   pre-<head id>-<yyyyMMdd-HHmmss>.sqlite   before every migration (MigrationRunner), newest 3 kept
//   daily-<yyyyMMdd>.sqlite                  once a day when the app is idle (DailyBackupScheduler), newest 7 kept
//   pre-restore-<ts>.sqlite                  the current data, saved before a restore replaces it, newest 3 kept
//   failed-<ts>.sqlite                       the live file of a migration that threw (kept, never pruned)
// Every copy is SQLite's online backup (`DatabaseReader.backup(to:)`), fsynced and checked with `integrity_check`.
// A restore is staged (`restore-pending.json`) and applied by MigrationRunner at the next launch, before any pool
// exists, so the files are never swapped under an open connection. Never used for the incognito in-memory database.
import AntiChatFoundation
import Foundation
import GRDB

public struct BackupService: Sendable {
    public enum Kind: String, Sendable, CaseIterable { case daily, preUpdate, preRestore }

    public struct Backup: Sendable, Equatable, Identifiable {
        public var url: URL
        public var kind: Kind
        public var date: Date
        public var bytes: Int64
        public var id: String { url.lastPathComponent }
    }

    public static let keepDaily = 7
    public static let keepPreUpdate = 3
    public static let keepPreRestore = 3
    static let stagedName = "restore-pending.json"

    public let databaseURL: URL
    public var now: @Sendable () -> Date
    public var directory: URL { databaseURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true) }

    public init(databaseURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.databaseURL = databaseURL
        self.now = now
    }

    // MARK: Taking backups

    /// The copy before a migration to `head` (MigrationRunner step 2), then prune.
    @discardableResult
    public func preMigration(pool: any DatabaseReader, head: String) throws -> URL {
        let url = unique { "pre-\(head)-\($0).sqlite" }
        try copy(from: pool, to: url)
        try prune()
        return url
    }

    /// Today's daily backup when the newest is older than 24 h (or there is none); nil when not due.
    @discardableResult
    public func dailyIfDue(from reader: any DatabaseReader) throws -> URL? {
        let newest = try list().filter { $0.kind == .daily }.map(\.date).max()
        if let newest, now().timeIntervalSince(newest) < 24 * 3600 { return nil }
        let url = directory.appendingPathComponent("daily-\(Self.formatter("yyyyMMdd").string(from: now())).sqlite")
        if FileManager.default.fileExists(atPath: url.path) { return nil }
        try copy(from: reader, to: url)
        try prune()
        AppLog.log(.store, .info, "backup: daily \(url.lastPathComponent)")
        return url
    }

    /// Online backup to `url` (a fresh file), fsync, `integrity_check == ok`; a failed check deletes the copy.
    func copy(from reader: any DatabaseReader, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).partial")
        try? fm.removeItem(at: tmp)
        do {
            let dest = try DatabaseQueue(path: tmp.path)
            try reader.backup(to: dest)
            try dest.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = DELETE") }
            let ok = try dest.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
            try dest.close()
            // The copy took the source's WAL header; after `journal_mode = DELETE` an empty `-shm` can stay behind.
            for suffix in ["-wal", "-shm", "-journal"] { try? fm.removeItem(atPath: tmp.path + suffix) }
            guard ok == "ok" else { throw StorageError.migrationFailed("backup integrity_check: \(ok ?? "nil")") }
            let h = try FileHandle(forWritingTo: tmp)
            try h.synchronize()
            try h.close()
            try fm.moveItem(at: tmp, to: url)
        } catch {
            for suffix in ["", "-wal", "-shm", "-journal"] { try? fm.removeItem(atPath: tmp.path + suffix) }
            throw error
        }
    }

    // MARK: Listing and pruning

    /// Every backup, newest first.
    public func list() throws -> [Backup] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .compactMap(Self.parse)
            .sorted { ($0.date, $0.url.lastPathComponent) > ($1.date, $1.url.lastPathComponent) }
    }

    static func parse(_ url: URL) -> Backup? {
        let name = url.lastPathComponent
        guard name.hasSuffix(".sqlite") else { return nil }
        let base = String(name.dropLast(".sqlite".count))
        let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if base.hasPrefix("daily-"), let d = formatter("yyyyMMdd").date(from: String(base.dropFirst(6))) {
            return Backup(url: url, kind: .daily, date: d, bytes: bytes)
        }
        let stamp = String(base.suffix(15))  // yyyyMMdd-HHmmss
        guard let d = formatter("yyyyMMdd-HHmmss").date(from: stamp) else { return nil }
        if base.hasPrefix("pre-restore-") { return Backup(url: url, kind: .preRestore, date: d, bytes: bytes) }
        if base.hasPrefix("pre-") { return Backup(url: url, kind: .preUpdate, date: d, bytes: bytes) }
        return nil
    }

    /// Keeps the newest 7 daily, 3 pre-update and 3 pre-restore copies.
    public func prune() throws {
        let all = try list()
        for (kind, keep) in [(Kind.daily, Self.keepDaily), (.preUpdate, Self.keepPreUpdate), (.preRestore, Self.keepPreRestore)] {
            for b in all.filter({ $0.kind == kind }).dropFirst(keep) { try FileManager.default.removeItem(at: b.url) }
        }
    }

    /// Non-archived chats in a backup, read from a clone-free read-only open (backups are DELETE-journal files).
    public static func chatCount(_ backup: Backup) -> Int? {
        var config = Configuration()
        config.readonly = true
        guard let q = try? DatabaseQueue(path: backup.url.path, configuration: config) else { return nil }
        defer { try? q.close() }
        return try? q.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat WHERE archived_at IS NULL") }
    }

    // MARK: Restore

    /// Stages `backup` to replace the database at the next launch (the caller relaunches the app).
    public func stageRestore(_ backup: Backup) throws {
        guard FileManager.default.fileExists(atPath: backup.url.path) else { throw StorageError.notFound(backup.id) }
        let data = try JSONEncoder().encode(["backup": backup.url.lastPathComponent])
        try data.write(to: directory.appendingPathComponent(Self.stagedName), options: .atomic)
    }

    /// MigrationRunner step 0: applies a staged restore with no pool open. The current data is first saved as
    /// `pre-restore-<ts>.sqlite`; then the backup replaces the triple. Returns the backup used, nil when none staged.
    /// Review fix (M8.T16): the request is forgotten only once it is applied (a failure keeps it for the next launch,
    /// and S-25 shows meanwhile); a live database that cannot be opened (corrupt: why users restore) or checked is
    /// saved as raw files instead; the live file is never deleted before the backup copy exists beside it — the copy
    /// goes to a temporary file that atomically replaces it.
    @discardableResult
    func applyStagedRestore() throws -> URL? {
        let fm = FileManager.default
        let marker = directory.appendingPathComponent(Self.stagedName)
        guard let data = fm.contents(atPath: marker.path) else { return nil }
        func forget() { try? fm.removeItem(at: marker) }
        guard let name = (try? JSONDecoder().decode([String: String].self, from: data))?["backup"], !name.contains("/") else {
            forget()
            return nil
        }
        let source = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: source.path) else {
            forget()
            return nil
        }
        if fm.fileExists(atPath: databaseURL.path) {
            let pre = unique { "pre-restore-\($0).sqlite" }
            do {
                let current = try DatabaseQueue(path: databaseURL.path)  // a writable open folds a WAL into the copy
                defer { try? current.close() }
                try copy(from: current, to: pre)
            } catch {
                // A database SQLite cannot open or check: keep its files exactly as they are.
                AppLog.log(.store, .error, "backup: pre-restore copy failed (\(error)); saving the raw files")
                try? fm.removeItem(at: pre)
                for suffix in ["", "-wal", "-shm"] {
                    let from = MigrationRunner.sidecar(databaseURL, suffix)
                    if fm.fileExists(atPath: from.path) { try fm.copyItem(at: from, to: MigrationRunner.sidecar(pre, suffix)) }
                }
            }
        }
        let staging = databaseURL.deletingLastPathComponent().appendingPathComponent(".restore-\(UUID().uuidString).sqlite")
        try fm.copyItem(at: source, to: staging)
        do {
            if fm.fileExists(atPath: databaseURL.path) {
                _ = try fm.replaceItemAt(databaseURL, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: databaseURL)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        // The old WAL / SHM belong to the replaced file (their salts no longer match; remove them at once).
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(at: MigrationRunner.sidecar(databaseURL, suffix)) }
        forget()
        try? prune()
        AppLog.log(.store, .notice, "backup: restored \(name)")
        return source
    }

    // MARK: Names

    func stamp() -> String { Self.formatter("yyyyMMdd-HHmmss").string(from: now()) }

    /// `name(stamp)` in the backup folder; a taken name moves the stamp on by a second (fixed clocks, fast relaunches).
    func unique(_ name: (String) -> String) -> URL {
        var date = now()
        while true {
            let url = directory.appendingPathComponent(name(Self.formatter("yyyyMMdd-HHmmss").string(from: date)))
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            date += 1
        }
    }

    static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }
}
