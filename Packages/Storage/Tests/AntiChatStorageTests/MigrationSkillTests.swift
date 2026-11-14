// M7.T12 definition of done: `v29_skill_flags` adds `skill` (architecture §5.1 + apply_all, content_hash, embedding),
// the down step restores the previous schema exactly, the pre-migration backup is written, and the repository
// round-trips (upsert by name keeps the id and the switches).
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

@Suite struct MigrationSkillTests {
    @Test func upThenDownRestoresThePreviousSchema() throws {
        let q = try DatabaseQueue()
        var m = Migrations.migrator()
        m.eraseDatabaseOnSchemaChange = false
        let previous = Migrations.identifiers[Migrations.identifiers.firstIndex(of: "v29_skill_flags")! - 1]
        try m.migrate(q, upTo: previous)
        let before = try q.read(schemaDump)
        try m.migrate(q, upTo: "v29_skill_flags")
        let cols = try q.read { db in try db.columns(in: "skill").map(\.name) }
        for c in ["id", "name", "path", "enabled", "manifest_json", "trust", "script_policy", "apply_all", "content_hash",
                  "embedding", "created_at", "updated_at"] {
            #expect(cols.contains(c), "missing \(c)")
        }
        // Apply to every chat is off by default (R-082 AC3); scripts never run by default (R-265).
        try q.write { db in
            try db.execute(sql: "INSERT INTO skill (id, name, path, created_at, updated_at) VALUES ('a', 'x', 'x', 0, 0)")
        }
        #expect(try q.read { try Bool.fetchOne($0, sql: "SELECT apply_all FROM skill") } == false)
        #expect(try q.read { try String.fetchOne($0, sql: "SELECT script_policy FROM skill") } == "never")
        try q.write { try Migrations.v29SkillFlagsDown($0) }
        #expect(try q.read(schemaDump) == before)
        #expect(try q.read { try m.appliedIdentifiers($0) }.contains("v29_skill_flags") == false)
    }

    /// The migration backup: a database at the previous head is copied to `Backups/pre-v29_skill_flags-…` before
    /// `v29_skill_flags` runs (MigrationRunner, M8.T01), and the copy still has no `skill` table.
    @Test func migratingToV29WritesABackupFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skill-mig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("antichat.sqlite")
        do {
            let q = try DatabaseQueue(path: url.path)
            var m = Migrations.migrator()
            m.eraseDatabaseOnSchemaChange = false
            try m.migrate(q, upTo: Migrations.identifiers[Migrations.identifiers.firstIndex(of: "v29_skill_flags")! - 1])
            try q.close()
        }
        let (db, report) = try AppDatabase.open(at: url, runner: MigrationRunner(eraseOnSchemaChange: false))
        #expect(try db.read { try $0.tableExists("skill") })
        let backup = try #require(report.backup)
        #expect(backup.lastPathComponent.hasPrefix("pre-\(Migrations.identifiers.last!)"))  // named after the target (latest) migration
        let copy = try DatabaseQueue(path: backup.path)
        #expect(try copy.read { try $0.tableExists("skill") } == false)
    }

    @Test func repositoryUpsertKeepsIdAndSwitches() throws {
        let db = try AppDatabase.inMemory()
        let repo = SkillRepository(db)
        #expect(try repo.all().isEmpty)
        let first = try repo.upsert(SkillRecord(name: "email-polish", trust: .bundled))
        try repo.update("email-polish") { $0.applyAll = true; $0.enabled = false }
        let again = try repo.upsert(SkillRecord(name: "email-polish", contentHash: "new"))
        #expect(again.id == first.id)
        let row = try #require(try repo.skill(named: "email-polish"))
        #expect(row.contentHash == "new")
        #expect(row.applyAll == true && row.enabled == false, "a re-import keeps the user's switches")
        try repo.delete("email-polish")
        #expect(try repo.all().isEmpty)
    }
}
