// Chat management for the window and sidebar (M1.T07, R-001/R-011, G-001). The UI never imports AntiChatStorage
// (architecture §3: UI → Harness only), so this service wraps `ChatRepository`/`MessageTree` and hands the UI plain
// value types. Every mutation writes through `ChatRepository`; the sidebar sees it through a GRDB
// `ValueObservation` (architecture §6), never through a local copy.
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation
import GRDB

/// One sidebar / Chats-page row.
public struct ChatSummary: Identifiable, Hashable, Sendable {
    public var id: String
    /// Empty while the auto title is pending (the row shows `side.untitled`).
    public var title: String
    public var titlePending: Bool
    public var isEvil: Bool
    public var pinned: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// M1.T19: a reply finished while the chat was not on screen (sidebar dot + bold); cleared on open.
    public var unread: Bool
    /// M8.T04: the chat's project (nil = Recents); project chats show under their project, not in the sidebar's Recents.
    public var projectID: String?
    /// M8.T06 step 10: imported from ChatGPT / Claude / an AntiChat export (`chat.source`): the "Imported" chip.
    public var imported: Bool

    public init(id: String, title: String, titlePending: Bool = false, isEvil: Bool = false, pinned: Bool = false,
                createdAt: Date = Date(), updatedAt: Date? = nil, unread: Bool = false, projectID: String? = nil,
                imported: Bool = false) {
        self.imported = imported
        self.unread = unread
        self.projectID = projectID
        self.id = id
        self.title = title
        self.titlePending = titlePending
        self.isEvil = isEvil
        self.pinned = pinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    init(_ r: ChatRecord) {
        self.init(id: r.id, title: r.title, titlePending: r.titleState == .pending, isEvil: r.mode == .evil,
                  pinned: r.pinned, createdAt: r.createdAt, updatedAt: r.updatedAt, unread: r.unread,
                  projectID: r.projectID, imported: r.source != .local)
    }
}

/// One visible-path message, flattened to its text parts (the transcript placeholder until M1.T06/T09 render parts).
public struct TranscriptItem: Identifiable, Hashable, Sendable {
    public enum Role: String, Sendable { case user, assistant, other }
    public var id: String
    public var role: Role
    public var text: String
    public var createdAt: Date

