// M8.T02 (R-242 AC1/AC2, R-060 AC5; G-035): the memory tables (migration v18_memory) and their only writer.
// Ported design from danny-avila/LibreChat@8d3da9bbb220a0a96be9330a2e1cbd385fb786d5:packages/api/src/agents/memory.ts
// (key/value upsert per user `:174-276`, P-media-01); our schema adds topic + scope (one topic = one document,
// Anthropic memory-tool docs, reference only). No code copied.
// Writes go through `insert / update / delete / undo` only, each appending one `memory_event` (the undo log), and
// only from MemoryTool, MemorySettingsViewModel, MemoryReviewService (after a tap) and MemoryImporter (M11):
// tools/ci/memory-write-paths.py enforces the caller list. Active items are mirrored into `chunk(source='memory')`
// (FTS through its triggers; the vector when an embedder gave one, else BackgroundIndexer.embedPending fills it).
import AntiChatStorage
import Foundation
import GRDB

public enum MemoryScope: String, Codable, Sendable, CaseIterable { case global, project }
public enum MemoryOrigin: String, Codable, Sendable { case user, tool, review, `import` }
public enum MemoryItemState: String, Codable, Sendable { case active, pending, deleted }

/// R-060 AC3: the five categories that are stored only when "Include sensitive topics" is on. A storage choice the
/// user makes; nothing in a chat is blocked or rewritten.
public enum SensitiveCategory: String, Codable, Sendable, CaseIterable { case health, sexuality, religion, politics, finances }

public struct MemoryTopic: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public static let databaseTableName = "memory_topic"
    public var id: String
    public var scope: MemoryScope
    public var projectID: String?
    public var name: String
    public var sensitiveCategory: SensitiveCategory?
    public var createdAt: Date
    public var updatedAt: Date
    enum CodingKeys: String, CodingKey {
        case id, scope, name, projectID = "project_id", sensitiveCategory = "sensitive_category", createdAt = "created_at",
             updatedAt = "updated_at"
    }
}

public struct MemoryItem: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public static let databaseTableName = "memory_item"
    public var id: String
    public var topicID: String
    public var scope: MemoryScope
    public var projectID: String?
    public var key: String
    public var text: String
    public var state: MemoryItemState
    public var origin: MemoryOrigin
    public var sourceMessageID: String?
    public var sourceChatID: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, scope, key, text, state, origin, topicID = "topic_id", projectID = "project_id",
             sourceMessageID = "source_message_id", sourceChatID = "source_chat_id", createdAt = "created_at",
             updatedAt = "updated_at", deletedAt = "deleted_at"
    }
}

public struct MemoryEvent: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public enum Op: String, Codable, Sendable { case add, update, delete }
    public static let databaseTableName = "memory_event"
    public var id: String
    public var itemID: String
    public var op: Op
    public var beforeJSON: String?
    public var afterJSON: String?
    public var messageID: String?
    public var createdAt: Date
    public var undoneAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, op, itemID = "item_id", beforeJSON = "before_json", afterJSON = "after_json", messageID = "message_id",
             createdAt = "created_at", undoneAt = "undone_at"
    }
}

/// An active item with its topic (snapshot, browser, `view`).
public struct MemoryEntry: Sendable, Equatable {
    public var item: MemoryItem
    public var topic: MemoryTopic
}

public enum MemoryStoreError: Error, Equatable, Sendable {
    case projectScopeNeedsProject
    case tooLong(String)
    case notFound(String)
}

public struct MemoryStore: Sendable {
    public static let maxKey = 64
    public static let maxText = 500
    public static let maxTopic = 40
    public let database: AppDatabase
    public var now: @Sendable () -> Date

    public init(database: AppDatabase, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.now = now
    }

    // MARK: Writes (each with one memory_event)

    /// Adds a fact. Returns the item and its event.
    @discardableResult
    public func insert(topic: String, scope: MemoryScope = .global, projectID: String? = nil, key: String, text: String,
                       sensitive: SensitiveCategory? = nil, origin: MemoryOrigin, sourceChatID: String? = nil,
                       sourceMessageID: String? = nil, vector: [Float]? = nil) throws -> (MemoryItem, MemoryEvent) {
        try validate(scope: scope, projectID: projectID, topic: topic, key: key, text: text)
        return try database.write { db in
            let t = try topicRow(db, name: topic, scope: scope, projectID: projectID, sensitive: sensitive)
            let stamp = now()
            let item = MemoryItem(id: StorageID.make(now: stamp), topicID: t.id, scope: scope, projectID: projectID,
                                  key: Self.clean(key), text: Self.clean(text), state: .active, origin: origin,
                                  sourceMessageID: sourceMessageID, sourceChatID: sourceChatID, createdAt: stamp, updatedAt: stamp)
            try item.insert(db)
            try mirror(db, item, vector: vector)
            let event = try log(db, item: item.id, op: .add, before: nil, after: item, messageID: sourceMessageID)
            return (item, event)
        }
    }

