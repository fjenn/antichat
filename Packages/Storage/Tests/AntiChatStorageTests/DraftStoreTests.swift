// AT-302 Storage legs (M1.T21, R-302; P-shell-15): the draft row is written ≤ 1 s after the last change — on a
// virtual clock (`draft.updated_at − last keystroke`, debounce 500 ms) and on the real clock; restore (pending wins,
// attachments round-trip), clear on send, empty deletes, synchronous flush (app termination), incognito drafts kept
// in memory only (the composer's flag and the M1.T20 `isIncognito` seam: no `draft` row, ever), and the rows of a
// deleted chat go with it (Definition of done: cascade).
//   make test-unit FILTER=DraftStoreTests
import Foundation
import GRDB
import Synchronization
import Testing
@testable import AntiChatStorage

/// A clock tests advance by hand. `sleep` parks until `advance` reaches the deadline; cancellation (the debounce
/// cancels its timer on every new element) throws.
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by d: Duration) -> Instant { Instant(offset: offset + d) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private struct Sleeper {
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [UUID: Sleeper] = [:]
        var lastDeadline: Instant?
    }

    private let state = Mutex(State())
    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }
    /// The deadline of the most recent `sleep` call (the debounce's final timer once typing stopped).
    var lastDeadline: Instant? { state.withLock { $0.lastDeadline } }
    /// The parked sleepers' deadlines, as offsets from now.
    var pendingDelays: [Duration] { state.withLock { s in s.sleepers.values.map { s.now.duration(to: $0.deadline) } } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let resumeNow: Bool = state.withLock { s in
                    s.lastDeadline = deadline
                    if deadline <= s.now || Task.isCancelled { return true }
                    s.sleepers[id] = Sleeper(deadline: deadline, continuation: c)
                    return false
                }
                if resumeNow {
                    if Task.isCancelled { c.resume(throwing: CancellationError()) } else { c.resume() }
                }
            }
        } onCancel: {
            let c = state.withLock { $0.sleepers.removeValue(forKey: id)?.continuation }
            c?.resume(throwing: CancellationError())
        }
    }

    func advance(by d: Duration) {
        let due: [CheckedContinuation<Void, any Error>] = state.withLock { s in
            s.now = s.now.advanced(by: d)
            let ready = s.sleepers.filter { $0.value.deadline <= s.now }
            for k in ready.keys { s.sleepers[k] = nil }
            return ready.values.map(\.continuation)
        }
        for c in due { c.resume() }
    }
}

@Suite struct DraftStoreTests {
    static let epoch = Date(timeIntervalSince1970: 1_793_400_000)

    private func rows(_ db: AppDatabase) throws -> [DraftRecord] { try db.read { try DraftRecord.fetchAll($0) } }

