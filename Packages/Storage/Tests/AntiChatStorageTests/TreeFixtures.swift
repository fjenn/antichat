// Shared fixtures and checks for the storage tests (M1.T04).
// - `TreeFixtures.treeBasic()`: fixture chat `tree-basic` (one chat, 3 user/assistant turns, in-memory DB).
// - `fixturesRoot`: the fixtures checkout (`ANTICHAT_FIXTURES` overrides `<repo>/fixtures`).
// - `TreeShape` / `readShapes`: the comparable tree shape of M0.T11 step 1, rebuilt from the database alone.
// - `TreeInvariants.violations`: the tree invariants of M1.T04 step 6.
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let fixturesRoot: URL = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"].map(URL.init(fileURLWithPath:))
    ?? repoRoot.appendingPathComponent("fixtures")

/// Every `*.expected.json` in `dirs`, as "<dir>/<name>" relative to the fixtures root.
func expectedFiles(in dirs: [String]) -> [String] {
    dirs.flatMap { dir -> [String] in
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: fixturesRoot.appendingPathComponent(dir).path)) ?? []
        return names.filter { $0.hasSuffix(".expected.json") }.sorted().map { "\(dir)/\($0)" }
    }
}

/// Every import fixture file (the inputs behind the `*.expected.json` files).
func importFixtureFiles() -> [URL] {
    expectedFiles(in: ["chats/chatgpt-export", "chats/claude-export"]).compactMap { path in
        let url = fixturesRoot.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["fixture"] as? String else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }
}

enum TreeFixtures {
    struct TreeBasic {
        let database: AppDatabase
        let chatID: String
        /// u1, a1, u2, a2, u3, a3 (the active path, root first).
        let ids: [String]
    }

    /// Fixture chat `tree-basic`: one chat, 3 user/assistant turns.
    static func treeBasic(_ database: AppDatabase? = nil) throws -> TreeBasic {
        let database = try database ?? AppDatabase.inMemory()
        let chat = try ChatRepository(database).create(title: "tree-basic")
        let tree = MessageTree(database)
        var ids: [String] = []
        for turn in 1...3 {
            let user = try tree.append(chatID: chat.id, parentID: ids.last, role: .user, parts: [.text("question \(turn)")])
            let reply = try tree.append(chatID: chat.id, parentID: user.id, role: .assistant,
                                        parts: [.text("answer \(turn)")]) {
                $0.modelID = "chat-0.8b"
                $0.engine = "mlx"
                $0.provenance = MessageProvenance(modelSHA: "sha256-fixture", mode: .normal,
                                                  sampling: ["temperature": 0.7, "top_p": 0.95], tokPerS: 88.5)
            }
            ids += [user.id, reply.id]
        }
        return TreeBasic(database: database, chatID: chat.id, ids: ids)
    }
}

/// The comparable shape of one conversation (M0.md T11 step 1).
struct TreeShape: Equatable, CustomStringConvertible {
    var id: String
    var nodes: Int
    var edges: [[String?]]  // [child, parent], sorted
    var recovered: [String]
    var activeLeaf: String?
    var activePath: [String]
    var description: String { "\(id): \(nodes) nodes, leaf \(activeLeaf ?? "nil"), path \(activePath.count)" }

    init(id: String, nodes: Int, edges: [[String?]], recovered: [String], activeLeaf: String?, activePath: [String]) {
        self.id = id
        self.nodes = nodes
        self.edges = edges.sorted { ($0[0] ?? "") < ($1[0] ?? "") }
        self.recovered = recovered.sorted()
        self.activeLeaf = activeLeaf
        self.activePath = activePath
    }

    init(expected object: [String: Any]) {
        let edges = (object["edges"] as? [[Any]] ?? []).map { pair in pair.map { $0 as? String } }
        self.init(
            id: object["id"] as? String ?? "", nodes: object["nodes"] as? Int ?? -1, edges: edges,
            recovered: object["recovered"] as? [String] ?? [], activeLeaf: object["active_leaf"] as? String,
            activePath: object["active_path"] as? [String] ?? [])
    }

