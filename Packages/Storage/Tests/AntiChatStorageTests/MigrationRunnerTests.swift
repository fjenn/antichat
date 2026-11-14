// M8.T01 AT-301 (R-301 AC1, AC3): guard → backup → migrate → restore-on-throw, from every committed schema version.
//   (a) every fixtures/chats/db/<id>.sqlite (+ the M1-era legacy container) migrates to head, rows kept, with a
//       pre-<head>-*.sqlite backup whose integrity_check is ok and whose content equals the fixture's;
//   (b) an injected failure leaves antichat.sqlite equal in content to the pre-migration backup, state migrationFailed;
//   (c) both future-v999 variants: mtime, size and sha256 of every file unchanged, no new file, state newerData;
//   (d) registration is append-only against fixtures/chats/db/migrations.lock (renumbers need Migrations.renamed).
//   make test-unit FILTER=MigrationRunnerTests      (log: build/at/AT-301/<date>.log)
import CryptoKit
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

let dbFixtures = fixturesRoot.appendingPathComponent("chats/db")

/// Content of the user tables as a canonical string (the Swift twin of tools/ci/db-canon.py's table set).
func canonicalDump(_ reader: any DatabaseReader) throws -> String {
    let tables = ["chat": "id", "message": "id", "message_part": "message_id, idx", "attachment": "id", "file_blob": "id",
                  "draft": "chat_id", "feedback": "message_id, kind", "tool_permission": "tool_key"]
    let core = ["id", "title", "mode", "chat_id", "parent_id", "role", "body", "idx", "kind", "text", "blob_id",
                "sha256", "display_name", "policy", "tool_key", "created_at", "updated_at", "leaf_message_id", "active_child_id"]
    return try reader.read { db in
        var out: [String] = []
        for (t, key) in tables.sorted(by: { $0.key < $1.key }) where try db.tableExists(t) {
            let cols = try db.columns(in: t).map(\.name).filter(core.contains).sorted()
            for row in try Row.fetchAll(db, sql: "SELECT \(cols.joined(separator: ",")) FROM \(t) ORDER BY \(key)") {
                out.append(t + "|" + cols.map { "\(row[$0] as DatabaseValue)" }.joined(separator: "|"))
            }
        }
        return out.joined(separator: "\n")
    }
}

func openReadOnly(_ url: URL) throws -> DatabaseQueue {
    var c = Configuration()
    c.readonly = true
    return try DatabaseQueue(path: url.path, configuration: c)
}

func tempContainer(_ name: String = "mr") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Appends a line to build/at/AT-301/<date>.log (the AT artefact).
func at301Log(_ line: String) {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { dir.deleteLastPathComponent() }
    dir = dir.appendingPathComponent("build/at/AT-301")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let day = Date().formatted(.iso8601.year().month().day())
    let url = dir.appendingPathComponent("\(day).log")
    let data = Data((line + "\n").utf8)
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
}

func sha(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }

let releaseRunner = MigrationRunner(eraseOnSchemaChange: false)  // Release behaviour (what the owner's data meets)

@Suite(.serialized) struct MigrationRunnerTests {
    static var fixtureIDs: [String] {
        Migrations.identifiers.filter { FileManager.default.fileExists(atPath: dbFixtures.appendingPathComponent("\($0).sqlite").path) }
    }

    // (a)
    @Test func everyFixtureMigratesToHeadWithAVerifiedBackup() throws {
        let names = Self.fixtureIDs.map { "\($0).sqlite" } + ["legacy-m1-v2_tool_permission.sqlite"]
        #expect(Self.fixtureIDs.count >= 14, "fixtures missing under \(dbFixtures.path)")
        for name in names {
            let src = dbFixtures.appendingPathComponent(name)
            try #require(FileManager.default.fileExists(atPath: src.path), "\(name)")
            let dir = try tempContainer()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("antichat.sqlite")
            try FileManager.default.copyItem(at: src, to: url)
            let before = try canonicalDump(try openReadOnly(src))
            let (db, report) = try AppDatabase.open(at: url, runner: releaseRunner)
            let applied = try db.read { try Migrations.migrator().appliedIdentifiers($0) }
            #expect(applied == Set(Migrations.identifiers), "\(name): \(applied.sorted())")
            #expect(try canonicalDump(db.reader) == before, "\(name): rows changed by the migration")
            let isHead = name == "\(Migrations.head).sqlite"
            if isHead {
                #expect(report.backup == nil, "\(name): nothing pending, no backup")
            } else {
                let backup = try #require(report.backup, "\(name): no pre-migration backup")
                #expect(backup.lastPathComponent.hasPrefix("pre-\(Migrations.head)-"))
                let q = try openReadOnly(backup)
                #expect(try q.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") } == "ok")
                #expect(try canonicalDump(q) == before, "\(name): backup differs from the original")
            }
            // Chats still open through the app's repositories after the upgrade.
            #expect(try db.read { try ChatRepository.sidebarRequest().fetchCount($0) } == 20, "\(name)")
            at301Log("AT-301 (a) \(name): \(report.applied.last ?? "-") -> \(report.head), backup \(report.backup?.lastPathComponent ?? "none"), \(Int(report.durationMs)) ms")
        }
    }

