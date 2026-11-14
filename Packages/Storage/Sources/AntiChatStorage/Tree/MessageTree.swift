// Message tree operations (R-296, P-shell-03; design ported from janhq/jan@7890e41:web-app/src/lib/message-branching.ts
// and open-webui/open-webui@f7ac7ee:backend/open_webui/models/chat_messages.py, no code copied).
//
// Model: every message has `parent_id` (nil = a root); versions of a turn are siblings (same parent), ordered by
// `position`. Each node's `active_child_id` picks the child on the active path; `chat.leaf_message_id` is the last
// node of that path. Regenerate and edit insert a sibling and make it active; switching versions only moves
// `active_child_id` (and the leaf follows). Versions of the first message are sibling roots; the active root is the
// top ancestor of the leaf.
//
// Every `static func … (db:)` runs inside the caller's transaction (one writer, architecture §6); the instance
// methods open their own read or write transaction.
import Foundation
import GRDB

public struct MessageTree: Sendable {
    public let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    public func visiblePath(_ chatID: String) throws -> [MessageRecord] {
        try database.read { try Self.visiblePath(chatID, db: $0) }
    }

    /// Appends a new message under `parentID` (nil = a new root) and makes it the active leaf.
    @discardableResult
    public func append(
        chatID: String, parentID: String?, role: MessageRole, status: MessageStatus = .done,
        parts: [PartContent] = [], configure: (inout MessageRecord) -> Void = { _ in }
    ) throws -> MessageRecord {
        try database.write { db in
            try Self.append(chatID: chatID, parentID: parentID, role: role, status: status, parts: parts,
                            configure: configure, db: db)
        }
    }

    /// Regenerate / edit: a new sibling of `messageID` (same parent), made active.
    @discardableResult
    public func insertSibling(
        of messageID: String, role: MessageRole? = nil, status: MessageStatus = .done, parts: [PartContent] = [],
        configure: (inout MessageRecord) -> Void = { _ in }
    ) throws -> MessageRecord {
        try database.write { db in
            try Self.insertSibling(of: messageID, role: role, status: status, parts: parts, configure: configure, db: db)
        }
    }

    public func setActive(_ messageID: String) throws {
        try database.write { db in try Self.setActive(messageID, db: db) }
    }

    public func versionInfo(_ messageID: String) throws -> (index: Int, total: Int) {
        try database.read { try Self.versionInfo(messageID, db: $0) }
    }

    public func siblings(of messageID: String) throws -> [MessageRecord] {
        try database.read { try Self.siblings(of: messageID, db: $0) }
    }

    /// Copies the path from the root down to `messageID` (inclusive) into a new chat; returns its id.
    /// `title` is the caller's localized `chat.branchTitle` ("{title} (branch)"); the original chat is unchanged.
    @discardableResult
    public func branchCopy(upTo messageID: String, title: String, mode: ChatMode? = nil) throws -> String {
        try database.write { db in try Self.branchCopy(upTo: messageID, title: title, mode: mode, db: db) }
    }

    // MARK: - Reads

    /// The active path, root first: a recursive CTE from the active root following `active_child_id`.
    /// The active root is the top ancestor of `chat.leaf_message_id` (first root by position if there is no leaf).
    public static func visiblePath(_ chatID: String, db: Database) throws -> [MessageRecord] {
        try MessageRecord.fetchAll(db, sql: """
            WITH RECURSIVE
              up(id, parent_id, depth) AS (
                SELECT m.id, m.parent_id, 0 FROM chat c JOIN message m ON m.id = c.leaf_message_id WHERE c.id = :chat
                UNION ALL
                SELECT m.id, m.parent_id, up.depth + 1 FROM up JOIN message m ON m.id = up.parent_id
                WHERE up.depth < 1000000
              ),
              root(id) AS (
                SELECT id FROM up WHERE parent_id IS NULL
                UNION ALL
                SELECT id FROM (SELECT id FROM message WHERE chat_id = :chat AND parent_id IS NULL
                                ORDER BY position, id LIMIT 1)
                WHERE NOT EXISTS (SELECT 1 FROM up)
              ),
              path(id, depth) AS (
                SELECT id, 0 FROM root
                UNION ALL
                SELECT p.active_child_id, path.depth + 1 FROM path JOIN message p ON p.id = path.id
                WHERE p.active_child_id IS NOT NULL AND path.depth < 1000000
              )
            SELECT message.* FROM path JOIN message ON message.id = path.id ORDER BY path.depth
            """, arguments: ["chat": chatID])
    }

