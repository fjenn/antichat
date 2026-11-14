// Whole-tree export / import (R-296 "export → import round-trip keeps the tree"). Schema `antichat.tree.v1`:
// every node of the chat (not only the active path), in preorder (parents first, siblings by position), with
// its parts. Import remaps every id to a fresh UUIDv7 and keeps the structure, versions and active path.
import Foundation
import GRDB

public struct TreeExportDocument: Codable, Sendable, Equatable {
    public static let schemaID = "antichat.tree.v1"

    public struct Chat: Codable, Sendable, Equatable {
        public var title: String
        public var titleState: TitleState
        public var mode: ChatMode
        public var pinned: Bool
        public var archivedAt: Date?
        public var createdAt: Date
        public var updatedAt: Date
        public var memoryEnabled: Bool
        public var toolsJSON: String?
        public var modelSlotSnapshot: String?
        public var source: ChatSource
        public var sourceID: String?
        public var importNotice: ImportNotice?

        enum CodingKeys: String, CodingKey {
            case title, mode, pinned, source
            case titleState = "title_state", archivedAt = "archived_at", createdAt = "created_at"
            case updatedAt = "updated_at", memoryEnabled = "memory_enabled", toolsJSON = "tools_json"
            case modelSlotSnapshot = "model_slot_snapshot", sourceID = "source_id", importNotice = "import_notice"
        }
    }

    public struct Node: Codable, Sendable, Equatable {
        public var id: String
        public var parentID: String?
        public var activeChildID: String?
        public var position: Int
        public var role: MessageRole
        public var status: MessageStatus
        public var modelID: String?
        public var engine: String?
        public var usage: MessageUsage?
        public var provenance: MessageProvenance?
        public var contextSummary: String?
        public var summaryOfIDs: [String]?
        public var errorCode: String?
        public var createdAt: Date
        public var sourceID: String?
        public var recovered: Bool
        public var parts: [PartContent]

        enum CodingKeys: String, CodingKey {
            case id, position, role, status, engine, usage, provenance, recovered, parts
            case parentID = "parent_id", activeChildID = "active_child_id", modelID = "model_id"
            case contextSummary = "context_summary", summaryOfIDs = "summary_of_ids", errorCode = "error_code"
            case createdAt = "created_at", sourceID = "source_id"
        }
    }

    public var schema: String
    public var chat: Chat
    public var leafID: String?
    /// Preorder: every parent precedes its children; siblings by position.
    public var nodes: [Node]

    enum CodingKeys: String, CodingKey { case schema, chat, nodes, leafID = "leaf_id" }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        // Unix seconds rounded to the microsecond: `Date` keeps seconds since 2001, so a raw Double round trip
        // (DB → Date → JSON → Date → DB) can drift by an ulp; rounding makes repeated exports identical.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode((date.timeIntervalSince1970 * 1_000_000).rounded() / 1_000_000)
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

public enum TreeExport {
    public static func exportJSON(_ chatID: String, from database: AppDatabase) throws -> Data {
        try TreeExportDocument.encoder().encode(database.read { try document(chatID, db: $0) })
    }

    @discardableResult
    public static func importJSON(_ data: Data, into database: AppDatabase) throws -> String {
        let document: TreeExportDocument
        do {
            document = try TreeExportDocument.decoder().decode(TreeExportDocument.self, from: data)
        } catch {
            throw StorageError.invalidExport("not an \(TreeExportDocument.schemaID) document: \(error)")
        }
        return try database.write { try importDocument(document, db: $0) }
    }