    // (b)
    @Test func aFailingMigrationRestoresThePreMigrationBackup() throws {
        let from = try #require(Self.fixtureIDs.first { $0 != Migrations.head })
        let dir = try tempContainer()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("antichat.sqlite")
        try FileManager.default.copyItem(at: dbFixtures.appendingPathComponent("\(from).sqlite"), to: url)
        let before = try canonicalDump(try openReadOnly(url))
        var failingRunner = releaseRunner
        failingRunner.testHook_failAt = Migrations.head
        var state: AppLaunchState?
        do { _ = try AppDatabase.open(at: url, runner: failingRunner) } catch StorageError.launchBlocked(let s) { state = s }
        guard case .migrationFailed(_, let backupName)? = state, let backupName else {
            Issue.record("state \(String(describing: state))"); return
        }
        let backup = dir.appendingPathComponent("Backups/\(backupName)")
        #expect(try canonicalDump(try openReadOnly(url)) == before)
        #expect(try canonicalDump(try openReadOnly(url)) == (try canonicalDump(try openReadOnly(backup))))
        let ids = try openReadOnly(url).read { try String.fetchSet($0, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(ids.contains(Migrations.head) == false && ids.contains(from))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Backups").path)
        #expect(names.contains { $0.hasPrefix("failed-") }, "\(names)")
        // The next launch (fixed build) migrates normally.
        let (db, _) = try AppDatabase.open(at: url, runner: releaseRunner)
        #expect(try canonicalDump(db.reader) == before)
        at301Log("AT-301 (b) fail at \(Migrations.head) from \(from): restored, content equal, state migrationFailed")
    }

    // (c)
    @Test(arguments: ["future-v999.sqlite", "future-v999-wal"])
    func newerDataChangesNothing(_ fixture: String) throws {
        let dir = try tempContainer()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dbFixtures.appendingPathComponent(fixture)
        if fixture.hasSuffix("-wal") {
            for f in try FileManager.default.contentsOfDirectory(atPath: src.path) {
                try FileManager.default.copyItem(at: src.appendingPathComponent(f), to: dir.appendingPathComponent(f))
            }
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("antichat.sqlite-wal").path))
        } else {
            try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent("antichat.sqlite"))
        }
        func snapshot() throws -> [String: String] {
            var out: [String: String] = [:]
            for f in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() {
                let u = dir.appendingPathComponent(f)
                let a = try FileManager.default.attributesOfItem(atPath: u.path)
                out[f] = "\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) \(a[.size] ?? 0) \(try sha(u))"
            }
            return out
        }
        let before = try snapshot()
        var state: AppLaunchState?
        do { _ = try AppDatabase.open(at: dir.appendingPathComponent("antichat.sqlite")) } catch StorageError.launchBlocked(let s) { state = s }
        #expect(state == .newerData(unknown: [DBFixtureMaker.futureIdentifier]))
        let after = try snapshot()
        #expect(after == before)
        at301Log("AT-301 (c) \(fixture): newerData, unchanged: " + after.map { "\($0.key)=\($0.value.split(separator: " ").last ?? "")" }.sorted().joined(separator: " "))
    }

    // (d)
    @Test func registrationIsAppendOnlyAgainstTheLock() throws {
        let lines = try String(contentsOf: dbFixtures.appendingPathComponent("migrations.lock"), encoding: .utf8)
            .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        let renames = lines.filter { $0.contains("->") }.map { $0.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespaces) } }
        for r in renames { #expect(Migrations.renamed[r[1]]?.contains(r[0]) == true, "lock rename \(r) not in Migrations.renamed") }
        let locked = lines.filter { !$0.contains("->") }
        #expect(Set(Migrations.identifiers).count == Migrations.identifiers.count, "duplicate identifier")
        #expect(Migrations.identifiers == Migrations.migrator().migrations, "identifiers list ≠ registration")
        // Every locked id is still registered (or renamed, recorded in Migrations.renamed), in the same relative order.
        let resolved = locked.map { id in Migrations.renamed.first { $0.value.contains(id) }?.key ?? id }
        for (old, new) in zip(locked, resolved) where old != new || !Migrations.identifiers.contains(old) {
            #expect(Migrations.identifiers.contains(new), "\(old) disappeared: register its new id with Migrations.renamed")
        }
        let positions = resolved.compactMap { Migrations.identifiers.firstIndex(of: $0) }
        #expect(positions == positions.sorted(), "locked migrations were reordered")
        // Each registered id has a fixture (the DoD of every migration-adding task).
        // (The shared checkout may lag this tree's submodule by the fixtures a branch adds: either has it.)
        let own = repoRoot.appendingPathComponent("fixtures/chats/db")
        for id in Migrations.identifiers {
            #expect([dbFixtures, own].contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("\(id).sqlite").path) },
                    "no fixture for \(id)")
        }
        at301Log("AT-301 (d) lock \(locked.count) ids, registered \(Migrations.identifiers.count), renames \(renames.count): append-only ok")
    }

    @Test func renamedIdentifierIsMergedNotRefused() throws {
        let dir = try tempContainer()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("antichat.sqlite")
        try FileManager.default.copyItem(at: dbFixtures.appendingPathComponent("legacy-m1-v2_tool_permission.sqlite"), to: url)
        let (db, _) = try AppDatabase.open(at: url, runner: releaseRunner)
        let ids = try db.read { try String.fetchSet($0, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(!ids.contains("v2_tool_permission") && ids == Set(Migrations.identifiers))
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tool_permission") } == 1)
        // Same schema as a database created by this build from scratch (no table created twice, none missing).
        let fresh = try AppDatabase.onDisk(at: dir.appendingPathComponent("fresh/antichat.sqlite"), runner: releaseRunner)
        func schema(_ r: any DatabaseReader) throws -> [String] {
            try r.read { try String.fetchAll($0, sql: "SELECT type || ' ' || name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY 1") }
        }
        #expect(try schema(db.reader) == schema(fresh.reader))
    }

    /// Owner try-out guard: any open failure (newer data, an unknown/garbage file, a failed migration) maps to a
    /// visible blocking window, never `.ready` on a silent in-memory database; the file is left untouched.
    @Test func openFailureIsNeverASilentInMemoryLaunch() throws {
        let dir = try tempContainer()
        defer { try? FileManager.default.removeItem(at: dir) }
        let future = dir.appendingPathComponent("future/antichat.sqlite")
        try FileManager.default.createDirectory(at: future.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dbFixtures.appendingPathComponent("future-v999.sqlite"), to: future)
        let garbage = dir.appendingPathComponent("garbage/antichat.sqlite")
        try FileManager.default.createDirectory(at: garbage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a database, unknown schema".utf8).write(to: garbage)
        for url in [future, garbage] {
            let before = try sha(url)
            var state = AppLaunchState.ready
            do { _ = try AppDatabase.open(at: url, runner: releaseRunner) } catch { state = AppLaunchState.blocking(for: error) }
            #expect(state != .ready, "\(url.path) opened or mapped to .ready")
            #expect(try sha(url) == before, "\(url.lastPathComponent) changed")
        }
        for error: any Error in [StorageError.launchBlocked(.ready), StorageError.supersededByNewerVersion,
                                 StorageError.migrationFailed("x"), CocoaError(.fileReadCorruptFile)] {
            #expect(AppLaunchState.blocking(for: error) != .ready)
        }
    }

    @Test func freshFileGetsNoBackupAndNoSpaceBlocksTheMigration() throws {
        let dir = try tempContainer()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, report) = try AppDatabase.open(at: dir.appendingPathComponent("antichat.sqlite"))
        #expect(report.backup == nil && report.applied.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Backups").path))
        let from = try #require(Self.fixtureIDs.first)
        let url = dir.appendingPathComponent("old/antichat.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dbFixtures.appendingPathComponent("\(from).sqlite"), to: url)
        let tight = MigrationRunner(eraseOnSchemaChange: false, freeSpace: { _ in 1024 })
        var state: AppLaunchState?
        do { _ = try AppDatabase.open(at: url, runner: tight) } catch StorageError.launchBlocked(let s) { state = s }
        guard case .backupNoSpace(let need)? = state else { Issue.record("\(String(describing: state))"); return }
        #expect(need > 1024)
        let ids = try openReadOnly(url).read { try String.fetchSet($0, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(ids == [from], "migrated without a backup")
    }
}