    /// Replaces an item's text (and key). Returns the new item and its event.
    @discardableResult
    public func update(id: String, text: String, key: String? = nil, messageID: String? = nil, sourceChatID: String? = nil,
                       vector: [Float]? = nil) throws -> (MemoryItem, MemoryEvent) {
        guard text.count <= Self.maxText, !text.isEmpty else { throw MemoryStoreError.tooLong("text") }
        return try database.write { db in
            guard let before = try MemoryItem.fetchOne(db, key: id) else { throw MemoryStoreError.notFound(id) }
            var after = before
            after.text = Self.clean(text)
            if let key { after.key = Self.clean(key) }
            if let sourceChatID { after.sourceChatID = sourceChatID }  // the chat that last stated it (volatile line)
            after.updatedAt = now()
            try after.update(db)
            try mirror(db, after, vector: vector)
            let event = try log(db, item: id, op: .update, before: before, after: after, messageID: messageID)
            return (after, event)
        }
    }

    /// Soft delete (state deleted, chunk removed). Returns the event.
    @discardableResult
    public func delete(id: String, messageID: String? = nil) throws -> MemoryEvent {
        try database.write { db in
            guard let before = try MemoryItem.fetchOne(db, key: id) else { throw MemoryStoreError.notFound(id) }
            var after = before
            after.state = .deleted
            after.deletedAt = now()
            after.updatedAt = after.deletedAt!
            try after.update(db)
            try mirror(db, after, vector: nil)
            return try log(db, item: id, op: .delete, before: before, after: after, messageID: messageID)
        }
    }

    /// Undo one event: the item goes back to `before_json` (an undone add becomes deleted). Idempotent.
    public func undo(eventID: String) throws {
        try database.write { db in
            guard var event = try MemoryEvent.fetchOne(db, key: eventID) else { throw MemoryStoreError.notFound(eventID) }
            guard event.undoneAt == nil else { return }
            guard var item = try MemoryItem.fetchOne(db, key: event.itemID) else { throw MemoryStoreError.notFound(event.itemID) }
            if let before = event.beforeJSON.flatMap({ try? JSONDecoder.memory.decode(MemoryItem.self, from: Data($0.utf8)) }) {
                item = before
                item.updatedAt = now()
            } else {  // an add: undoing it removes the item
                item.state = .deleted
                item.deletedAt = now()
                item.updatedAt = item.deletedAt!
            }
            try item.update(db)
            try mirror(db, item, vector: nil)
            event.undoneAt = now()
            try event.update(db)
        }
    }