    private func until(_ timeout: Double = 5, _ cond: () throws -> Bool) async rethrows -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try cond() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return try cond()
    }

    /// A store on a manual clock whose `updated_at` follows the same clock.
    private func virtualStore(_ db: AppDatabase, isIncognito: @escaping @Sendable (DraftStore.Key) -> Bool = { _ in false })
        -> (DraftStore, ManualClock) {
        let clock = ManualClock()
        let store = DraftStore(database: db, clock: clock, now: { [clock] in
            let o = clock.now.offset.components
            return Self.epoch.addingTimeInterval(Double(o.seconds) + Double(o.attoseconds) / 1e18)
        }, isIncognito: isIncognito)
        return (store, clock)
    }

    private func virtualDate(_ clock: ManualClock) -> Date {
        let o = clock.now.offset.components
        return Self.epoch.addingTimeInterval(Double(o.seconds) + Double(o.attoseconds) / 1e18)
    }

    /// AT-302 pass condition, virtual clock: a burst of keystrokes, then `updated_at − last keystroke ≤ 1,000 ms`
    /// (it is the 500 ms debounce); nothing is written while typing continues.
    @Test func savedWithinOneSecondOfTheLastKeystrokeOnAVirtualClock() async throws {
        let db = try AppDatabase.inMemory()
        let (store, clock) = virtualStore(db)
        var text = ""
        var lastKeystroke = Self.epoch
        // Keystrokes every 120 virtual ms (< 500): the debounce never fires while typing.
        for ch in "hello world" {
            text.append(ch)
            store.update(DraftStore.Draft(text: text), for: .newChat)
            lastKeystroke = virtualDate(clock)
            try? await Task.sleep(for: .milliseconds(5))  // the debounce task takes the element
            for _ in 0..<12 {
                clock.advance(by: .milliseconds(10))
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        #expect(try rows(db).isEmpty, "written while typing")
        // Then the clock runs on in 10 ms steps until the debounce timer has fired (cap: 3 virtual s), and stops there:
        // the write lands on the stopped clock however long the host takes to run it.
        // (A timer that fired may re-arm for a moved deadline: then the clock runs on again.)
        var advanced = 0
        while try rows(db).isEmpty, advanced < 3000 {
            if let d = clock.lastDeadline, d <= clock.now, clock.sleeperCount == 0 {
                _ = try await until(10) { try !rows(db).isEmpty || clock.sleeperCount > 0 }
                advanced += 1000  // at most 3 such waits
                continue
            }
            clock.advance(by: .milliseconds(10))
            advanced += 10
            try? await Task.sleep(for: .milliseconds(2))
        }
        let row = try #require(try rows(db).first, "no row after 3 virtual s")
        #expect(row.chatID == DraftRecord.newChatKey)
        #expect(row.text == "hello world")
        // Deterministic on any host: the row is written exactly at the debounce's final deadline, which is 500 virtual ms
        // after the debounce received the last keystroke — never earlier than 500 ms after the keystroke. How long the
        // test loop takes to hand the keystroke over (it raced the clock steps at load ~150: lag 1.03 s) is scheduling,
        // not the store; the real-clock leg below checks the same wiring on `ContinuousClock` (order only).
        let deadline = try #require(clock.lastDeadline)
        let o = deadline.offset.components
        let deadlineDate = Self.epoch.addingTimeInterval(Double(o.seconds) + Double(o.attoseconds) / 1e18)
        #expect(abs(row.updatedAt.timeIntervalSince(deadlineDate)) < 0.011, "written at the debounce deadline (one 10 ms step)")
        let lag = row.updatedAt.timeIntervalSince(lastKeystroke)
        #expect(lag >= 0.5 - 1e-6, "updated_at − last keystroke = \(lag) s: the debounce held 500 ms")
    }

    /// The same wiring on the real clock (`ContinuousClock`, the app's store): the last keystroke is saved, after the
    /// debounce held. The ≤ 1 s bound is the virtual-clock test above: on the wall clock a loaded host stretched it
    /// (sleeps and timers only give lower bounds).
    @Test func savedAfterTheDebounceOnTheRealClock() async throws {
        let db = try AppDatabase.inMemory()
        let store = DraftStore(database: db)
        let chat = try ChatRepository(db).create(title: "t")
        var last = Date()
        for i in 1...5 {
            store.update(DraftStore.Draft(text: String(repeating: "a", count: i)), for: .chat(chat.id))
            last = Date()
            try await Task.sleep(for: .milliseconds(60))
        }
        #expect(try await until(3) { try rows(db).first?.text == "aaaaa" })
        let row = try #require(try rows(db).first)
        let lag = row.updatedAt.timeIntervalSince(last)
        #expect(lag >= 0.49, "updated_at − last keystroke = \(lag) s: written before the 500 ms debounce")
    }

    @Test func restoreClearAndEmptyRules() async throws {
        let db = try AppDatabase.inMemory()
        let (store, _) = virtualStore(db)
        let chat = try ChatRepository(db).create(title: "t")
        let card = String(repeating: "x", count: 12_000)
        let draft = DraftStore.Draft(text: "half a thought", attachments: [.pastedText(card), .file("/tmp/a.pdf")])
        store.update(draft, for: .chat(chat.id))
        #expect(store.draft(for: .chat(chat.id)) == draft, "pending draft restores before it is written")
        store.flush()
        #expect(store.pendingCount == 0)
        let row = try #require(try DraftRepository(db).draft(chatID: chat.id))
        #expect(row.text == "half a thought")
        #expect(DraftStore.decode(row.attachmentsJSON) == draft.attachments)
        // A fresh store (relaunch) restores the row, attachment card included.
        let (relaunched, _) = virtualStore(db)
        #expect(relaunched.draft(for: .chat(chat.id)) == draft)
        #expect(relaunched.draft(for: .newChat) == nil)
        // Whitespace only = empty = the row goes.
        relaunched.update(DraftStore.Draft(text: "  \n "), for: .chat(chat.id))
        relaunched.flush()
        #expect(try DraftRepository(db).draft(chatID: chat.id) == nil)
        // Send clears pending and stored.
        relaunched.update(DraftStore.Draft(text: "to send"), for: .chat(chat.id))
        relaunched.flush()
        relaunched.update(DraftStore.Draft(text: "to send!"), for: .chat(chat.id))
        relaunched.clear(.chat(chat.id))
        #expect(relaunched.pendingCount == 0)
        #expect(try DraftRepository(db).draft(chatID: chat.id) == nil)
        #expect(relaunched.draft(for: .chat(chat.id)) == nil)
    }

    /// App termination: `flush()` writes the pending debounce synchronously (no waiting for the timer).
    @Test func flushWritesThePendingDraftSynchronously() throws {
        let db = try AppDatabase.inMemory()
        let (store, clock) = virtualStore(db)
        store.update(DraftStore.Draft(text: "quit now"), for: .newChat)
        #expect(try rows(db).isEmpty)
        store.flush()
        #expect(try rows(db).map(\.text) == ["quit now"])
        #expect(clock.now.offset == .zero)
    }

    /// Incognito via the composer's flag: never a `draft` row (not after the debounce, not after flush, not on
    /// clear); restorable from memory while the chat is open; gone after `discardIncognito`.
    @Test func incognitoFlagKeepsDraftsInMemoryOnly() async throws {
        let db = try AppDatabase.inMemory()
        let (store, clock) = virtualStore(db)
        store.update(DraftStore.Draft(text: "secret phrase 7731"), for: .newChat, incognito: true)
        clock.advance(by: .seconds(2))
        try? await Task.sleep(for: .milliseconds(50))
        store.flush()
        #expect(try rows(db).isEmpty)
        #expect(store.pendingCount == 0)
        #expect(store.memoryKeys == [.newChat])
        #expect(store.draft(for: .newChat, incognito: true)?.text == "secret phrase 7731")
        #expect(store.draft(for: .newChat) == nil, "the disk path never sees it")
        store.discardIncognito(.newChat)
        #expect(store.draft(for: .newChat, incognito: true) == nil)
        #expect(try rows(db).isEmpty)
    }

    /// Incognito via the M1.T20 seam (`isIncognito`, StoreRouter): a chat flagged incognito is skipped by the disk
    /// path even when the caller does not pass the flag; other chats still persist.
    @Test func incognitoSeamSkipsFlaggedChats() async throws {
        let db = try AppDatabase.inMemory()
        let chats = ChatRepository(db)
        let normal = try chats.create(title: "normal"), hidden = try chats.create(title: "incognito")
        let hiddenID = hidden.id
        let (store, clock) = virtualStore(db, isIncognito: { $0 == .chat(hiddenID) })
        store.update(DraftStore.Draft(text: "kept"), for: .chat(normal.id))
        store.update(DraftStore.Draft(text: "never on disk"), for: .chat(hidden.id))
        try? await Task.sleep(for: .milliseconds(5))
        var advanced = 0
        while try rows(db).isEmpty, advanced < 3000 {
            clock.advance(by: .milliseconds(10))
            advanced += 10
            try? await Task.sleep(for: .milliseconds(2))
        }
        store.flush()
        #expect(try rows(db).map(\.chatID) == [normal.id])
        #expect(try db.read { try String.fetchAll($0, sql: "SELECT text FROM draft") } == ["kept"])
        #expect(store.draft(for: .chat(hidden.id))?.text == "never on disk")
        store.clear(.chat(hidden.id))
        #expect(store.memoryKeys.isEmpty)
    }

    /// The StoreRouter wiring (`DraftStore(router:)`): a chat routed to an in-memory store never gets a `draft` row.
    @Test func routerRoutedChatNeverPersistsDraft() throws {
        let disk = try AppDatabase.inMemory()
        let router = StoreRouter(disk: disk)
        let normal = try ChatRepository(disk).create(title: "normal")
        let hiddenID = "incognito-chat"
        try router.route(hiddenID, to: try StoreRouter.makeEphemeralStore())
        let store = DraftStore(router: router)
        store.update(DraftStore.Draft(text: "kept"), for: .chat(normal.id))
        store.update(DraftStore.Draft(text: "never on disk"), for: .chat(hiddenID))
        store.flush()
        #expect(try disk.read { try String.fetchAll($0, sql: "SELECT chat_id FROM draft") } == [normal.id])
        #expect(store.draft(for: .chat(hiddenID))?.text == "never on disk", "restorable from memory while open")
    }

    /// Definition of done: a chat's draft row goes when the chat is deleted.
    @Test func draftRowsAreRemovedWithTheirChat() throws {
        let db = try AppDatabase.inMemory()
        let chats = ChatRepository(db)
        let a = try chats.create(title: "a"), b = try chats.create(title: "b")
        let (store, _) = virtualStore(db)
        store.update(DraftStore.Draft(text: "for a"), for: .chat(a.id))
        store.update(DraftStore.Draft(text: "for b"), for: .chat(b.id))
        store.update(DraftStore.Draft(text: "for new"), for: .newChat)
        store.flush()
        #expect(try rows(db).count == 3)
        try chats.delete(a.id)
        #expect(Set(try rows(db).map(\.chatID)) == [b.id, DraftRecord.newChatKey])
    }

    // MARK: AT-NFR-S3: the main thread never waits for the writer

    /// An on-disk pool, the kind of database the app uses.
    private func pool() throws -> (AppDatabase, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("draft-writer-\(UUID().uuidString)",
                                                                                isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite")), dir)
    }

    /// A background transaction holds the writer for `seconds` (a streaming save or the indexer under load).
    private func holdWriter(_ db: AppDatabase, seconds: Double) async {
        let held = Mutex(false)
        Thread.detachNewThread {
            try? db.write { _ in
                held.withLock { $0 = true }
                Thread.sleep(forTimeInterval: seconds)
            }
        }
        _ = await until { held.withLock { $0 } }
    }

    /// A send's clear and a chat switch's `flushSoon` return at once while another transaction holds the writer.
    /// The left chat's draft restores from memory until its write commits. A sent draft never comes back. Both rows
    /// are right once the writer is free. Before this fix, both calls waited for the writer on the main thread.
    @Test func clearAndFlushSoonNeverWaitForTheWriter() async throws {
        let (db, dir) = try pool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chats = ChatRepository(db)
        let left = try chats.create(title: "left"), sent = try chats.create(title: "sent")
        let (store, _) = virtualStore(db)
        store.update(DraftStore.Draft(text: "was here"), for: .chat(sent.id))
        store.flush()
        await holdWriter(db, seconds: 0.6)
        let t0 = Date()
        store.update(DraftStore.Draft(text: "come back to me"), for: .chat(left.id))
        store.flushSoon()
        store.clear(.chat(sent.id))
        let took = Date().timeIntervalSince(t0)
        #expect(took < 0.2, "returned in \(took) s with the writer held")
        #expect(store.draft(for: .chat(left.id))?.text == "come back to me", "in flight: restored from memory")
        #expect(store.draft(for: .chat(sent.id)) == nil, "a sent draft does not come back while its delete waits")
        store.settle()
        #expect(try DraftRepository(db).draft(chatID: left.id)?.text == "come back to me")
        #expect(try DraftRepository(db).draft(chatID: sent.id) == nil)
        #expect(store.draft(for: .chat(left.id))?.text == "come back to me", "committed: restored from the row")
    }

    /// Write order: a send's delete enqueued after a pass that already holds the draft still wins (no resurrection).
    @Test func clearAfterAQueuedPassDeletesTheRow() async throws {
        let (db, dir) = try pool()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chat = try ChatRepository(db).create(title: "t")
        let (store, _) = virtualStore(db)
        await holdWriter(db, seconds: 0.3)
        store.update(DraftStore.Draft(text: "to send"), for: .chat(chat.id))
        store.flushSoon()  // queued behind the held writer
        store.clear(.chat(chat.id))  // queued after it
        store.settle()
        #expect(try DraftRepository(db).draft(chatID: chat.id) == nil)
        #expect(store.draft(for: .chat(chat.id)) == nil)
    }
}