    /// Field-by-field differences, for a readable failure message.
    func differences(from other: TreeShape) -> [String] {
        var out: [String] = []
        if nodes != other.nodes { out.append("nodes \(nodes) != expected \(other.nodes)") }
        let mine = Set(edges.map { "\($0[0] ?? "nil")<-\($0[1] ?? "nil")" })
        let theirs = Set(other.edges.map { "\($0[0] ?? "nil")<-\($0[1] ?? "nil")" })
        for e in theirs.subtracting(mine).sorted() { out.append("missing edge \(e)") }
        for e in mine.subtracting(theirs).sorted() { out.append("extra edge \(e)") }
        if recovered != other.recovered { out.append("recovered \(recovered) != expected \(other.recovered)") }
        if activeLeaf != other.activeLeaf { out.append("active_leaf \(activeLeaf ?? "nil") != \(other.activeLeaf ?? "nil")") }
        if activePath != other.activePath { out.append("active_path \(activePath) != \(other.activePath)") }
        return out
    }
}

struct ReadShape {
    var chatID: String
    var shape: TreeShape
    /// The path read down from the root via `active_child_id`.
    var downPath: [String]
    /// The path from `MessageTree.visiblePath` (recursive CTE).
    var ctePath: [String]
    var emptyMessages: Int
}

