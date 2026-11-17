// M8.T02 AT-242 unit legs (R-242 AC1/AC2, R-060 AC3/AC5): MemoryStoreTests (schema constraints, one event per write,
// undo), MemoryToolTests (save/update/delete/undo through the tool, sensitive off by default, Paused view-only),
// MemoryUpdateDeciderTests (cosine shortcut, model band, fallbacks, parsing).
//   make test-unit FILTER=MemoryStoreTests,MemoryToolTests,MemoryUpdateDeciderTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import GRDB
import Synchronization
import Testing
@testable import AntiChatKnowledge

/// Vectors by hand: texts in the same group share one axis (cosine 1), plus a small per-text axis for `near` pairs.
struct TableEmbedder: Embedder {
    var table: [String: [Float]] = [:]
    func embed(_ texts: [String], kind: EmbedRequest.Kind) async throws -> [[Float]] {
        texts.map { t in
            if let v = table[t] { return Self.pad(v) }
            var v = [Float](repeating: 0, count: 8)
            v[abs(t.hashValue) % 8] = 1
            return Self.pad(v)
        }
    }
    func rerank(query: String, documents: [String]) async throws -> [Float]? { nil }
    static func pad(_ v: [Float]) -> [Float] { v + [Float](repeating: 0, count: VecLoader.dimensions - v.count) }
}

final class ScriptedDecisionModel: MemoryDecisionModel, Sendable {
    let reply: String?
    let calls = Mutex(0)
    init(_ reply: String?) { self.reply = reply }
    func complete(system: String, user: String) async -> String? {
        calls.withLock { $0 += 1 }
        return reply.map { $0.replacingOccurrences(of: "$FIRST", with: Self.firstID(user) ?? "") }
    }
    static func firstID(_ user: String) -> String? {
        user.range(of: #""id":"([^"]+)""#, options: .regularExpression).map { String(user[$0].dropFirst(6).dropLast()) }
    }
}

func memoryDB() throws -> (AppDatabase, MemoryStore) {
    let db = try AppDatabase.inMemory()
    try db.write { d in try d.execute(sql: "INSERT INTO chat (id, created_at, updated_at) VALUES ('c1', 0, 0)") }
    return (db, MemoryStore(database: db))
}

@Suite struct MemoryStoreTests {
    @Test func schemaRequiresTopicAndScope() throws {
        let (db, store) = try memoryDB()
        // No topic → FK/NOT NULL; project scope without a project → CHECK.
        #expect(throws: (any Error).self) {
            try db.write { try $0.execute(sql: "INSERT INTO memory_item (id, scope, key, text, origin, created_at, updated_at) VALUES ('x','global','k','t','user',0,0)") }
        }
        #expect(throws: (any Error).self) {
            try db.write { d in
                try d.execute(sql: "INSERT INTO memory_topic (id, scope, name, created_at, updated_at) VALUES ('t1','global','Food',0,0)")
                try d.execute(sql: "INSERT INTO memory_item (id, topic_id, scope, project_id, key, text, origin, created_at, updated_at) VALUES ('y','t1','project',NULL,'k','t','user',0,0)")
            }
        }
        #expect(throws: MemoryStoreError.projectScopeNeedsProject) {
            try store.insert(topic: "Food", scope: .project, key: "k", text: "t", origin: .user)
        }
        #expect(throws: MemoryStoreError.tooLong("text")) {
            try store.insert(topic: "Food", key: "k", text: String(repeating: "a", count: 501), origin: .user)
        }
    }

    @Test func everyWriteLogsOneEventAndUndoRestores() throws {
        let (_, store) = try memoryDB()
        let (item, add) = try store.insert(topic: "Food", key: "diet", text: "Vegetarian", origin: .tool, sourceChatID: "c1")
        #expect(add.op == .add && add.beforeJSON == nil)
        let (_, upd) = try store.update(id: item.id, text: "Vegan since 2024")
        let del = try store.delete(id: item.id)
        #expect(try store.events(itemID: item.id).map(\.op) == [.add, .update, .delete])
        #expect(try store.active().isEmpty)
        try store.undo(eventID: del.id)
        #expect(try store.active().map(\.item.text) == ["Vegan since 2024"])
        try store.undo(eventID: upd.id)
        #expect(try store.active().map(\.item.text) == ["Vegetarian"])
        try store.undo(eventID: add.id)
        #expect(try store.active().isEmpty)
        try store.undo(eventID: add.id)  // idempotent
        #expect(try store.events(itemID: item.id).count == 3)
    }

    @Test func activeItemsAreMirroredAsMemoryChunks() throws {
        let (db, store) = try memoryDB()
        let (item, _) = try store.insert(topic: "Work", key: "job", text: "Nurse at a clinic", origin: .user,
                                         vector: TableEmbedder.pad([1]))
        func chunks() throws -> [String] { try db.read { try String.fetchAll($0, sql: "SELECT text FROM chunk WHERE source = 'memory'") } }
        #expect(try chunks() == ["Work: job: Nurse at a clinic"])
        #expect(try store.vectors([item.id]).count == 1)
        try store.delete(id: item.id)
        #expect(try chunks().isEmpty)
        // Topics are one per name (case-insensitive) and scope.
        try store.insert(topic: "work", key: "k2", text: "Night shifts", origin: .user)
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_topic") } == 1)
    }
}

