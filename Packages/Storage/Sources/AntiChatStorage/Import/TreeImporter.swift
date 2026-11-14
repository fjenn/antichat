// Promoted from the M0.T11 prototype (S-13, G-058, P-platform-10; `SpikeTreeImporter`, A-M0-T11a): ChatGPT
// `conversations.json` mapping trees and Claude data exports → the v1 message tree (architecture.md §5.1:
// `message.parent_id`, `active_child_id`, `position`, `chat.leaf_message_id`), every branch kept.
// Format detection and zip handling ported from osaurus-ai/osaurus@66c3dde:
// Packages/OsaurusCore/Managers/Chat/ChatSessionImporter.swift (MIT) `parse(data:)` / `parseArchive`,
// on ZIPFoundation 0.9.20 instead of Osaurus' `ZipArchive`. Unknown fields are ignored (D-004: no real export
// sample; real-sample validation is an M8 item). The import UI lands in M8 (AT-092).
import Foundation
import GRDB
import ZIPFoundation

// MARK: - Model shared by the mappings

/// One source node as the export has it, before tree repair. `role == nil` or empty `parts` = unusable.
struct RawNode {
    var id: String
    var parentId: String?
    /// Source child order (ChatGPT `children`); empty = use source order.
    var childOrder: [String]
    var role: MessageRole?
    var parts: [PartContent]
    var createdAt: Date?
    /// M8.T06 step 4: image references (ChatGPT asset pointer ids, e.g. `file-abc`), resolved against the zip.
    var images: [String] = []
    /// M8.T06 step 6: unsupported part types kept as text (`[Imported {type}]`), one entry per part.
    var kept: [String] = []
    /// M8.T06 step 5: the model slug (`imported:<slug>` in `message.model_id`).
    var model: String?
    var usable: Bool { role != nil && (!parts.isEmpty || !images.isEmpty) }
}

/// M8.T06 step 6: an unsupported part as plain text under a `[Imported {type}]` header (fenced, untrusted).
func keptPart(_ type: String, _ body: String, untrusted: Bool = false) -> PartContent {
    let fence = body.contains("```") ? "~~~~" : "```"
    return PartContent(kind: .text, body: "[Imported \(type)]\n\(fence)\n\(body)\n\(fence)", untrusted: untrusted)
}

public enum ImportFormat: String, Sendable { case chatGPT = "chatgpt", claude }

struct RawConversation {
    var format: ImportFormat
    var sourceId: String?
    var title: String
    var createdAt: Date?
    var updatedAt: Date?
    /// In source order (Claude: array order; ChatGPT: create_time, then id).
    var nodes: [RawNode]
    var currentLeaf: String?
    var notice: ImportNotice?
}

/// The repaired tree, ready to write: only usable nodes, each with its effective parent.
public struct ImportedTree: Sendable {
    public struct Node: Sendable {
        public var sourceId: String
        public var parentSourceId: String?
        public var activeChildSourceId: String?
        public var position: Int
        public var role: MessageRole
        public var parts: [PartContent]
        public var createdAt: Date?
        /// Re-attached because its parent was missing or part of a cycle (M0.md T11 failure mode 2).
        public var recovered: Bool
        /// M8.T06: image references and kept-as-text part types of this node; the source model slug.
        public var images: [String] = []
        public var kept: [String] = []
        public var model: String?
    }
    public var format: ImportFormat
    public var sourceId: String?
    public var title: String
    public var createdAt: Date?
    public var updatedAt: Date?
    /// Preorder (parents before children, siblings by source order).
    public var nodes: [Node]
    public var activeLeaf: String?
    public var activePath: [String]
    public var notice: ImportNotice?
}

public enum ImportError: Error, Equatable {
    case invalidJSON, unrecognizedFormat, noConversations
    /// M8.T07: an AntiChat export of a newer format version (`import.newerExport`).
    case newerExport
}

// MARK: - Importer

public enum TreeImporter {
    /// Parses a ChatGPT `conversations.json`, a Claude export JSON, or a zip of either.
    public static func parse(data: Data) throws -> [ImportedTree] {
        try raw(data: data).map(buildTree)
    }

    /// Parses `data` and writes every conversation into `database` in one transaction. Returns the new chat ids.
    @discardableResult
    public static func importExport(data: Data, into database: AppDatabase) throws -> [String] {
        let trees = try parse(data: data)
        return try database.write { db in try trees.map { try write($0, db) } }
    }