/// Rebuilds every chat's shape from the database alone (no importer state), in source ids.
/// The active path is read three ways and must agree: up from `chat.leaf_message_id` via `parent_id`, down from
/// that path's root via `active_child_id`, and with `MessageTree.visiblePath`.
func readShapes(_ db: Database) throws -> [ReadShape] {
    let chats = try Row.fetchAll(db, sql: "SELECT id, source_id, leaf_message_id FROM chat ORDER BY rowid")
    return try chats.map { chat in
        let chatId: String = chat["id"]
        let rows = try Row.fetchAll(
            db, sql: "SELECT id, parent_id, active_child_id, source_id, recovered FROM message WHERE chat_id = ?",
            arguments: [chatId])
        var source: [String: String] = [:]
        var parent: [String: String?] = [:]
        var activeChild: [String: String?] = [:]
        var recovered: [String] = []
        for row in rows {
            let id: String = row["id"]
            source[id] = row["source_id"]
            parent[id] = row["parent_id"] as String?
            activeChild[id] = row["active_child_id"] as String?
            if row["recovered"] as Bool { recovered.append(row["source_id"]) }
        }
        let edges: [[String?]] = rows.map { row in
            let id: String = row["id"]
            return [source[id], parent[id]!.flatMap { source[$0] }]
        }
        let leaf: String? = chat["leaf_message_id"]
        var up: [String] = []
        var cursor = leaf
        while let c = cursor, up.count <= rows.count { up.append(c); cursor = parent[c] ?? nil }
        up.reverse()
        var down: [String] = []
        cursor = up.first
        while let c = cursor, down.count <= rows.count {
            down.append(c)
            if c == leaf { break }
            cursor = activeChild[c] ?? nil
        }
        let cte = try MessageTree.visiblePath(chatId, db: db).map(\.id)
        let empty = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM message m WHERE chat_id = ?
              AND NOT EXISTS (SELECT 1 FROM message_part p WHERE p.message_id = m.id AND length(trim(p.body)) > 0)
            """, arguments: [chatId]) ?? -1
        let shape = TreeShape(
            id: chat["source_id"] ?? "", nodes: rows.count, edges: edges, recovered: recovered,
            activeLeaf: leaf.flatMap { source[$0] }, activePath: up.compactMap { source[$0] })
        return ReadShape(chatID: chatId, shape: shape, downPath: down.compactMap { source[$0] },
                         ctePath: cte.compactMap { source[$0] }, emptyMessages: empty)
    }
}

enum TreeInvariants {
    /// M1.T04 step 6: every `parent_id` exists (in the same chat), every `active_child_id` is a child, the leaf is
    /// the end of the active path, the tree is acyclic and every chat with messages has at least one root. Versions of
    /// the first message are sibling roots, so "one root per chat" is checked as "one active root".
    static func violations(_ db: Database) throws -> [String] {
        var out: [String] = []
        let checks: [(String, String)] = [
            ("parent missing or in another chat", """
                SELECT m.id FROM message m LEFT JOIN message p ON p.id = m.parent_id
                WHERE m.parent_id IS NOT NULL AND (p.id IS NULL OR p.chat_id <> m.chat_id)
                """),
            ("active child is not a child", """
                SELECT m.id FROM message m LEFT JOIN message c ON c.id = m.active_child_id
                WHERE m.active_child_id IS NOT NULL AND (c.id IS NULL OR c.parent_id IS NOT m.id)
                """),
            ("node with children but no active child", """
                SELECT DISTINCT p.id FROM message p JOIN message c ON c.parent_id = p.id
                WHERE p.active_child_id IS NULL AND p.id NOT IN (SELECT leaf_message_id FROM chat WHERE leaf_message_id IS NOT NULL)
                """),
            ("chat with messages but no root", """
                SELECT c.id FROM chat c WHERE EXISTS (SELECT 1 FROM message m WHERE m.chat_id = c.id)
                AND NOT EXISTS (SELECT 1 FROM message m WHERE m.chat_id = c.id AND m.parent_id IS NULL)
                """),
            ("chat with messages but no leaf", """
                SELECT c.id FROM chat c WHERE c.leaf_message_id IS NULL
                AND EXISTS (SELECT 1 FROM message m WHERE m.chat_id = c.id)
                """),
            ("leaf in another chat", """
                SELECT c.id FROM chat c JOIN message m ON m.id = c.leaf_message_id WHERE m.chat_id <> c.id
                """),
            ("part of a missing message", """
                SELECT p.id FROM message_part p LEFT JOIN message m ON m.id = p.message_id WHERE m.id IS NULL
                """),
        ]
        for (name, sql) in checks {
            let ids = try String.fetchAll(db, sql: sql)
            if !ids.isEmpty { out.append("\(name): \(ids.prefix(5))") }
        }
        // Acyclic + leaf = end of the active path, per chat.
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? 0
        let reach = try Int.fetchOne(db, sql: """
            WITH RECURSIVE r(id, depth) AS (
              SELECT id, 0 FROM message WHERE parent_id IS NULL
              UNION ALL SELECT m.id, r.depth + 1 FROM r JOIN message m ON m.parent_id = r.id WHERE r.depth < 100000
            ) SELECT COUNT(DISTINCT id) FROM r
            """) ?? 0
        if reach != total { out.append("cycle or unreachable nodes: \(total - reach)") }
        for chatID in try String.fetchAll(db, sql: "SELECT id FROM chat WHERE leaf_message_id IS NOT NULL") {
            let path = try MessageTree.visiblePath(chatID, db: db)
            let leaf = try String.fetchOne(db, sql: "SELECT leaf_message_id FROM chat WHERE id = ?", arguments: [chatID])
            if path.last?.id != leaf { out.append("chat \(chatID): leaf is not the end of the active path") }
        }
        let fk = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
        if !fk.isEmpty { out.append("foreign_key_check: \(fk.count) rows") }
        return out
    }
}

/// Records an issue for every tree-invariant violation in `database`.
func expectValidTrees(_ database: AppDatabase, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let violations = try database.read { db in try TreeInvariants.violations(db) }
    #expect(violations == [], sourceLocation: sourceLocation)
}

/// An export with every id replaced by its preorder index (structural comparison, AT-296 (3)).
func normalizedExport(_ data: Data) throws -> TreeExportDocument {
    var document = try TreeExportDocument.decoder().decode(TreeExportDocument.self, from: data)
    var index: [String: String] = [:]
    for (i, node) in document.nodes.enumerated() { index[node.id] = "n\(i)" }
    document.nodes = document.nodes.map { node in
        var n = node
        n.id = index[node.id]!
        n.parentID = node.parentID.map { index[$0] ?? "?\($0)" }
        n.activeChildID = node.activeChildID.map { index[$0] ?? "?\($0)" }
        n.summaryOfIDs = node.summaryOfIDs.map { $0.map { index[$0] ?? "?\($0)" } }
        return n
    }
    document.leafID = document.leafID.map { index[$0] ?? "?\($0)" }
    return document
}
