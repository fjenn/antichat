// Archived chats and bulk chat operations (M1.T22 step 5; R-011 AC4; settings-map §9): the Archived chats page
// (observe, search, unarchive, delete), Archive all, Delete all, and the auto-archive sweep
// (`AutoArchiveService`). Every mutation is one write; the sidebar and the page observe the database.
import AntiChatStorage
import AntiChatTools
import Foundation
import GRDB

/// One row of Settings → Privacy & Data → Archived chats.
public struct ArchivedChat: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var archivedAt: Date
    public var updatedAt: Date

    init?(_ r: ChatRecord) {
        guard let at = r.archivedAt else { return nil }
        self.init(id: r.id, title: r.title, archivedAt: at, updatedAt: r.updatedAt)
    }

    public init(id: String, title: String, archivedAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.archivedAt = archivedAt
        self.updatedAt = updatedAt
    }

    /// Case- and diacritic-insensitive title filter (the page's search field); empty query keeps every row.
    public static func filter(_ rows: [ArchivedChat], query: String, untitled: String) -> [ArchivedChat] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return rows }
        return rows.filter { ($0.title.isEmpty ? untitled : $0.title).range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

extension ChatListService {
    static func archivedRequest() -> QueryInterfaceRequest<ChatRecord> {
        ChatRecord.filter(ChatRecord.Columns.archivedAt != nil)
            .order(ChatRecord.Columns.archivedAt.desc, ChatRecord.Columns.id.desc)
    }

    /// Archived chats, most recently archived first.
    @MainActor
    public func observeArchived(onError: @escaping @MainActor (Error) -> Void = { _ in },
                                onChange: @escaping @MainActor ([ArchivedChat]) -> Void) -> ObservationToken {
        let observation = ValueObservation.tracking(regions: [Self.archivedRequest()]) { db in  // constant region
            try Self.archivedRequest().fetchAll(db).compactMap(ArchivedChat.init)
        }.removeDuplicates()
        return ObservationToken(observation.start(in: database.reader, scheduling: .mainActor, onError: onError,
                                                  onChange: onChange))
    }

    public func archived() throws -> [ArchivedChat] {
        try database.read { db in try Self.archivedRequest().fetchAll(db).compactMap(ArchivedChat.init) }
    }

    /// Number of chats, archived ones included.
    public func totalCount() throws -> Int { try database.read { db in try ChatRecord.fetchCount(db) } }

    /// "Archive all chats": archives every chat that is not archived yet; returns how many.
    @discardableResult
    public func archiveAll(now: Date = Date()) throws -> Int {
        try database.write { db in
            try db.execute(sql: "UPDATE chat SET archived_at = ? WHERE archived_at IS NULL",
                           arguments: [now.timeIntervalSince1970])
            return db.changesCount
        }
    }

    /// "Delete all chats" (typed confirmation in the UI): deletes every chat, archived ones too; returns how many.
    @discardableResult
    public func deleteAll() throws -> Int {
        let ids = try database.write { db -> [String] in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM chat")
            try ChatRecord.deleteAll(db)
            return ids
        }
        SheetSessions.shared.close(chatIDs: ids)  // M6 review #5: this database's chats only
        FileToolsClient.release(chatIDs: ids)  // M6.T21 review #6: interpreter + jail
        return ids.count
    }

    /// The auto-archive sweep: archives every non-archived chat whose last activity (`updated_at`) is at least
    /// `days` days before `now`. Returns the archived ids.
    @discardableResult
    public func archiveInactive(days: Int, now: Date) throws -> [String] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        return try database.write { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM chat WHERE archived_at IS NULL AND updated_at <= ?",
                                          arguments: [cutoff])
            guard !ids.isEmpty else { return [] }
            try db.execute(sql: "UPDATE chat SET archived_at = ? WHERE archived_at IS NULL AND updated_at <= ?",
                           arguments: [now.timeIntervalSince1970, cutoff])
            return ids
        }
    }
}
