// M8.T03 AT-246 (R-246 AC1/AC2): (a) default off on T0/T1, on T2–T4; (b) gates: battery, idle 299 s vs 300 s, Low
// Power Mode, a running turn, thermal, 6 h spacing; (c) a run with a scripted model returning 3 facts writes 3
// pending suggestions and zero memory_item rows (a TransactionObserver counts inserts during the run); (d) Save →
// one active item (origin review), Dismiss → dismissed.
//   make test-unit FILTER=MemoryReviewServiceTests
import AntiChatStorage
import Foundation
import GRDB
import Synchronization
import Testing
@testable import AntiChatKnowledge

struct FakePower: PowerSource { var onACPower = true; var lowPowerMode = false }
struct FakeIdle: IdleClock { var idleSeconds: Double = 600 }
struct FakeThermal: ThermalSource { var isFairOrBetter = true }

final class ItemInsertCounter: TransactionObserver, @unchecked Sendable {
    let count = Mutex(0)
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        if case .insert(let table) = eventKind { return table == "memory_item" }
        return false
    }
    func databaseDidChange(with event: DatabaseEvent) { count.withLock { $0 += 1 } }
    func databaseDidCommit(_ db: Database) {}
    func databaseDidRollback(_ db: Database) {}
}

@Suite struct MemoryReviewServiceTests {
    static let facts = #"[{"topic":"Music","text":"Plays jazz piano","sensitive_category":"none"},{"topic":"Work","text":"Works as a nurse on nights","sensitive_category":"none"},{"topic":"Food","text":"Cooks vegetarian food","sensitive_category":"none"},{"topic":"Health","text":"Has asthma since childhood","sensitive_category":"health"},{"topic":"X","text":"short"}]"#

    func gates(_ power: FakePower = FakePower(), idle: Double = 600, busy: Bool = false, thermal: Bool = true,
               policy: MemoryPolicy = MemoryPolicy(), enabled: Bool = true) -> MemoryReviewService.Gates {
        MemoryReviewService.Gates(enabled: enabled, policy: policy, power: power, idle: FakeIdle(idleSeconds: idle),
                                  thermal: FakeThermal(isFairOrBetter: thermal), busy: { busy })
    }

    func seeded() throws -> (AppDatabase, MemoryStore) {
        let (db, store) = try memoryDB()
        try db.write { d in
            try d.execute(sql: "UPDATE chat SET updated_at = 100 WHERE id = 'c1'")
            try d.execute(sql: "INSERT INTO message (id, chat_id, role, created_at) VALUES ('u1', 'c1', 'user', 1)")
            try d.execute(sql: "INSERT INTO message_part (message_id, idx, kind, body) VALUES ('u1', 0, 'text', 'I play jazz piano and work nights as a nurse')")
        }
        return (db, store)
    }

    @Test func defaultsByTier() {
        #expect(!MemoryReviewService.defaultEnabled(tier: "T0") && !MemoryReviewService.defaultEnabled(tier: "T1"))
        #expect(["T2", "T3", "T4"].allSatisfy(MemoryReviewService.defaultEnabled(tier:)))
    }

    @Test func gates() throws {
        let (_, store) = try memoryDB()
        let s = MemoryReviewService(store: store, model: nil, embedder: nil)
        #expect(s.skipReason(gates(FakePower(onACPower: false)), lastRun: nil) == .battery)
        #expect(s.skipReason(gates(idle: 299), lastRun: nil) == .notIdle)
        #expect(s.skipReason(gates(idle: 300), lastRun: nil) == nil)
        #expect(s.skipReason(gates(FakePower(lowPowerMode: true)), lastRun: nil) == .lowPower)
        #expect(s.skipReason(gates(busy: true), lastRun: nil) == .busy)
        #expect(s.skipReason(gates(thermal: false), lastRun: nil) == .thermal)
        #expect(s.skipReason(gates(enabled: false), lastRun: nil) == .disabled)
        #expect(s.skipReason(gates(policy: MemoryPolicy(mode: .paused)), lastRun: nil) == .memoryNotOn)
        #expect(s.skipReason(gates(), lastRun: store.now().addingTimeInterval(-3600)) == .tooSoon)
    }

    @Test func runWritesPendingSuggestionsOnly() async throws {
        let (db, store) = try seeded()
        let counter = ItemInsertCounter()
        db.writer.add(transactionObserver: counter)
        let s = MemoryReviewService(store: store, model: ScriptedDecisionModel(Self.facts), embedder: nil)
        #expect(try await s.run(gates(), lastRun: nil).isEmpty == false)
        let pending = try s.pending()
        #expect(pending.map(\.text) == ["Plays jazz piano", "Works as a nurse on nights", "Cooks vegetarian food"], "sensitive off + < 8 chars dropped")
        #expect(counter.count.withLock { $0 } == 0)
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_item") } == 0)
        print("AT-246 memory_item inserts during review: \(counter.count.withLock { $0 })")
        // Gated: nothing.
        #expect(try await s.run(gates(FakePower(onACPower: false)), lastRun: nil).isEmpty)
        // (d) Save → one active item; Dismiss → dismissed.
        let item = try #require(try s.save(pending[0].id))
        #expect(item.origin == .review)
        #expect(try store.active().count == 1)
        try s.dismiss(pending[1].id)
        #expect(try s.pending().map(\.text) == ["Cooks vegetarian food"])
        #expect(try s.save(pending[1].id) == nil, "a dismissed suggestion cannot be saved")
    }

    @Test func evilAndMemoryOffChatsAreNotRead() async throws {
        let (db, store) = try seeded()
        try db.write { d in
            try d.execute(sql: "UPDATE chat SET memory_enabled = 0 WHERE id = 'c1'")
            try d.execute(sql: "INSERT INTO chat (id, mode, created_at, updated_at) VALUES ('e1', 'evil', 0, 100)")
            try d.execute(sql: "INSERT INTO message (id, chat_id, role, created_at) VALUES ('u2', 'e1', 'user', 2)")
            try d.execute(sql: "INSERT INTO message_part (message_id, idx, kind, body) VALUES ('u2', 0, 'text', 'I play jazz piano')")
        }
        let s = MemoryReviewService(store: store, model: ScriptedDecisionModel(Self.facts), embedder: nil)
        #expect(try await s.run(gates(), lastRun: nil).isEmpty, "memory-off and Evil chats are not read")
        #expect(try await s.run(gates(policy: MemoryPolicy(useInEvil: true)), lastRun: nil).count == 3)
    }
}