    /// The user's typed-confirmation reset (M8.T03): every item, topic, event and memory chunk is removed for good.
    public func resetAll() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM chunk WHERE source = 'memory'")
            try db.execute(sql: "DELETE FROM memory_event")
            try db.execute(sql: "DELETE FROM memory_item")
            try db.execute(sql: "DELETE FROM memory_topic")
            // Review fix (M8.T16): Reset leaves no memory text anywhere — pending review suggestions, and the frozen
            // per-chat snapshots (an old chat stops sending the reset facts to the model).
            if try db.tableExists("memory_suggestion") { try db.execute(sql: "DELETE FROM memory_suggestion") }
            let snapshotColumns = try db.columns(in: "chat").map(\.name).filter { $0.hasPrefix("memory_snapshot") }
            for c in snapshotColumns { try db.execute(sql: "UPDATE chat SET \"\(c)\" = NULL WHERE \"\(c)\" IS NOT NULL") }
        }
    }

    /// Every active item, global and project-scoped (Settings › Manage memories lists them all).
    public func allActive() throws -> [MemoryEntry] {
        try database.read { db in
            let items = try MemoryItem.filter(Column("state") == MemoryItemState.active.rawValue)
                .order(Column("created_at"), Column("id")).fetchAll(db)
            let topics = try Dictionary(uniqueKeysWithValues: MemoryTopic.fetchAll(db, keys: Set(items.map(\.topicID))).map { ($0.id, $0) })
            return items.compactMap { i in topics[i.topicID].map { MemoryEntry(item: i, topic: $0) } }
        }
    }

    // MARK: Reads

    /// Active items of a scope (global, or global + project when `projectID` is set and `projectOnly` is false),
    /// grouped by topic then oldest first.
    public func active(scope: MemoryScope = .global, projectID: String? = nil) throws -> [MemoryEntry] {
        try database.read { db in
            let items = try MemoryItem
                .filter(Column("state") == MemoryItemState.active.rawValue && Column("scope") == scope.rawValue)
                .filter(scope == .project ? Column("project_id") == projectID : Column("project_id") == nil)
                .order(Column("created_at"), Column("id"))
                .fetchAll(db)
            let topics = try Dictionary(uniqueKeysWithValues: MemoryTopic.fetchAll(db, keys: Set(items.map(\.topicID))).map { ($0.id, $0) })
            return items.compactMap { i in topics[i.topicID].map { MemoryEntry(item: i, topic: $0) } }
        }
    }

    public func item(_ id: String) throws -> MemoryItem? { try database.read { try MemoryItem.fetchOne($0, key: id) } }

    public func events(itemID: String) throws -> [MemoryEvent] {
        try database.read { try MemoryEvent.filter(Column("item_id") == itemID).order(Column("created_at"), Column("id")).fetchAll($0) }
    }

    /// The stored document vector of each active item that has one (cosine neighbours, snapshot ranking).
    public func vectors(_ ids: [String]) throws -> [String: [Float]] {
        guard !ids.isEmpty else { return [:] }
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.source_id, v.embedding FROM chunk c JOIN chunk_vec v ON v.rowid = c.id
                WHERE c.source = 'memory' AND c.source_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments(ids))
            var out: [String: [Float]] = [:]
            for r in rows {
                let data: Data = r["embedding"]
                out[r["source_id"]] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
            return out
        }
    }

    // MARK: Internals

    func validate(scope: MemoryScope, projectID: String?, topic: String, key: String, text: String) throws {
        if (scope == .project) != (projectID != nil) { throw MemoryStoreError.projectScopeNeedsProject }
        if topic.isEmpty || topic.count > Self.maxTopic { throw MemoryStoreError.tooLong("topic") }
        if key.isEmpty || key.count > Self.maxKey { throw MemoryStoreError.tooLong("key") }
        if text.isEmpty || text.count > Self.maxText { throw MemoryStoreError.tooLong("text") }
    }

    static func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    func topicRow(_ db: Database, name: String, scope: MemoryScope, projectID: String?, sensitive: SensitiveCategory?) throws -> MemoryTopic {
        let name = Self.clean(name)
        if var t = try MemoryTopic.fetchOne(db, sql: """
            SELECT * FROM memory_topic WHERE scope = ? AND ifnull(project_id, '') = ? AND name = ? COLLATE NOCASE
            """, arguments: [scope.rawValue, projectID ?? "", name]) {
            if t.sensitiveCategory == nil, let sensitive {
                t.sensitiveCategory = sensitive
                t.updatedAt = now()
                try t.update(db)
            }
            return t
        }
        let stamp = now()
        let t = MemoryTopic(id: StorageID.make(now: stamp), scope: scope, projectID: projectID, name: name,
                            sensitiveCategory: sensitive, createdAt: stamp, updatedAt: stamp)
        try t.insert(db)
        return t
    }

    /// Keeps `chunk(source='memory')` equal to the active items (text "Topic: key: text").
    func mirror(_ db: Database, _ item: MemoryItem, vector: [Float]?) throws {
        try db.execute(sql: "DELETE FROM chunk WHERE source = 'memory' AND source_id = ?", arguments: [item.id])
        guard item.state == .active else { return }
        let topic = try String.fetchOne(db, sql: "SELECT name FROM memory_topic WHERE id = ?", arguments: [item.topicID]) ?? ""
        try db.execute(sql: """
            INSERT INTO chunk (source, source_id, chat_id, ord, text, created_at) VALUES ('memory', ?, NULL, 0, ?, ?)
            """, arguments: [item.id, "\(topic): \(item.key): \(item.text)", item.updatedAt.timeIntervalSince1970])
        if let vector, vector.count == VecLoader.dimensions, try db.tableExists("chunk_vec") {
            try db.execute(sql: "INSERT OR REPLACE INTO chunk_vec(rowid, embedding) VALUES (?, ?)",
                           arguments: [db.lastInsertedRowID, ChunkTables.blob(vector)])
        }
    }

    func log(_ db: Database, item: String, op: MemoryEvent.Op, before: MemoryItem?, after: MemoryItem?, messageID: String?) throws -> MemoryEvent {
        let stamp = now()
        let e = MemoryEvent(id: StorageID.make(now: stamp), itemID: item, op: op, beforeJSON: before.flatMap(Self.json),
                            afterJSON: after.flatMap(Self.json), messageID: messageID, createdAt: stamp)
        try e.insert(db)
        return e
    }

    static func json(_ item: MemoryItem) -> String? {
        (try? JSONEncoder.memory.encode(item)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

extension JSONEncoder {
    static let memory: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = .sortedKeys
        return e
    }()
}

extension JSONDecoder {
    static let memory: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