    static func raw(data: Data) throws -> [RawConversation] {
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return try rawArchive(data) }
        guard let root = try? JSONSerialization.jsonObject(with: data) else { throw ImportError.invalidJSON }
        let items: [[String: Any]]
        if let array = root as? [[String: Any]] {
            items = array
        } else if let object = root as? [String: Any] {
            items = [object]
        } else {
            throw ImportError.unrecognizedFormat
        }
        let parsed: [RawConversation]
        if items.contains(where: ChatGPTTreeImporter.matches) {
            parsed = items.compactMap(ChatGPTTreeImporter.parse)
        } else if items.contains(where: ClaudeTreeImporter.matches) {
            parsed = items.compactMap(ClaudeTreeImporter.parse)
        } else {
            throw ImportError.unrecognizedFormat
        }
        guard !parsed.isEmpty else { throw ImportError.noConversations }
        return parsed
    }

    /// Every `.json` entry that parses as a known format (users.json etc. are skipped, as upstream).
    private static func rawArchive(_ data: Data) throws -> [RawConversation] {
        let archive = try Archive(data: data, accessMode: .read)
        var all: [RawConversation] = []
        let entries = archive.filter { entry in
            let name = entry.path.lowercased()
            return entry.type == .file && name.hasSuffix(".json") && !name.hasPrefix("__macosx/")
                && !(name.split(separator: "/").last?.hasPrefix("._") ?? false)
        }.sorted { $0.path < $1.path }
        for entry in entries {
            let buffer = try ChatImporter.read(archive, entry)
            if let parsed = try? raw(data: buffer) { all.append(contentsOf: parsed) }
        }
        guard !all.isEmpty else { throw ImportError.noConversations }
        return all
    }

    // MARK: Tree repair (M0.md T11 step 3)

    static func buildTree(_ conversation: RawConversation) -> ImportedTree {
        var byId: [String: RawNode] = [:]
        var order: [String] = []
        for node in conversation.nodes where byId[node.id] == nil {
            byId[node.id] = node
            order.append(node.id)
        }
        let sourceIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })

        // 1. Resolved parent per raw node: missing parents and cycles are cut and re-attached.
        var parent: [String: String?] = [:]
        var recovered = Set<String>()
        for id in order { parent[id] = byId[id]!.parentId }
        let realRoot = order.first { byId[$0]!.parentId == nil }
        func reattach(_ id: String) {
            parent[id] = (realRoot == id) ? nil : realRoot
            recovered.insert(id)
        }
        for id in order {
            if let p = parent[id]!, byId[p] == nil { reattach(id) }  // dangling parent → orphan
        }
        // Cycles: walk up from each node; at the first repeated id, cut that node's parent edge.
        for start in order {
            var seen = Set<String>()
            var current: String? = start
            while let c = current {
                if !seen.insert(c).inserted {
                    reattach(c)
                    break
                }
                current = parent[c]!
            }
        }

        // 2. Effective parent of each usable node = nearest usable ancestor.
        func effectiveParent(_ id: String) -> String? {
            var p = parent[id]!
            while let candidate = p, !byId[candidate]!.usable { p = parent[candidate]! }
            return p
        }
        let usable = order.filter { byId[$0]!.usable }

        // 3. Sibling order: preorder of the full raw tree, children by source `children` order, then source order.
        var rawChildren: [String?: [String]] = [:]
        for id in order { rawChildren[parent[id]!, default: []].append(id) }
        func childKey(_ parentId: String?, _ id: String) -> (Int, Int) {
            let hint = parentId.flatMap { byId[$0]!.childOrder.firstIndex(of: id) } ?? Int.max
            return (hint, sourceIndex[id]!)
        }
        var preorder: [String: Int] = [:]
        var stack: [String] = (rawChildren[nil] ?? []).sorted { childKey(nil, $0) < childKey(nil, $1) }.reversed()
        while let id = stack.popLast() {
            preorder[id] = preorder.count
            let kids = (rawChildren[id] ?? []).sorted { childKey(id, $0) < childKey(id, $1) }
            stack.append(contentsOf: kids.reversed())
        }
        var children: [String?: [String]] = [:]
        var effParent: [String: String?] = [:]
        for id in usable {
            let p = effectiveParent(id)
            effParent[id] = p
            children[p, default: []].append(id)
        }
        for key in children.keys { children[key]!.sort { preorder[$0]! < preorder[$1]! } }

        // 4. Active leaf: current node (or its nearest usable ancestor), else the last-child descent.
        var leaf: String?
        if let current = conversation.currentLeaf, byId[current] != nil {
            leaf = byId[current]!.usable ? current : effectiveParent(current)
        }
        if leaf == nil {
            var cursor = children[nil]?.last
            while let c = cursor, let next = children[c]?.last { cursor = next }
            leaf = cursor
        }
        var path: [String] = []
        var cursor = leaf
        while let c = cursor { path.append(c); cursor = effParent[c]! }
        path.reverse()
        let next = Dictionary(uniqueKeysWithValues: zip(path, path.dropFirst()).map { ($0, $1) })

        // 5. Nodes in preorder of the repaired tree; active child = next on the path, else the last child.
        var out: [ImportedTree.Node] = []
        var work: [String] = (children[nil] ?? []).reversed()
        while let id = work.popLast() {
            let raw = byId[id]!
            let kids = children[id] ?? []
            let active: String? = (id == leaf) ? nil : (next[id] ?? kids.last)
            let siblings = children[effParent[id]!] ?? []
            out.append(.init(
                sourceId: id, parentSourceId: effParent[id]!, activeChildSourceId: active,
                position: siblings.firstIndex(of: id)!, role: raw.role!, parts: raw.parts,
                createdAt: raw.createdAt, recovered: recovered.contains(id), images: raw.images, kept: raw.kept,
                model: raw.model
            ))
            work.append(contentsOf: kids.reversed())
        }
        return ImportedTree(
            format: conversation.format, sourceId: conversation.sourceId, title: conversation.title,
            createdAt: conversation.createdAt, updatedAt: conversation.updatedAt, nodes: out,
            activeLeaf: leaf, activePath: path, notice: conversation.notice
        )
    }

    // MARK: Write (GRDB)

    /// Writes one repaired tree as a new chat (fresh UUIDv7 ids; source ids kept in `source_id`). M8.T06: `replacing`
    /// = an existing chat whose messages are replaced (re-import of a newer export: same chat id, project, pins);
    /// `image` resolves a node's image reference to a stored blob (attachment rows on that message).
    static func write(_ tree: ImportedTree, _ db: Database, replacing: String? = nil,
                      image: (String) throws -> FileBlobRecord? = { _ in nil }) throws -> String {
        let now = Date()
        let created = tree.createdAt ?? tree.nodes.compactMap(\.createdAt).min() ?? now
        let title = tree.title.isEmpty ? Self.fallbackTitle(tree) : tree.title
        var chat = ChatRecord(
            title: title, titleState: title.isEmpty ? .pending : .user, createdAt: created,
            updatedAt: tree.updatedAt ?? created, source: tree.format.chatSource, sourceID: tree.sourceId,
            importNotice: tree.notice)
        if let replacing, var existing = try ChatRecord.fetchOne(db, key: replacing) {
            try db.execute(sql: "UPDATE chat SET leaf_message_id = NULL WHERE id = ?", arguments: [replacing])
            try db.execute(sql: "DELETE FROM message WHERE chat_id = ?", arguments: [replacing])
            existing.title = chat.title
            existing.titleState = chat.titleState
            existing.updatedAt = chat.updatedAt
            existing.importNotice = chat.importNotice
            try existing.update(db)
            chat = existing
        } else {
            try chat.insert(db)
        }
        var ids: [String: String] = [:]
        for node in tree.nodes { ids[node.sourceId] = StorageID.make() }
        // M8.T06 step 11: cached statements (no per-row record encoding) — the 1 GB export writes ~1 M rows.
        // `active_child_id` is set after every row exists: inserted pointing forward, it leaves a pending DEFERRED
        // foreign-key violation, and while one is pending SQLite checks each later message insert against the
        // un-indexed `active_child_id` column with a full scan of `message` (quadratic: the 1 GB import never ended).
        let insertMessage = try db.cachedStatement(sql: """
            INSERT INTO message (id, chat_id, parent_id, active_child_id, position, role, status, model_id, created_at,
                                 source_id, recovered) VALUES (?, ?, ?, ?, ?, ?, 'done', ?, ?, ?, ?)
            """)
        let insertPart = try db.cachedStatement(sql: "INSERT INTO message_part (message_id, idx, kind, body, untrusted) VALUES (?, ?, ?, ?, ?)")
        for node in tree.nodes {  // preorder: parents are inserted first
            let id = ids[node.sourceId]!
            let model: String? = node.model.flatMap { $0.isEmpty ? nil : "imported:\($0)" }
            try insertMessage.execute(arguments: [
                id, chat.id, node.parentSourceId.flatMap { ids[$0] }, nil,
                node.position, node.role.rawValue, model, (node.createdAt ?? created).timeIntervalSince1970, node.sourceId,
                node.recovered])
            for ref in node.images {
                guard let blob = try image(ref) else { continue }
                let ext = (blob.path as NSString).pathExtension.lowercased()
                let uti = ext == "png" ? "public.png" : ext == "webp" ? "org.webmproject.webp" : ext == "gif" ? "com.compuserve.gif" : "public.jpeg"
                try AttachmentRecord(messageID: id, blobID: blob.id, displayName: "\(ref).\(ext.isEmpty ? "png" : ext)",
                                     uti: uti, createdAt: node.createdAt ?? created).insert(db)
            }
            for (idx, part) in node.parts.enumerated() {
                try insertPart.execute(arguments: [id, idx, part.kind.rawValue, part.body, part.untrusted])
            }
        }
        let setActive = try db.cachedStatement(sql: "UPDATE message SET active_child_id = ? WHERE id = ?")
        for node in tree.nodes {
            if let child = node.activeChildSourceId.flatMap({ ids[$0] }) { try setActive.execute(arguments: [child, ids[node.sourceId]!]) }
        }
        try db.execute(sql: "UPDATE chat SET leaf_message_id = ? WHERE id = ?",
                       arguments: [tree.activeLeaf.flatMap { ids[$0] }, chat.id])
        return chat.id
    }

    /// Step 5: no title in the export → the first user line, ≤ 60 characters.
    static func fallbackTitle(_ tree: ImportedTree) -> String {
        guard let first = tree.nodes.first(where: { $0.role == .user }),
              let text = first.parts.first(where: { $0.kind == .text })?.body else { return "" }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.count <= 60 ? line : String(line.prefix(59)) + "…"
    }
}

extension ImportFormat {
    var chatSource: ChatSource {
        switch self {
        case .chatGPT: .chatgpt
        case .claude: .claude
        }
    }
}
