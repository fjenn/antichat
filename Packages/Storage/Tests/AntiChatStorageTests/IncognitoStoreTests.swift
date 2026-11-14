// M1.T20 (R-090, NFR-PR3): StoreRouter sends an incognito chat's records to an in-memory store; the on-disk
// database file, its WAL/SHM and the container directory stay byte-identical while that chat is written.
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

@Suite struct IncognitoStoreTests {
    private func container() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("incognito-store-\(UUID().uuidString)",
                                                                              isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func snapshot(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            out[name] = try Data(contentsOf: dir.appendingPathComponent(name))
        }
        return out
    }

    @Test func ephemeralStoreIsMemoryOnlyWithMemoryTempTables() throws {
        let store = try StoreRouter.makeEphemeralStore()
        #expect(store.isInMemory)
        let tempStore = try store.read { db in try Int.fetchOne(db, sql: "PRAGMA temp_store") }
        #expect(tempStore == 2)  // MEMORY
        let file = try store.read { db in try String.fetchOne(db, sql: "SELECT file FROM pragma_database_list WHERE name = 'main'") }
        #expect((file ?? "").isEmpty)
        // Same migrations as the disk database.
        let tables = try store.read { db in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") }
        #expect(tables.contains("chat") && tables.contains("message") && tables.contains("draft"))
    }

    @Test func routesChatsAndRefusesAnOnDiskStore() throws {
        let dir = container()
        defer { try? FileManager.default.removeItem(at: dir) }
        let disk = try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite"))
        let router = StoreRouter(disk: disk)
        let mem = try StoreRouter.makeEphemeralStore()
        #expect(throws: StorageError.self) { try router.route("x", to: disk) }
        try router.route("incog", to: mem)
        #expect(router.database(for: "incog") === mem)
        #expect(router.database(for: "other") === disk)
        #expect(router.database(for: nil) === disk)
        #expect(router.isEphemeral("incog"))
        #expect(!router.persistsDrafts(for: "incog"))
        #expect(router.persistsDrafts(for: "other"))
        router.release(store: mem)
        #expect(!router.isEphemeral("incog"))
        #expect(router.database(for: "incog") === disk)
    }

    @Test func writingAnIncognitoChatLeavesTheDiskFilesIdentical() throws {
        let dir = container()
        defer { try? FileManager.default.removeItem(at: dir) }
        let disk = try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite"))
        let normal = try ChatRepository(disk).create(title: "normal")
        _ = try disk.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat") }
        let before = try snapshot(dir)
        let router = StoreRouter(disk: disk)
        let mem = try StoreRouter.makeEphemeralStore()
        let chat = try ChatRepository(mem).create(title: "")
        try router.route(chat.id, to: mem)
        let db = router.database(for: chat.id)
        for i in 0..<50 {
            try db.write { d in
                let leaf = try ChatRecord.fetchOne(d, key: chat.id)?.leafMessageID
                _ = try MessageTree.append(chatID: chat.id, parentID: leaf, role: i % 2 == 0 ? .user : .assistant,
                                           status: .done, parts: [.text("zephyrquartz secret \(i) " + String(repeating: "y", count: 4_000))],
                                           configure: { _ in }, db: d)
            }
        }
        // A large sort in the incognito store (temp_store=MEMORY: no spill file).
        _ = try db.read { d in try Row.fetchAll(d, sql: "SELECT * FROM message ORDER BY created_at DESC, id") }
        #expect(try snapshot(dir) == before)
        #expect(try ChatRepository(disk).chat(chat.id) == nil)
        #expect(try ChatRepository(disk).chat(normal.id) != nil)
        let hits = try disk.read { d in try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH 'zephyrquartz'") }
        #expect(hits == 0)
    }
}
