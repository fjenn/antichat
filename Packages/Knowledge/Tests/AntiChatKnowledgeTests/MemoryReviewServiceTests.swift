// M8.T03 AT-246 (R-246 AC1/AC2; owner 2026-11-16: automatic memory): (a) default off on T0/T1, on T2–T4; (b) gates:
// battery, idle 299 s vs 300 s, Low Power Mode, a running turn, thermal, 6 h spacing; (c) a run saves the facts the
// model marked certain (one active item + one memory_event each, origin review) and leaves unsure / unmarked ones as
// pending suggestions; a certain fact that touches an existing memory, or whose comparison failed, stays pending;
// unparseable output saves nothing; sensitive facts need the setting; nothing is saved or suggested twice;
// (d) Save → one active item (origin review), Dismiss → dismissed.
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

/// Answers the review's extraction prompt with `facts` and the decider's comparison prompt with `decision`.
struct ReviewModel: MemoryDecisionModel {
    var facts: String?
    var decision: String? = #"{"event":"ADD"}"#
    func complete(system: String, user: String) async -> String? {
        guard system == MemoryUpdateDecider.systemPrompt else { return facts }
        return decision.map { $0.replacingOccurrences(of: "$FIRST", with: ScriptedDecisionModel.firstID(user) ?? "") }
    }
}

@Suite struct MemoryReviewServiceTests {
    static let facts = #"[{"topic":"Music","text":"Plays jazz piano","confidence":"certain","sensitive_category":"none"},{"topic":"Work","text":"Works as a nurse on nights","confidence":"unsure","sensitive_category":"none"},{"topic":"Food","text":"Cooks vegetarian food","sensitive_category":"none"},{"topic":"Health","text":"Has asthma since childhood","confidence":"certain","sensitive_category":"health"},{"topic":"X","text":"short","confidence":"certain"}]"#

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

