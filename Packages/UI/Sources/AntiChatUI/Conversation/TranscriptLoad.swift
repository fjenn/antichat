// M9.T05 (NFR-U11 "opening a 500-turn chat ≤ 500 ms p95"): the reads behind `ConversationModel.load`, batched.
// The load read each message of the visible path with five queries of its own (parts, its siblings for ‹n/m›, its
// rating, its attachments and their blobs): ~5,000 statements on the main thread for the 1,000-message chat. The same
// rows are now read with one query per table for the whole path (chunked `IN` lists), then grouped in memory; the
// order rules are the per-message queries' (parts by `idx`, siblings by `position, id`, attachments by `created_at`).
import AntiChatHarness
import AntiChatStorage
import Foundation
import GRDB

struct TranscriptLoad {
    let path: [MessageRecord]
    private let parts: [String: [MessagePartRecord]]
    private let versions: [String: (index: Int, total: Int)]
    private let ratings: [String: FeedbackRepository.Rating]
    private let attachments: [String: [(AttachmentRecord, FileBlobRecord?)]]

    /// The visible path of `chatID` and everything its rows show. `roles`: the messages whose details are read (the
    /// transcript shows user and assistant messages only).
    init(chatID: String, db: Database, roles: Set<MessageRole> = [.user, .assistant]) throws {
        path = try MessageTree.visiblePath(chatID, db: db)
        let shown = path.filter { roles.contains($0.role) }
        let ids = shown.map(\.id)
        let userIDs = shown.filter { $0.role == .user }.map(\.id)

        var parts: [String: [MessagePartRecord]] = [:]
        for chunk in Self.chunks(ids) {
            let rows = try MessagePartRecord.filter(chunk.contains(MessagePartRecord.Columns.messageID))
                .order(MessagePartRecord.Columns.messageID, MessagePartRecord.Columns.idx).fetchAll(db)
            for r in rows { parts[r.messageID, default: []].append(r) }
        }
        self.parts = parts

        // ‹index/total› among the siblings (children of the same parent in this chat, by position then id).
        let siblingRows = try Row.fetchAll(db, sql: """
            SELECT id, parent_id FROM message WHERE chat_id = ? ORDER BY position, id
            """, arguments: [chatID])
        var children: [String?: [String]] = [:]
        for r in siblingRows { children[r["parent_id"] as String?, default: []].append(r["id"]) }
        var versions: [String: (index: Int, total: Int)] = [:]
        for m in shown {
            let siblings = children[m.parentID] ?? []
            guard let i = siblings.firstIndex(of: m.id) else { throw StorageError.notFound("message \(m.id)") }
            versions[m.id] = (i + 1, siblings.count)
        }
        self.versions = versions

        var ratings: [String: FeedbackRepository.Rating] = [:]
        for chunk in Self.chunks(ids) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT message_id, kind FROM feedback WHERE message_id IN (\(marks)) AND kind IN ('liked', 'disliked')
                """, arguments: StatementArguments(chunk))
            for r in rows {
                let id: String = r["message_id"]
                if ratings[id] == nil, let rating = (r["kind"] as String?).flatMap(FeedbackRepository.Rating.init(rawValue:)) { ratings[id] = rating }
            }
        }
        self.ratings = ratings

        var attachments: [String: [(AttachmentRecord, FileBlobRecord?)]] = [:]
        for chunk in Self.chunks(userIDs) {
            let rows = try AttachmentRecord.filter(chunk.contains(Column("message_id"))).order(Column("created_at")).fetchAll(db)
            guard !rows.isEmpty else { continue }
            let blobs = try FileBlobRecord.fetchAll(db, keys: Set(rows.map(\.blobID)))
            let byID = Dictionary(blobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for a in rows { if let mid = a.messageID { attachments[mid, default: []].append((a, byID[a.blobID])) } }
        }
        self.attachments = attachments
    }

    func parts(of id: String) -> [MessagePartRecord] { parts[id] ?? [] }
    func versionInfo(_ id: String) -> (index: Int, total: Int) { versions[id] ?? (1, 1) }
    func rating(_ id: String) -> FeedbackRepository.Rating? { ratings[id] }
    func attachments(of id: String) -> [(AttachmentRecord, FileBlobRecord?)] { attachments[id] ?? [] }

    /// `IN` lists stay well under SQLite's bound-variable limit.
    private static func chunks(_ ids: [String], size: Int = 500) -> [[String]] {
        stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
    }
}