    public static func message(_ id: String, db: Database) throws -> MessageRecord {
        guard let record = try MessageRecord.fetchOne(db, key: id) else { throw StorageError.notFound("message \(id)") }
        return record
    }

    /// Siblings of `messageID` including itself, in version order.
    public static func siblings(of messageID: String, db: Database) throws -> [MessageRecord] {
        let target = try message(messageID, db: db)
        return try children(of: target.parentID, chatID: target.chatID, db: db)
    }

    /// Children of `parentID` (nil = the roots of `chatID`), in version order.
    public static func children(of parentID: String?, chatID: String, db: Database) throws -> [MessageRecord] {
        try MessageRecord
            .filter(MessageRecord.Columns.chatID == chatID && MessageRecord.Columns.parentID == parentID)
            .order(MessageRecord.Columns.position, MessageRecord.Columns.id)
            .fetchAll(db)
    }

    /// ‹index/total›, 1-based.
    public static func versionInfo(_ messageID: String, db: Database) throws -> (index: Int, total: Int) {
        let siblings = try siblings(of: messageID, db: db)
        guard let i = siblings.firstIndex(where: { $0.id == messageID }) else {
            throw StorageError.notFound("message \(messageID)")
        }
        return (i + 1, siblings.count)
    }

    /// Ancestors of `messageID` and itself, root first.
    public static func ancestry(of messageID: String, db: Database) throws -> [MessageRecord] {
        try MessageRecord.fetchAll(db, sql: """
            WITH RECURSIVE up(id, parent_id, depth) AS (
              SELECT id, parent_id, 0 FROM message WHERE id = ?
              UNION ALL
              SELECT m.id, m.parent_id, up.depth + 1 FROM up JOIN message m ON m.id = up.parent_id
              WHERE up.depth < 1000000
            )
            SELECT message.* FROM up JOIN message ON message.id = up.id ORDER BY up.depth DESC
            """, arguments: [messageID])
    }

    // MARK: - Writes

    @discardableResult
    public static func append(
        chatID: String, parentID: String?, role: MessageRole, status: MessageStatus = .done,
        parts: [PartContent] = [], configure: (inout MessageRecord) -> Void = { _ in }, db: Database
    ) throws -> MessageRecord {
        if let parentID {
            let parent = try message(parentID, db: db)
            guard parent.chatID == chatID else { throw StorageError.invalidTree("parent \(parentID) is in another chat") }
        }
        let next = try Int.fetchOne(db, sql: """
            SELECT COALESCE(MAX(position) + 1, 0) FROM message WHERE chat_id = ? AND parent_id IS ?
            """, arguments: [chatID, parentID]) ?? 0
        var record = MessageRecord(chatID: chatID, parentID: parentID, position: next, role: role, status: status)
        configure(&record)
        record.chatID = chatID
        record.parentID = parentID
        record.position = next
        record.activeChildID = nil
        try record.insert(db)
        for (idx, part) in parts.enumerated() {
            var row = MessagePartRecord(messageID: record.id, idx: idx, kind: part.kind, body: part.body,
                                        untrusted: part.untrusted)
            try row.insert(db)
        }
        try setActive(record.id, db: db)
        return record
    }

    @discardableResult
    public static func insertSibling(
        of messageID: String, role: MessageRole? = nil, status: MessageStatus = .done, parts: [PartContent] = [],
        configure: (inout MessageRecord) -> Void = { _ in }, db: Database
    ) throws -> MessageRecord {
        let target = try message(messageID, db: db)
        return try append(chatID: target.chatID, parentID: target.parentID, role: role ?? target.role, status: status,
                          parts: parts, configure: configure, db: db)
    }