    @Test func certainIsSavedUnsureStaysPending() async throws {
        let (db, store) = try seeded()
        let counter = ItemInsertCounter()
        db.writer.add(transactionObserver: counter)
        let s = MemoryReviewService(store: store, model: ReviewModel(facts: Self.facts), embedder: nil)
        let rows = try await s.run(gates(), lastRun: nil)
        #expect(rows.map(\.state) == [.saved, .pending, .pending], "sensitive off + < 8 chars dropped")
        // certain → saved by itself: one active item, origin review, one add event (undo / delete in Settings).
        let active = try store.active()
        #expect(active.map(\.item.text) == ["Plays jazz piano"] && active[0].item.origin == .review && active[0].topic.name == "Music")
        #expect(try store.events(itemID: active[0].item.id).map(\.op) == [.add])
        #expect(counter.count.withLock { $0 } == 1)
        // unsure, and no confidence at all → pending, nothing stored.
        let pending = try s.pending()
        #expect(pending.map(\.text) == ["Works as a nurse on nights", "Cooks vegetarian food"])
        // The same facts again: nothing saved or suggested twice.
        #expect(try await s.run(gates(), lastRun: nil).isEmpty)
        #expect(try store.active().count == 1 && s.pending().count == 2)
        // An undone automatic save is not brought back by the next run.
        try store.undo(eventID: try #require(try store.events(itemID: active[0].item.id).first).id)
        #expect(try await s.run(gates(), lastRun: nil).isEmpty)
        #expect(try store.active().isEmpty)
        // Gated: nothing.
        #expect(try await s.run(gates(FakePower(onACPower: false)), lastRun: nil).isEmpty)
        // (d) Save → one active item; Dismiss → dismissed.
        let item = try #require(try s.save(pending[0].id))
        #expect(item.origin == .review)
        #expect(try store.active().count == 1)
        try s.dismiss(pending[1].id)
        #expect(try s.pending().isEmpty)
        #expect(try s.save(pending[1].id) == nil, "a dismissed suggestion cannot be saved")
        #expect(try await s.run(gates(), lastRun: nil).isEmpty, "a dismissed fact is not proposed again")
    }

    @Test func sensitiveNeedsTheSetting() async throws {
        let (_, store) = try seeded()
        let s = MemoryReviewService(store: store, model: ReviewModel(facts: Self.facts), embedder: nil)
        let rows = try await s.run(gates(policy: MemoryPolicy(includeSensitive: true)), lastRun: nil)
        #expect(rows.first { $0.text == "Has asthma since childhood" }?.state == .saved)
        #expect(try store.active().first { $0.item.text == "Has asthma since childhood" }?.topic.sensitiveCategory == .health)
        let (_, store2) = try seeded()
        let off = MemoryReviewService(store: store2, model: ReviewModel(facts: Self.facts), embedder: nil)
        #expect(try await off.run(gates(), lastRun: nil).contains { $0.sensitiveCategory != nil } == false)
        #expect(try store2.active().contains { $0.topic.sensitiveCategory != nil } == false)
    }

    @Test func unparseableOrUnmarkedOutputSavesNothing() async throws {
        for raw in ["Sure! The user plays jazz piano.", #"[{"topic":"Music","text":"Plays jazz piano","confidence":"certain""#, ""] {
            let (_, store) = try seeded()
            let s = MemoryReviewService(store: store, model: ReviewModel(facts: raw), embedder: nil)
            #expect(try await s.run(gates(), lastRun: nil).isEmpty)
            #expect(try store.active().isEmpty && s.pending().isEmpty)
        }
        // Parsed, but the confidence is missing, not a string, or a word we do not know: unsure → pending.
        let (_, store) = try seeded()
        let odd = #"[{"topic":"Music","text":"Plays jazz piano"},{"topic":"Work","text":"Works as a nurse","confidence":0.9},{"topic":"Food","text":"Cooks vegetarian food","confidence":"high"},{"topic":"Home","text":"Lives in Lisbon","confidence":" Certain "}]"#
        let s = MemoryReviewService(store: store, model: ReviewModel(facts: odd), embedder: nil)
        #expect(try await s.run(gates(), lastRun: nil).map(\.state) == [.pending, .pending, .pending, .saved])
        #expect(try store.active().map(\.item.text) == ["Lives in Lisbon"])
        #expect(MemoryReviewService.parse(odd).map(\.certain) == [false, false, false, true])
    }

    @Test func conflictWithAnExistingMemoryStaysPending() async throws {
        let certain = #"[{"topic":"Home","text":"Lives in Hamburg now","confidence":"certain"}]"#
        // The comparison says the new fact changes (UPDATE) or contradicts (DELETE) a stored one, or gives no usable
        // answer: the user chooses. The stored memory is untouched.
        for decision in [#"{"event":"UPDATE","id":"$FIRST","text":"Lives in Hamburg"}"#, #"{"event":"DELETE","id":"$FIRST"}"#, "no idea", nil] {
            let (_, store) = try seeded()
            try store.insert(topic: "Home", key: "city", text: "Lives in Berlin", origin: .tool)
            let s = MemoryReviewService(store: store, model: ReviewModel(facts: certain, decision: decision), embedder: nil)
            #expect(try await s.run(gates(), lastRun: nil).map(\.state) == [.pending], "\(decision ?? "nil")")
            #expect(try store.active().map(\.item.text) == ["Lives in Berlin"])
        }
        // Already covered (NONE), or the same text in other casing / punctuation: nothing at all.
        let (_, store) = try seeded()
        try store.insert(topic: "Home", key: "city", text: "Lives in Berlin", origin: .tool)
        let covered = MemoryReviewService(store: store, model: ReviewModel(facts: certain, decision: #"{"event":"NONE","id":"$FIRST"}"#), embedder: nil)
        #expect(try await covered.run(gates(), lastRun: nil).isEmpty)
        let same = MemoryReviewService(store: store, model: ReviewModel(facts: #"[{"topic":"City","text":"lives in BERLIN.","confidence":"certain"}]"#), embedder: nil)
        #expect(try await same.run(gates(), lastRun: nil).isEmpty)
        // The same fact twice in one answer: stored once.
        let twice = MemoryReviewService(store: store, model: ReviewModel(facts: #"[{"topic":"Pets","text":"Has a dog named Rex","confidence":"certain"},{"topic":"Pets","text":"has a dog named rex!","confidence":"certain"}]"#), embedder: nil)
        #expect(try await twice.run(gates(), lastRun: nil).map(\.state) == [.saved])
        #expect(try store.active().count == 2 && covered.pending().isEmpty)
    }

    @Test func evilAndMemoryOffChatsAreNotRead() async throws {
        let (db, store) = try seeded()
        try db.write { d in
            try d.execute(sql: "UPDATE chat SET memory_enabled = 0 WHERE id = 'c1'")
            try d.execute(sql: "INSERT INTO chat (id, mode, created_at, updated_at) VALUES ('e1', 'evil', 0, 100)")
            try d.execute(sql: "INSERT INTO message (id, chat_id, role, created_at) VALUES ('u2', 'e1', 'user', 2)")
            try d.execute(sql: "INSERT INTO message_part (message_id, idx, kind, body) VALUES ('u2', 0, 'text', 'I play jazz piano')")
        }
        let s = MemoryReviewService(store: store, model: ReviewModel(facts: Self.facts), embedder: nil)
        #expect(try await s.run(gates(), lastRun: nil).isEmpty, "memory-off and Evil chats are not read")
        #expect(try await s.run(gates(policy: MemoryPolicy(useInEvil: true)), lastRun: nil).count == 3)
    }
}