    public static func document(_ chatID: String, db: Database) throws -> TreeExportDocument {
        guard let chat = try ChatRecord.fetchOne(db, key: chatID) else { throw StorageError.notFound("chat \(chatID)") }
        let messages = try MessageRecord.filter(MessageRecord.Columns.chatID == chatID).fetchAll(db)
        var partsByMessage: [String: [PartContent]] = [:]
        let parts = try MessagePartRecord
            .filter(sql: "message_id IN (SELECT id FROM message WHERE chat_id = ?)", arguments: [chatID])
            .order(MessagePartRecord.Columns.messageID, MessagePartRecord.Columns.idx)
            .fetchAll(db)
        for part in parts {
            partsByMessage[part.messageID, default: []].append(
                PartContent(kind: part.kind, body: part.body, untrusted: part.untrusted))
        }
        var children: [String?: [MessageRecord]] = [:]
        for message in messages { children[message.parentID, default: []].append(message) }
        for key in children.keys { children[key]!.sort { ($0.position, $0.id) < ($1.position, $1.id) } }
        var nodes: [TreeExportDocument.Node] = []
        var stack: [MessageRecord] = (children[nil] ?? []).reversed()
        while let m = stack.popLast() {
            nodes.append(.init(
                id: m.id, parentID: m.parentID, activeChildID: m.activeChildID, position: m.position, role: m.role,
                status: m.status, modelID: m.modelID, engine: m.engine, usage: m.usage, provenance: m.provenance,
                contextSummary: m.contextSummary, summaryOfIDs: m.summaryOfIDs, errorCode: m.errorCode,
                createdAt: m.createdAt, sourceID: m.sourceID, recovered: m.recovered, parts: partsByMessage[m.id] ?? []))
            stack.append(contentsOf: (children[m.id] ?? []).reversed())
        }
        guard nodes.count == messages.count else {
            throw StorageError.invalidTree("chat \(chatID): \(messages.count - nodes.count) nodes unreachable from a root")
        }
        return TreeExportDocument(
            schema: TreeExportDocument.schemaID,
            chat: .init(
                title: chat.title, titleState: chat.titleState, mode: chat.mode, pinned: chat.pinned,
                archivedAt: chat.archivedAt, createdAt: chat.createdAt, updatedAt: chat.updatedAt,
                memoryEnabled: chat.memoryEnabled, toolsJSON: chat.toolsJSON, modelSlotSnapshot: chat.modelSlotSnapshot,
                source: chat.source, sourceID: chat.sourceID, importNotice: chat.importNotice),
            leafID: chat.leafMessageID, nodes: nodes)
    }

    public static func importDocument(_ document: TreeExportDocument, db: Database) throws -> String {
        guard document.schema == TreeExportDocument.schemaID else {
            throw StorageError.invalidExport("schema \(document.schema), expected \(TreeExportDocument.schemaID)")
        }
        var newID: [String: String] = [:]
        var parentOf: [String: String?] = [:]
        for node in document.nodes {
            guard newID[node.id] == nil else { throw StorageError.invalidExport("duplicate node \(node.id)") }
            if let parent = node.parentID, newID[parent] == nil {
                throw StorageError.invalidExport("node \(node.id): parent \(parent) missing or not before it")
            }
            newID[node.id] = StorageID.make()
            parentOf[node.id] = node.parentID
        }
        for node in document.nodes {
            if let child = node.activeChildID, parentOf[child] != .some(node.id) {
                throw StorageError.invalidExport("node \(node.id): active child \(child) is not its child")
            }
        }
        if let leaf = document.leafID, newID[leaf] == nil { throw StorageError.invalidExport("leaf \(leaf) missing") }

        let c = document.chat
        let chat = ChatRecord(
            title: c.title, titleState: c.titleState, mode: c.mode, pinned: c.pinned, archivedAt: c.archivedAt,
            createdAt: c.createdAt, updatedAt: c.updatedAt, memoryEnabled: c.memoryEnabled, toolsJSON: c.toolsJSON,
            modelSlotSnapshot: c.modelSlotSnapshot, source: c.source, sourceID: c.sourceID, importNotice: c.importNotice)
        try chat.insert(db)
        for node in document.nodes {
            let record = MessageRecord(
                id: newID[node.id]!, chatID: chat.id, parentID: node.parentID.flatMap { newID[$0] },
                activeChildID: node.activeChildID.flatMap { newID[$0] }, position: node.position, role: node.role,
                status: node.status, modelID: node.modelID, engine: node.engine, usage: node.usage,
                provenance: node.provenance, contextSummary: node.contextSummary,
                summaryOfIDs: node.summaryOfIDs.map { $0.compactMap { newID[$0] } }, errorCode: node.errorCode,
                createdAt: node.createdAt, sourceID: node.sourceID, recovered: node.recovered)
            try record.insert(db)
            for (idx, part) in node.parts.enumerated() {
                var row = MessagePartRecord(messageID: record.id, idx: idx, kind: part.kind, body: part.body,
                                            untrusted: part.untrusted)
                try row.insert(db)
            }
        }
        try db.execute(sql: "UPDATE chat SET leaf_message_id = ? WHERE id = ?",
                       arguments: [document.leafID.flatMap { newID[$0] }, chat.id])
        return chat.id
    }
}
