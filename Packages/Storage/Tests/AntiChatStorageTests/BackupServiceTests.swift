// M8.T01 AT-301 (R-301 AC2): daily backups on a stepped clock (10 days → exactly 7 daily remain, the newest 3
// pre-update copies remain), listing, and a staged restore of day 3 that yields that day's content (the current data
// saved as pre-restore first).
//   make test-unit FILTER=BackupServiceTests
import Foundation
import GRDB
import Synchronization
import Testing
@testable import AntiChatStorage

final class SteppedClock: Sendable {
    let t = Mutex(Date(timeIntervalSince1970: 1_793_000_000))  // 2026-10-26
    func now() -> Date { t.withLock { $0 } }
    func advance(_ s: TimeInterval) { t.withLock { $0 += s } }
}

@Suite(.serialized) struct BackupServiceTests {
    @Test func tenDaysKeepSevenDailyAndThreePreUpdate() throws {
        let dir = try tempContainer("bk")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("antichat.sqlite")
        let clock = SteppedClock()
        let db = try AppDatabase.onDisk(at: url, runner: MigrationRunner(eraseOnSchemaChange: false, now: { clock.now() }))
        let service = BackupService(databaseURL: url, now: { clock.now() })
        var dumps: [String: String] = [:]
        for day in 1...10 {
            try db.write { d in try ChatRecord(id: "day-\(day)", mode: .normal).insert(d) }
            let made = try #require(try service.dailyIfDue(from: db.reader), "day \(day)")
            dumps[made.lastPathComponent] = try canonicalDump(db.reader)
            #expect(try service.dailyIfDue(from: db.reader) == nil, "a second backup the same day")
            _ = try service.preMigration(pool: db.reader, head: "v\(day)_fake")
            clock.advance(24 * 3600)
        }
        let all = try service.list()
        let daily = all.filter { $0.kind == .daily }
        #expect(daily.count == BackupService.keepDaily)
        #expect(all.filter { $0.kind == .preUpdate }.map(\.url.lastPathComponent).map { $0.components(separatedBy: "-")[1] }
                == ["v10_fake", "v9_fake", "v8_fake"])
        #expect(daily.first?.date ?? .distantPast > daily.last?.date ?? .distantFuture, "newest first")
        #expect(daily.allSatisfy { (BackupService.chatCount($0) ?? 0) > 0 })

        // Restore day 3 of the kept seven (the 6th day overall), applied at the next launch.
        let pick = daily[daily.count - 3]
        let expected = try #require(dumps[pick.url.lastPathComponent])
        let current = try canonicalDump(db.reader)
        try service.stageRestore(pick)
        try (db.writer as? DatabasePool)?.close()
        let (reopened, report) = try AppDatabase.open(at: url, runner: MigrationRunner(eraseOnSchemaChange: false, now: { clock.now() }))
        #expect(report.restoredFrom?.lastPathComponent == pick.url.lastPathComponent)
        #expect(try canonicalDump(reopened.reader) == expected)
        let saved = try #require(try service.list().first { $0.kind == .preRestore })
        #expect(try canonicalDump(try openReadOnly(saved.url)) == current, "current data not saved before the restore")
        at301Log("AT-301 AC2 daily: 10 days → \(daily.count) daily, 3 pre-update; restore \(pick.url.lastPathComponent) content equal; pre-restore \(saved.url.lastPathComponent)")
    }

    /// Review fix (M8.T16): a live database SQLite cannot open is saved as raw files and the restore still runs; a
    /// restore that cannot be applied keeps its request for the next launch; the live file is never removed first.
    @Test func restoreSurvivesACorruptLiveDatabaseAndKeepsAFailedRequest() throws {
        let dir = try tempContainer("bk-corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("antichat.sqlite")
        let clock = SteppedClock()
        let db = try AppDatabase.onDisk(at: url, runner: MigrationRunner(eraseOnSchemaChange: false, now: { clock.now() }))
        try db.write { d in try ChatRecord(id: "kept", mode: .normal).insert(d) }
        let service = BackupService(databaseURL: url, now: { clock.now() })
        let backup = try #require(try service.dailyIfDue(from: db.reader))
        try (db.writer as? DatabasePool)?.close()
        // The live file turns to garbage (why people restore).
        try Data(repeating: 0x5A, count: 8192).write(to: url)
        for s in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) }
        try service.stageRestore(try #require(try service.list().first { $0.url.lastPathComponent == backup.lastPathComponent }))
        clock.advance(5)
        #expect(try service.applyStagedRestore()?.lastPathComponent == backup.lastPathComponent)
        let raw = try #require(try service.list().first { $0.kind == .preRestore })
        #expect(try Data(contentsOf: raw.url) == Data(repeating: 0x5A, count: 8192), "the corrupt file is kept as it was")
        let q = try DatabaseQueue(path: url.path)
        #expect(try q.read { try String.fetchOne($0, sql: "SELECT id FROM chat") } == "kept")
        try q.close()
        #expect(!FileManager.default.fileExists(atPath: service.directory.appendingPathComponent(BackupService.stagedName).path))

        // A backup that cannot be read: the restore throws and its request stays for the next launch.
        try service.stageRestore(try #require(try service.list().first { $0.url.lastPathComponent == backup.lastPathComponent }))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: backup.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path) }
        #expect(throws: (any Error).self) { try service.applyStagedRestore() }
        #expect(FileManager.default.fileExists(atPath: service.directory.appendingPathComponent(BackupService.stagedName).path),
                "a failed restore is retried at the next launch")
        let q2 = try DatabaseQueue(path: url.path)
        #expect(try q2.read { try String.fetchOne($0, sql: "SELECT id FROM chat") } == "kept", "the live file was not removed")
        try q2.close()
    }

    @Test func listIgnoresForeignFilesAndParsesKinds() throws {
        let dir = try tempContainer("bk")
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = BackupService(databaseURL: dir.appendingPathComponent("antichat.sqlite"))
        try FileManager.default.createDirectory(at: service.directory, withIntermediateDirectories: true)
        for n in ["daily-20261101.sqlite", "pre-v14_files_m6-20261102-101500.sqlite", "pre-restore-20261103-090000.sqlite",
                  "failed-20261103-090001.sqlite", "notes.txt", ".daily-x.sqlite.partial"] {
            FileManager.default.createFile(atPath: service.directory.appendingPathComponent(n).path, contents: Data())
        }
        #expect(try service.list().map(\.kind) == [.preRestore, .preUpdate, .daily])
    }
}