    /// Makes `messageID` visible: every ancestor's `active_child_id` points down to it, and the leaf becomes the end
    /// of the active chain below it. For a node already on the path this changes only its parent's pointer.
    public static func setActive(_ messageID: String, db: Database) throws {
        let chain = try ancestry(of: messageID, db: db)
        guard let target = chain.last, target.id == messageID else { throw StorageError.notFound("message \(messageID)") }
        for (parent, child) in zip(chain, chain.dropFirst()) where parent.activeChildID != child.id {
            try db.execute(sql: "UPDATE message SET active_child_id = ? WHERE id = ?", arguments: [child.id, parent.id])
        }
        let leaf = try descendActive(from: messageID, db: db)
        try db.execute(
            sql: "UPDATE chat SET leaf_message_id = ?, updated_at = ? WHERE id = ?",
            arguments: [leaf, Date().timeIntervalSince1970, target.chatID])
    }

    /// The end of the `active_child_id` chain starting at `messageID`.
    public static func descendActive(from messageID: String, db: Database) throws -> String {
        try String.fetchOne(db, sql: """
            WITH RECURSIVE down(id, depth) AS (
              SELECT ?, 0
              UNION ALL
              SELECT m.active_child_id, down.depth + 1 FROM down JOIN message m ON m.id = down.id
              WHERE m.active_child_id IS NOT NULL AND down.depth < 1000000
            )
            SELECT id FROM down ORDER BY depth DESC LIMIT 1
            """, arguments: [messageID]) ?? messageID
    }

    /// Recomputes `chat.leaf_message_id` from the active root (after deletes or repairs).
    public static func refreshLeaf(_ chatID: String, db: Database) throws {
        let leaf = try visiblePath(chatID, db: db).last?.id
        try db.execute(sql: "UPDATE chat SET leaf_message_id = ? WHERE id = ?", arguments: [leaf, chatID])
    }

    @discardableResult
    public static func branchCopy(upTo messageID: String, title: String, mode: ChatMode? = nil, db: Database) throws -> String {
        let path = try ancestry(of: messageID, db: db)
        guard let last = path.last, last.id == messageID else { throw StorageError.notFound("message \(messageID)") }
        guard let source = try ChatRecord.fetchOne(db, key: last.chatID) else {
            throw StorageError.notFound("chat \(last.chatID)")
        }
        let now = Date()
        let chat = ChatRecord(
            title: title, titleState: .user, mode: mode ?? source.mode, projectID: source.projectID, createdAt: now,
            memoryEnabled: source.memoryEnabled, toolsJSON: source.toolsJSON, modelSlotSnapshot: source.modelSlotSnapshot)
        try chat.insert(db)
        var newID: [String: String] = [:]
        for node in path { newID[node.id] = StorageID.make() }
        for (i, node) in path.enumerated() {
            var copy = node
            copy.id = newID[node.id]!
            copy.chatID = chat.id
            copy.parentID = i == 0 ? nil : newID[path[i - 1].id]
            copy.activeChildID = i + 1 < path.count ? newID[path[i + 1].id] : nil
            copy.position = 0
            copy.sourceID = nil
            copy.recovered = false
            copy.summaryOfIDs = node.summaryOfIDs.map { $0.compactMap { newID[$0] } }
            try copy.insert(db)
            try db.execute(sql: """
                INSERT INTO message_part (message_id, idx, kind, body, untrusted)
                SELECT ?, idx, kind, body, untrusted FROM message_part WHERE message_id = ? ORDER BY idx
                """, arguments: [copy.id, node.id])
            let attachments = try AttachmentRecord.filter(Column("message_id") == node.id).fetchAll(db)
            for var attachment in attachments {
                attachment.id = StorageID.make()
                attachment.messageID = copy.id
                try attachment.insert(db)
            }
        }
        try db.execute(sql: "UPDATE chat SET leaf_message_id = ? WHERE id = ?", arguments: [newID[messageID], chat.id])
        return chat.id
    }
}