@Suite struct MemoryUpdateDeciderTests {
    @Test func cosineShortcutUpdatesWithoutTheModel() async throws {
        let (_, store) = try memoryDB()
        let e = TableEmbedder(table: ["I'm vegetarian": [1, 0.1], "I don't eat meat": [1, 0.15]])
        let (old, _) = try store.insert(topic: "Food", key: "diet", text: "I'm vegetarian", origin: .tool,
                                        vector: try await e.embed(["I'm vegetarian"], kind: .document)[0])
        let model = ScriptedDecisionModel(#"{"event":"ADD"}"#)
        let out = await MemoryUpdateDecider(store: store, embedder: e, model: model).decide(new: "I don't eat meat", scope: .global, projectID: nil)
        #expect(out.decision == .update(id: old.id, text: "I don't eat meat") && !out.usedModel)
        #expect(model.calls.withLock { $0 } == 0)
    }

    @Test func middleBandAsksTheModelAndFarIsAdd() async throws {
        let (_, store) = try memoryDB()
        let e = TableEmbedder(table: ["Lives in Berlin": [1, 0, 0], "Moved to Hamburg": [0.7, 0.71, 0], "Plays chess": [0, 0, 1]])
        let (old, _) = try store.insert(topic: "Home", key: "city", text: "Lives in Berlin", origin: .tool,
                                        vector: try await e.embed(["Lives in Berlin"], kind: .document)[0])
        let model = ScriptedDecisionModel(#"{"event":"UPDATE","id":"$FIRST","text":"Lives in Hamburg (moved from Berlin)"}"#)
        let d = MemoryUpdateDecider(store: store, embedder: e, model: model)
        let mid = await d.decide(new: "Moved to Hamburg", scope: .global, projectID: nil)
        #expect(mid.usedModel && mid.decision == .update(id: old.id, text: "Lives in Hamburg (moved from Berlin)"))
        let far = await d.decide(new: "Plays chess", scope: .global, projectID: nil)
        #expect(far.decision == .add && !far.usedModel)
    }

    @Test func noEmbedderFallsBackToFTSNeighbours() async throws {
        let (_, store) = try memoryDB()
        try store.insert(topic: "Pets", key: "cat", text: "Has a cat named Miso", origin: .tool)
        let model = ScriptedDecisionModel(#"{"event":"NONE","id":"$FIRST"}"#)
        let d = MemoryUpdateDecider(store: store, embedder: nil, model: model)
        let out = await d.decide(new: "My cat is called Miso", scope: .global, projectID: nil)
        #expect(out.usedModel)
        if case .none(let id) = out.decision { #expect(id != nil) } else { Issue.record("\(out.decision)") }
        #expect(await d.decide(new: "Speaks Portuguese", scope: .global, projectID: nil).decision == .add)
    }

    @Test func normalisedDuplicateCheck() throws {
        #expect(MemoryStore.normalized("  I\u{2019}m  Végetarian. ") == "im vegetarian")
        #expect(MemoryStore.normalized("I'm vegetarian") == MemoryStore.normalized("IM VEGETARIAN!"))
        #expect(MemoryStore.normalized("Lives in Berlin") != MemoryStore.normalized("Lives in Bern"))
        let (db, store) = try memoryDB()
        try db.write { try $0.execute(sql: "INSERT INTO project (id, name, created_at, updated_at) VALUES ('p1', 'P', 0, 0)") }
        let (g, _) = try store.insert(topic: "Home", key: "city", text: "Lives in Berlin.", origin: .tool)
        let (p, _) = try store.insert(topic: "Work", scope: .project, projectID: "p1", key: "stack", text: "Uses Swift", origin: .tool)
        #expect(try store.duplicate(of: "lives in berlin")?.id == g.id)
        #expect(try store.duplicate(of: "lives in berlin", projectID: "p1")?.id == g.id, "a global fact also counts inside a project")
        #expect(try store.duplicate(of: "uses swift", projectID: "p1")?.id == p.id)
        #expect(try store.duplicate(of: "uses swift") == nil, "another project's fact is not a global duplicate")
        #expect(try store.duplicate(of: "Lives in Hamburg") == nil && store.duplicate(of: " ?! ") == nil)
        try store.delete(id: g.id)
        #expect(try store.duplicate(of: "lives in berlin") == nil, "a deleted memory can be saved again")
    }

    @Test func parseRejectsUnknownIdsAndJunk() {
        let known: Set = ["a1"]
        #expect(MemoryUpdateDecider.parse(#"sure: {"event":"UPDATE","id":"a1","text":"x"}"#, known: known, new: "n") == .update(id: "a1", text: "x"))
        #expect(MemoryUpdateDecider.parse(#"{"event":"UPDATE","id":"zz","text":"x"}"#, known: known, new: "n") == nil)
        #expect(MemoryUpdateDecider.parse("no json", known: known, new: "n") == nil)
        #expect(MemoryUpdateDecider.parse(#"{"event":"delete","id":"a1"}"#, known: known, new: "n") == .delete(id: "a1"))
    }
}

@Suite struct MemoryToolTests {
    func executor(_ store: MemoryStore, policy: MemoryPolicy = MemoryPolicy(), embedder: (any Embedder)? = TableEmbedder(),
                  model: (any MemoryDecisionModel)? = nil) -> MemoryToolExecutor {
        MemoryToolExecutor(store: store, decider: MemoryUpdateDecider(store: store, embedder: embedder, model: model), policy: { policy })
    }

    func obj(_ s: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:] }

    @Test func saveViewDeleteUndoEachLogOneEvent() async throws {
        let (_, store) = try memoryDB()
        let x = executor(store, embedder: TableEmbedder(table: ["vegetarian": [1, 0], "vegetarian since 2019": [1, 0]]))
        let saved = obj(try await x.run(#"{"action":"save","topic":"Food","key":"diet","value":"vegetarian"}"#, chatID: "c1"))
        let ids = try #require(saved["memoryEventIDs"] as? [String])
        #expect(ids.count == 1 && saved["result"] as? String == "added")
        // The same fact again (case, accents, punctuation aside): nothing written, no "Memory updated" line.
        let again = obj(try await x.run(#"{"action":"save","topic":"Diet","key":"food","value":" Végetarian. "}"#, chatID: "c1"))
        #expect(again["result"] as? String == "already_known" && again["stored"] as? Bool == true)
        #expect((again["memoryEventIDs"] as? [String])?.isEmpty == true)
        #expect(MemoryToolExecutor.eventIDs(inResult: try await x.run(#"{"action":"save","topic":"Food","key":"diet","value":"vegetarian since 2019"}"#, chatID: "c1")).count == 1)  // cosine 1 → update
        let view = obj(try await x.run(#"{"action":"view"}"#, chatID: "c1"))
        #expect((view["memory"] as? String)?.contains("[Food] diet: vegetarian") == true)
        let del = obj(try await x.run(#"{"action":"delete","key":"diet"}"#, chatID: "c1"))
        #expect(del["deleted"] as? Int == 1)
        #expect(try store.active().isEmpty)
        try store.undo(eventID: (del["memoryEventIDs"] as! [String])[0])
        #expect(try store.active().count == 1)
        let item = try #require(try store.active().first?.item)
        #expect(try store.events(itemID: item.id).map(\.op) == [.add, .update, .delete])
        #expect(item.origin == .tool && item.sourceChatID == "c1")
    }

    @Test func sensitiveIsStoredOnlyWithTheSettingOn() async throws {
        let (_, store) = try memoryDB()
        let args = #"{"action":"save","topic":"Health","key":"condition","value":"has asthma","sensitive_category":"health"}"#
        let off = obj(try await executor(store).run(args, chatID: "c1"))
        #expect(off["stored"] as? Bool == false && off["reason"] as? String == "sensitive_topics_off")
        #expect(try store.active().isEmpty)
        let on = obj(try await executor(store, policy: MemoryPolicy(includeSensitive: true)).run(args, chatID: "c1"))
        #expect(on["stored"] as? Bool == true)
        #expect(try store.active().first?.topic.sensitiveCategory == .health)
    }

    @Test func pausedAndPerChatAccess() async throws {
        let (_, store) = try memoryDB()
        let paused = obj(try await executor(store, policy: MemoryPolicy(mode: .paused)).run(#"{"action":"save","topic":"A","value":"b"}"#, chatID: "c1"))
        #expect(paused["stored"] as? Bool == false)
        #expect(try store.active().isEmpty)
        let p = MemoryPolicy()
        #expect(p.access(chatMemoryEnabled: true, isEvil: false, isIncognito: false) == .init(read: true, write: true))
        #expect(p.access(chatMemoryEnabled: false, isEvil: false, isIncognito: false).read == false)
        #expect(p.access(chatMemoryEnabled: true, isEvil: true, isIncognito: false).read == false)
        #expect(MemoryPolicy(useInEvil: true).access(chatMemoryEnabled: true, isEvil: true, isIncognito: false).write)
        #expect(p.access(chatMemoryEnabled: true, isEvil: false, isIncognito: true).read == false)
        #expect(MemoryPolicy(mode: .paused).access(chatMemoryEnabled: true, isEvil: false, isIncognito: false) == .init(read: true, write: false))
        #expect(MemoryPolicy(mode: .off).access(chatMemoryEnabled: true, isEvil: false, isIncognito: false).read == false)
        // Defaults (owner 2026-11-16): on, sensitive topics on, Evil on; a stored choice is kept.
        let d = UserDefaults.inMemory()
        #expect(MemoryPolicy.from(d) == MemoryPolicy(mode: .on, includeSensitive: true, useInEvil: true))
        d.set(false, forKey: "memoryIncludeSensitive")
        d.set(false, forKey: "useMemoryInEvil")
        #expect(MemoryPolicy.from(d) == MemoryPolicy(mode: .on, includeSensitive: false, useInEvil: false))
    }
}
