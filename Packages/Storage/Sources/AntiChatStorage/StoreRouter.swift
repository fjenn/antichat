// StoreRouter (M1.T20 step 3, P-shell-14, architecture §5.4): which database a chat's records live in. Every chat is
// on disk (the app's `DatabasePool`) unless it was routed to an in-memory store: an incognito chat's rows, parts,
// attachments, provenance, tool permissions and compaction summaries all go to its own `AppDatabase.inMemory()`
// (`DatabaseQueue`, same migrations, `PRAGMA temp_store=MEMORY`), which disappears when the session releases it.
// Callers that hold only a chat id (sidebar unread flag, tool chips, drafts in M1.T21) ask the router, never
// `disk` directly; `persistsDrafts` is the M1.T21 guard (no draft rows for incognito chats).
import Foundation
import Synchronization

public final class StoreRouter: Sendable {
    /// The app database (on disk; in memory only in tests and the open-failure fallback).
    public let disk: AppDatabase
    private let ephemeral = Mutex<[String: AppDatabase]>([:])

    public init(disk: AppDatabase) {
        self.disk = disk
    }

    /// A fresh ephemeral store: in memory, never a file (no path, no WAL, temp tables in memory).
    public static func makeEphemeralStore() throws -> AppDatabase { try AppDatabase.inMemory() }

    /// Routes `chatID` to `store`, which must be in memory (an on-disk store would defeat the routing).
    public func route(_ chatID: String, to store: AppDatabase) throws {
        guard store.isInMemory else { throw StorageError.invalidTree("ephemeral store must be in memory") }
        ephemeral.withLock { $0[chatID] = store }
    }

    /// Forgets every chat routed to `store` (the session closed).
    public func release(store: AppDatabase) {
        ephemeral.withLock { map in map = map.filter { $0.value !== store } }
    }

    public func release(_ chatID: String) {
        _ = ephemeral.withLock { $0.removeValue(forKey: chatID) }
    }

    /// The chat lives in an in-memory store.
    public func isEphemeral(_ chatID: String) -> Bool { ephemeral.withLock { $0[chatID] != nil } }

    /// Chats currently routed to memory (tests, probes).
    public var ephemeralChatIDs: Set<String> { ephemeral.withLock { Set($0.keys) } }

    /// The database holding `chatID`'s records (`disk` for nil, a new chat, or any chat not routed to memory).
    public func database(for chatID: String?) -> AppDatabase {
        guard let chatID else { return disk }
        return ephemeral.withLock { $0[chatID] } ?? disk
    }

    /// M1.T21: a draft may be written for this chat (never for an incognito one).
    public func persistsDrafts(for chatID: String?) -> Bool {
        guard let chatID else { return true }
        return !isEphemeral(chatID)
    }
}
