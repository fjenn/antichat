// M8.T02 step 3 (R-243 AC1/AC2): the frozen memory block. Built exactly once, at a chat's first send, before the
// prompt renders: all active items of the chat's scope when their text fits 2,000 characters (grouped by topic), else
// the items nearest to the first message (cosine on stored vectors; FTS order without an embedder) until 2,000.
// Stored in `chat.memory_snapshot_json` + its SHA-256 in `memory_snapshot_hash`; every later turn (also after a
// relaunch) reuses the stored block verbatim, so the stable prefix never changes. Facts written during the chat ride
// on a short volatile line instead (≤ 500 chars), outside the stable prefix.
import AntiChatEngineProtocol
import AntiChatStorage
import CryptoKit
import Foundation
import GRDB

public struct MemorySnapshot: Codable, Sendable, Equatable {
    /// The rendered stable block ("" = no memory for this chat).
    public var block: String
    /// The items it contains (provenance `memoryReads`, "Used memory ▸").
    public var itemIDs: [String]
    public var createdAt: Date
}

public struct MemorySnapshotBuilder: Sendable {
    public static let maxChars = 2_000
    public static let maxVolatileChars = 500
    public static let header = "## What you know about the user"
    public let store: MemoryStore
    public let embedder: (any Embedder)?

    public init(store: MemoryStore, embedder: (any Embedder)?) {
        self.store = store
        self.embedder = embedder
    }

    /// The chat's frozen snapshot: the stored one, else built now from `firstUserMessage` and stored. `usable` false
    /// (memory off for this chat, incognito, Evil without the setting) stores an empty snapshot, also frozen.
    public func snapshot(chatID: String, firstUserMessage: String, scope: MemoryScope = .global, projectID: String? = nil,
                         usable: Bool) async throws -> MemorySnapshot {
        if let stored = try stored(chatID: chatID) { return stored }
        var snap = MemorySnapshot(block: "", itemIDs: [], createdAt: store.now())
        if usable {
            var entries = try store.active(scope: .global)
            if scope == .project, let projectID { entries = try store.active(scope: .project, projectID: projectID) }
            let chosen = try await select(entries, query: firstUserMessage)
            snap.itemIDs = chosen.map(\.item.id)
            snap.block = Self.render(chosen)
        }
        let json = String(data: try JSONEncoder.memory.encode(snap), encoding: .utf8) ?? "{}"
        let hash = SHA256.hash(data: Data(snap.block.utf8)).map { String(format: "%02x", $0) }.joined()
        try store.database.write { db in
            try db.execute(sql: """
                UPDATE chat SET memory_snapshot_json = ?, memory_snapshot_hash = ? WHERE id = ? AND memory_snapshot_json IS NULL
                """, arguments: [json, hash, chatID])
        }
        return try stored(chatID: chatID) ?? snap
    }

    public func stored(chatID: String) throws -> MemorySnapshot? {
        try store.database.read { db in
            try String.fetchOne(db, sql: "SELECT memory_snapshot_json FROM chat WHERE id = ?", arguments: [chatID])
        }.flatMap { try? JSONDecoder.memory.decode(MemorySnapshot.self, from: Data($0.utf8)) }
    }

    public func storedHash(chatID: String) throws -> String? {
        try store.database.read { try String.fetchOne($0, sql: "SELECT memory_snapshot_hash FROM chat WHERE id = ?", arguments: [chatID]) }
    }

    /// All entries when they fit, else the nearest to `query` until the block is full.
    func select(_ entries: [MemoryEntry], query: String) async throws -> [MemoryEntry] {
        if Self.render(entries).count <= Self.maxChars { return entries }
        var ranked = entries
        if let embedder, let q = try? await embedder.embed([query], kind: .query).first {
            let vectors = try store.vectors(entries.map(\.item.id))
            ranked = entries.sorted { a, b in
                let ca = vectors[a.item.id].map { MemoryUpdateDecider.cosine(q, $0) } ?? -1
                let cb = vectors[b.item.id].map { MemoryUpdateDecider.cosine(q, $0) } ?? -1
                return ca > cb
            }
        } else {  // newest first without vectors
            ranked = entries.sorted { $0.item.updatedAt > $1.item.updatedAt }
        }
        var chosen: [MemoryEntry] = []
        for e in ranked where Self.render(chosen + [e]).count <= Self.maxChars { chosen.append(e) }
        return chosen
    }

    /// `## What you know about the user` + one `- [Topic] text` line per item, topics A–Z, items oldest first.
    public static func render(_ entries: [MemoryEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        let lines = entries.sorted {
            ($0.topic.name.lowercased(), $0.item.createdAt, $0.item.id) < ($1.topic.name.lowercased(), $1.item.createdAt, $1.item.id)
        }.map { "- [\($0.topic.name)] \($0.item.text)" }
        return ([header] + lines).joined(separator: "\n")
    }

    /// The volatile line: facts added or changed by this chat after its snapshot (nil when none).
    public func volatileLine(chatID: String, since: Date) throws -> String? {
        let items = try store.database.read { db in
            try MemoryItem.filter(Column("source_chat_id") == chatID && Column("state") == MemoryItemState.active.rawValue)
                .filter(Column("updated_at") >= since.timeIntervalSince1970)
                .order(Column("updated_at"), Column("id")).fetchAll(db)
        }
        guard !items.isEmpty else { return nil }
        var line = "Memory written in this chat: " + items.map { "\($0.key): \($0.text)" }.joined(separator: "; ")
        if line.count > Self.maxVolatileChars { line = String(line.prefix(Self.maxVolatileChars - 1)) + "…" }
        return line
    }
}