    public init(id: String, role: Role, text: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

public enum ChatExportFormat: String, CaseIterable, Sendable {
    case markdown, json
    public var fileExtension: String { self == .markdown ? "md" : "json" }
}

/// Cancels a database observation when cancelled or released.
public final class ObservationToken: @unchecked Sendable {
    private var cancellable: AnyDatabaseCancellable?
    init(_ c: AnyDatabaseCancellable) { cancellable = c }
    public func cancel() { cancellable?.cancel(); cancellable = nil }
    deinit { cancellable?.cancel() }
}

public final class ChatListService: Sendable {
    /// Rows observed by the sidebar per page (M1.T07 failure mode: observe the first 200 rows + paging).
    public static let sidebarPageSize = 200

    public let database: AppDatabase
    private var chats: ChatRepository { ChatRepository(database) }
    private var tree: MessageTree { MessageTree(database) }

    init(database: AppDatabase) { self.database = database }

    /// The app database at its default location (`-ANTICHAT_DEV_CONTAINER` in DEBUG).
    public static func openDefault() throws -> ChatListService {
        let db = try AppDatabase.openDefault()
        _ = try? MessageRepository(db).markInterruptedAfterCrash()
        return ChatListService(database: db)
    }

    /// The chat environment's database (W2 wiring: one database for the sidebar and the turn path,
    /// architecture §6; the environment already ran the launch sweep).
    public convenience init(environment: ChatEnvironment) { self.init(database: environment.database) }

    /// An in-memory database (tests, previews, and the fallback when the file cannot be opened).
    public static func inMemory() throws -> ChatListService { ChatListService(database: try AppDatabase.inMemory()) }

    // MARK: Observation

    /// Sidebar rows (archived excluded; pinned first, then most recently updated), at most `limit`.
    @MainActor
    public func observeSidebar(limit: Int = sidebarPageSize, onError: @escaping @MainActor (Error) -> Void = { _ in },
                               onChange: @escaping @MainActor ([ChatSummary]) -> Void) -> ObservationToken {
        // Explicit, constant region (AT-NFR-S3): on a DatabasePool the refetch after a commit runs on a reader
        // instead of inside the writer, so it never lengthens the writer's hold that the main thread may wait for.
        let observation = ValueObservation.tracking(regions: [ChatRepository.sidebarRequest()]) { db in
            try ChatRepository.sidebarRequest().limit(limit).fetchAll(db).map(ChatSummary.init)
        }.removeDuplicates()
        return ObservationToken(observation.start(in: database.reader, scheduling: .mainActor, onError: onError,
                                                  onChange: onChange))
    }

    /// Total number of non-archived chats (sidebar paging).
    public func sidebarCount() throws -> Int {
        try database.read { db in try ChatRepository.sidebarRequest().fetchCount(db) }
    }

    /// The visible path of `chatID` as transcript items.
    @MainActor
    public func observeTranscript(_ chatID: String, onError: @escaping @MainActor (Error) -> Void = { _ in },
                                  onChange: @escaping @MainActor ([TranscriptItem]) -> Void) -> ObservationToken {
        // The tables `transcript` reads, whole (a constant region, see `observeSidebar`): every streaming save
        // commits here, and the refetch no longer runs inside the writer.
        let observation = ValueObservation.tracking(regions: Self.transcriptRegions) { db in
            try Self.transcript(chatID, db: db)
        }.removeDuplicates()
        return ObservationToken(observation.start(in: database.reader, scheduling: .mainActor, onError: onError,
                                                  onChange: onChange))
    }

    /// Everything `transcript(_:db:)` reads: the chat's leaf, the message tree, the parts.
    static let transcriptRegions: [any DatabaseRegionConvertible] = [Table("chat"), Table("message"), Table("message_part")]

    public func transcript(_ chatID: String) throws -> [TranscriptItem] {
        try database.read { db in try Self.transcript(chatID, db: db) }
    }

    static func transcript(_ chatID: String, db: Database) throws -> [TranscriptItem] {
        try MessageTree.visiblePath(chatID, db: db).map { m in
            let text = try MessageRepository.parts(of: m.id, db: db).filter { $0.kind == .text }.map(\.body)
                .joined(separator: "\n\n")
            let role: TranscriptItem.Role = m.role == .user ? .user : (m.role == .assistant ? .assistant : .other)
            return TranscriptItem(id: m.id, role: role, text: text, createdAt: m.createdAt)
        }
    }

    // MARK: Reads

    public func chat(_ id: String) throws -> ChatSummary? { try chats.chat(id).map(ChatSummary.init) }

    // MARK: Mutations (each one write through ChatRepository; observers update the UI)

    /// Creates the chat row (on the first send of a new chat; an empty new chat has no row, like ChatGPT).
    @discardableResult
    public func create(title: String = "", evil: Bool = false) throws -> ChatSummary {
        ChatSummary(try chats.create(title: title, mode: evil ? .evil : .normal))
    }

    /// M1.T19 step 1: the chat row of a first send, titled with the prompt's first 60 characters
    /// (`TitleService.temporaryTitle`, `title_state = pending`) until the auto title replaces it.
    @discardableResult
    public func create(firstPrompt: String, evil: Bool = false) throws -> ChatSummary {
        ChatSummary(try chats.create(temporaryTitle: TitleService.temporaryTitle(firstPrompt), mode: evil ? .evil : .normal))
    }

    /// M1.T19 step 2: stores an auto title unless the user renamed the chat. Returns false when nothing changed.
    @discardableResult
    public func applyAutoTitle(_ id: String, title: String) throws -> Bool { try chats.applyAutoTitle(id, title: title) }

    /// M1.T19 step 4: the unread dot (set when a reply finishes off screen, cleared on open).
    @discardableResult
    public func setUnread(_ id: String, _ unread: Bool) throws -> Bool { try chats.setUnread(id, unread) }

    /// `setUnread` enqueued on the writer (main-thread callers never wait for it; AT-NFR-S3). An unchanged flag is
    /// no change: the statement's `unread != ?` makes it a no-op commit that no observation refetches for.
    public func setUnreadLater(_ id: String, _ unread: Bool) { chats.setUnreadLater(id, unread) }

    /// `applyAutoTitle` enqueued on the writer (the title job lands on the main thread mid-reply; AT-NFR-S3).
    public func applyAutoTitleLater(_ id: String, title: String, applied: (@Sendable (Bool) -> Void)? = nil) {
        chats.applyAutoTitleLater(id, title: title, applied: applied)
    }

    /// The chat has no message (a held send was cancelled before anything was written): removes the row, so an
    /// empty session never stays in the sidebar (M1.T19 step 3). Returns true when a row was removed.
    @discardableResult
    public func deleteIfEmpty(_ id: String) throws -> Bool {
        try database.write { db in
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE chat_id = ?", arguments: [id]) ?? 0
            guard n == 0 else { return false }
            return try ChatRecord.deleteOne(db, key: id)
        }
    }

    public func rename(_ id: String, to title: String) throws {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        try chats.rename(id, title: t)
    }

    public func setPinned(_ id: String, _ pinned: Bool) throws { try chats.setPinned(id, pinned) }

    public func archive(_ ids: [String]) throws {
        try database.write { db in
            let now = Date().timeIntervalSince1970
            for id in ids {
                try db.execute(sql: "UPDATE chat SET archived_at = ? WHERE id = ?",
                               arguments: [now, id])
            }
        }
    }

    public func unarchive(_ id: String) throws { try chats.setArchived(id, false) }

    public func delete(_ ids: [String]) throws {
        try database.write { db in
            for id in ids { _ = try ChatRecord.deleteOne(db, key: id) }
        }
        SheetSessions.shared.close(chatIDs: ids)  // M6 review #5: its DuckDB and query results go too
        FileToolsClient.release(chatIDs: ids)  // M6.T21 review #6: interpreter + jail
    }

    /// Appends a user message to the active path (stand-in for M1.T06's TurnController until the W2 merge).
    @discardableResult
    public func appendUserMessage(_ chatID: String, text: String) throws -> TranscriptItem {
        try database.write { db in
            let leaf = try ChatRecord.fetchOne(db, key: chatID)?.leafMessageID
            let m = try MessageTree.append(chatID: chatID, parentID: leaf, role: .user, status: .done,
                                           parts: [.text(text)], configure: { _ in }, db: db)
            try db.execute(sql: "UPDATE chat SET updated_at = ? WHERE id = ?",
                           arguments: [Date().timeIntervalSince1970, chatID])
            return TranscriptItem(id: m.id, role: .user, text: text, createdAt: m.createdAt)
        }
    }

    /// Appends a finished assistant message (fixtures, previews and the UI probe; M1.T06 owns real turns).
    @discardableResult
    public func appendAssistantMessage(_ chatID: String, text: String) throws -> TranscriptItem {
        try database.write { db in
            let leaf = try ChatRecord.fetchOne(db, key: chatID)?.leafMessageID
            let m = try MessageTree.append(chatID: chatID, parentID: leaf, role: .assistant, status: .done,
                                           parts: [.text(text)], configure: { _ in }, db: db)
            return TranscriptItem(id: m.id, role: .assistant, text: text, createdAt: m.createdAt)
        }
    }

    // MARK: Export (row menu › Export; the full export lands in M8)

    /// The chat as Markdown (visible path) or as the tree-preserving JSON of `TreeExport` (R-296).
    public func export(_ id: String, as format: ChatExportFormat) throws -> Data {
        switch format {
        case .json:
            return try TreeExport.exportJSON(id, from: database)
        case .markdown:
            return try database.read { db in
                guard let chat = try ChatRecord.fetchOne(db, key: id) else { throw StorageError.notFound("chat \(id)") }
                return Data(Self.markdown(title: chat.title, items: try Self.transcript(id, db: db)).utf8)
            }
        }
    }

    /// Markdown body: `# title`, then one `## role` section per visible message.
    public static func markdown(title: String, items: [TranscriptItem]) -> String {
        var out = "# \(title.isEmpty ? "Chat" : title)\n"
        for item in items {
            let heading = switch item.role {
            case .user: "User"
            case .assistant: "Assistant"
            case .other: "Note"
            }
            out += "\n## \(heading)\n\n\(item.text)\n"
        }
        return out
    }

    /// A file name for an exported chat: the title with path characters removed.
    public static func exportFileName(title: String, format: ChatExportFormat) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines).union(.controlCharacters)
        let base = title.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return "\(base.isEmpty ? "Chat" : String(base.prefix(80))).\(format.fileExtension)"
    }
}
