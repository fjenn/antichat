// M1.T22 step 5 (R-011 AC4): Archived chats operations (archive all, delete all, unarchive, search filter) and the
// daily auto-archive run on a virtual clock: Never by default; 30 days archives a chat inactive 31 days on the
// next daily run, never one inactive 29 days at the run, and runs at most once per 24 h.
import AntiChatStorage
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

@MainActor
@Suite struct AutoArchiveServiceTests {
    /// A chat whose last activity is `days` days before `now`.
    func chat(_ s: ChatListService, _ title: String, inactiveDays days: Double, now: Date) throws -> String {
        let c = try s.create(title: title)
        let t = now.addingTimeInterval(-days * 86_400).timeIntervalSince1970
        try s.database.write { db in
            try db.execute(sql: "UPDATE chat SET updated_at = ?, created_at = ? WHERE id = ?", arguments: [t, t, c.id])
        }
        return c.id
    }

    final class Clock: @unchecked Sendable {
        let state: Mutex<Date>
        init(_ d: Date) { state = Mutex(d) }
        var now: Date { state.withLock { $0 } }
        func advance(_ s: TimeInterval) { state.withLock { $0 = $0.addingTimeInterval(s) } }
    }

    final class Store: @unchecked Sendable {
        let days = Mutex(0)
        let last = Mutex<Date?>(nil)
    }

    @Test func neverByDefaultThenThirtyDaysOnTheNextDailyRun() throws {
        let s = try ChatListService.inMemory()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let clock = Clock(start)
        let store = Store()
        let old = try chat(s, "Old", inactiveDays: 31, now: start)
        let recent = try chat(s, "Recent", inactiveDays: 28, now: start)  // 29 days at the run
        let service = AutoArchiveService(
            chats: s, now: { clock.now }, days: { store.days.withLock { $0 } },
            lastRun: { store.last.withLock { $0 } }, saveLastRun: { d in store.last.withLock { $0 = d } })

        // Never (default): the daily run archives nothing.
        #expect(service.runIfDue().isEmpty)
        #expect(try s.archived().isEmpty)

        // Setting 30 days: nothing happens until the next daily run.
        store.days.withLock { $0 = 30 }
        clock.advance(3600)
        #expect(!service.isDue(at: clock.now))
        #expect(service.runIfDue().isEmpty)
        #expect(try s.archived().isEmpty)

        // Next daily run (+24 h): only the chat inactive ≥ 30 days is archived.
        clock.advance(86_400)
        #expect(service.runIfDue() == [old])
        #expect(try s.archived().map(\.id) == [old])
        #expect(try s.chat(recent) != nil)
        #expect(try s.sidebarCount() == 1)
        // Same day again: not due.
        #expect(service.runIfDue().isEmpty)
    }

    @Test func archiveAllDeleteAllAndUnarchive() throws {
        let s = try ChatListService.inMemory()
        let ids = try (0..<5).map { try s.create(title: "Chat \($0)").id }
        try s.archive([ids[0]])
        #expect(try s.archiveAll() == 4)
        #expect(try s.sidebarCount() == 0)
        #expect(Set(try s.archived().map(\.id)) == Set(ids))
        try s.unarchive(ids[2])
        #expect(try s.sidebarCount() == 1)
        #expect(try s.deleteAll() == 5)
        #expect(try s.totalCount() == 0)
    }

    @Test func archivedSearchFiltersByTitle() {
        let at = Date()
        let rows = [ArchivedChat(id: "a", title: "Trip to Lisbon", archivedAt: at, updatedAt: at),
                    ArchivedChat(id: "b", title: "Tax return", archivedAt: at, updatedAt: at),
                    ArchivedChat(id: "c", title: "", archivedAt: at, updatedAt: at)]
        #expect(ArchivedChat.filter(rows, query: "", untitled: "New chat").count == 3)
        #expect(ArchivedChat.filter(rows, query: "lisb", untitled: "New chat").map(\.id) == ["a"])
        #expect(ArchivedChat.filter(rows, query: "TAX", untitled: "New chat").map(\.id) == ["b"])
        #expect(ArchivedChat.filter(rows, query: "new", untitled: "New chat").map(\.id) == ["c"])
    }

    @Test func observeArchivedDeliversChanges() async throws {
        let s = try ChatListService.inMemory()
        let a = try s.create(title: "A")
        var latest: [ArchivedChat] = []
        let token = s.observeArchived { latest = $0 }
        defer { token.cancel() }
        try s.archive([a.id])
        for _ in 0..<400 where latest.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(latest.map(\.id) == [a.id])
        try s.unarchive(a.id)
        for _ in 0..<400 where !latest.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(latest.isEmpty)
    }
}
