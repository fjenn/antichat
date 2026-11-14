// AT-NFR-S3 (no main-thread stall > 2 s): the main thread's chat writes (unread on open, the auto title mid-reply)
// are enqueued on the writer and never wait for it. The 8-h soak stalled up to 4.4 s on synchronous writes queued
// behind a busy writer. These tests hold the writer from another thread and check the calls return at once, the writes
// land in order, and the title still never overwrites a rename.
//   make test-unit FILTER=WriteLaterTests
import Foundation
import GRDB
import Synchronization
import Testing
@testable import AntiChatStorage

@Suite struct WriteLaterTests {
    private func pool() throws -> (AppDatabase, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("write-later-\(UUID().uuidString)",
                                                                                isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite")), dir)
    }

    private func holdWriter(_ db: AppDatabase, seconds: Double) async {
        let held = Mutex(false)
        Thread.detachNewThread {
            try? db.write { _ in
                held.withLock { $0 = true }
                Thread.sleep(forTimeInterval: seconds)
            }
        }
        let end = Date().addingTimeInterval(5)
        while !held.withLock({ $0 }), Date() < end { try? await Task.sleep(for: .milliseconds(2)) }
    }

    private func barrier(_ db: AppDatabase) throws { try db.write { _ in } }

    @Test func unreadAndTitleReturnAtOnceWhileTheWriterIsHeld() async throws {
        let (db, dir) = try pool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chats = ChatRepository(db)
        let a = try chats.create(temporaryTitle: "temp a")
        try chats.setUnread(a.id, true)
        await holdWriter(db, seconds: 0.6)
        let applied = Mutex<Bool?>(nil)
        let t0 = Date()
        chats.setUnreadLater(a.id, false)
        chats.applyAutoTitleLater(a.id, title: "Auto A") { ok in applied.withLock { $0 = ok } }
        let took = Date().timeIntervalSince(t0)
        #expect(took < 0.2, "returned in \(took) s with the writer held")
        try barrier(db)
        let row = try #require(try chats.chat(a.id))
        #expect(row.unread == false)
        #expect(row.title == "Auto A")
        #expect(applied.withLock { $0 } == true)
    }

    @Test func autoTitleLaterKeepsARename() async throws {
        let (db, dir) = try pool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chats = ChatRepository(db)
        let a = try chats.create(temporaryTitle: "temp a")
        try db.write { try $0.execute(sql: "UPDATE chat SET title = 'Mine', title_state = 'user' WHERE id = ?", arguments: [a.id]) }
        let applied = Mutex<Bool?>(nil)
        chats.applyAutoTitleLater(a.id, title: "Auto A") { ok in applied.withLock { $0 = ok } }
        try barrier(db)
        #expect(try chats.chat(a.id)?.title == "Mine")
        #expect(applied.withLock { $0 } == false)
    }

    /// S3 review: the re-title after a first-prompt edit returns at once with the writer held, sets the temporary title
    /// pending again, and never overwrites a title the user set.
    @Test func retitlePendingLaterReturnsAtOnceAndKeepsARename() async throws {
        let (db, dir) = try pool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chats = ChatRepository(db)
        let a = try chats.create(temporaryTitle: "temp a")
        _ = try chats.applyAutoTitle(a.id, title: "Auto A")
        let b = try chats.create(temporaryTitle: "temp b")
        try chats.rename(b.id, title: "Mine")
        await holdWriter(db, seconds: 0.6)
        let applied = Mutex<[String: Bool]>([:])
        let t0 = Date()
        chats.retitlePendingLater(a.id, title: "Edited a") { ok in applied.withLock { $0[a.id] = ok } }
        chats.retitlePendingLater(b.id, title: "Edited b") { ok in applied.withLock { $0[b.id] = ok } }
        let took = Date().timeIntervalSince(t0)
        #expect(took < 0.2, "returned in \(took) s with the writer held")
        try barrier(db)
        let rowA = try #require(try chats.chat(a.id)), rowB = try #require(try chats.chat(b.id))
        #expect(rowA.title == "Edited a" && rowA.titleState == .pending)
        #expect(rowB.title == "Mine" && rowB.titleState == .user)
        #expect(applied.withLock { $0 } == [a.id: true, b.id: false])
    }

    /// Writes keep their order on the writer's queue: an enqueued write lands before a later synchronous one.
    @Test func writeLaterKeepsOrder() throws {
        let (db, dir) = try pool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chats = ChatRepository(db)
        let a = try chats.create(temporaryTitle: "temp")
        chats.setUnreadLater(a.id, true)
        try chats.setUnread(a.id, false)
        #expect(try chats.chat(a.id)?.unread == false)
    }
}
