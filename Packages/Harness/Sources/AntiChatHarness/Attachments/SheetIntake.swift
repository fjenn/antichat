// M6.T07 (R-272 AC1): an attached spreadsheet → typed tables in the chat's DuckDB + the profile block for the prompt.
// Routes by the sniffed kind: XLSX and CSV/TSV through `SheetLoader` (AntiChatTools), legacy XLS through
// `XLSAdapter` (AntiChatKnowledge, libxls) first — the Harness is the layer that may import both (architecture §3).
// Memory cap and block size come from tier-budgets.json (`files.duckdb_memory_mb`, `files.sheet_profile_tokens`).
// M6.T08 calls it when a sheet is attached and offers `query_data` only once a table is loaded.
import AntiChatFoundation
import AntiChatKnowledge
import AntiChatStorage
import AntiChatTools
import Foundation
import GRDB

public enum SheetIntake {
    public struct Loaded: Sendable {
        public var tables: [LoadedTable]
        /// `<sheet_tables untrusted="true">…` — schema, row counts, first/last rows, stats; never the full table.
        public var profile: String
    }

    public static func store(chatID: String, tier: String, budgets: TierBudgets = .shared) throws -> DuckDBStore {
        try DuckDBStore.open(chatID: chatID, config: .init(memoryMB: budgets.duckDBMemoryMB(tier: tier)))
    }

    /// Load one file (kind from `TypeSniffer`) into `store`. Non-sheet kinds throw `SheetLoaderError.empty`.
    public static func load(url: URL, displayName: String? = nil, kind: AttachmentKind, into store: DuckDBStore, tier: String,
                            budgets: TierBudgets = .shared) async throws -> Loaded {
        let tables: [LoadedTable]
        let name = displayName ?? url.lastPathComponent
        switch kind {
        case .xlsx: tables = try await SheetLoader.load(xlsx: url, file: name, into: store)
        case .xls: tables = try SheetLoader.load(workbook: XLSAdapter.workbook(url: url), file: name, into: store)
        case .csv: tables = try await SheetLoader.load(csv: url, delimiter: .comma, file: name, into: store)
        case .tsv: tables = try await SheetLoader.load(csv: url, delimiter: .tab, file: name, into: store)
        default: throw SheetLoaderError.empty
        }
        let profile = try SheetProfile.block(tables, store: store, tokenCap: budgets.sheetProfileTokens(tier: tier))
        return Loaded(tables: tables, profile: profile)
    }
}

/// M6.T08: which sheets each chat has loaded (load-when-needed: a turn whose path has a ready sheet attachment loads it
/// into the chat's DuckDB once; `query_data` is offered only after that). The prompt shows the sheet's profile block in
/// place of its Markdown table (`DocumentContextAssembler`). In memory only: a relaunch reloads on the next turn.
///
/// M6 review #5: each chat's DuckDB (up to `files.duckdb_memory_mb`) and query results are released when the chat is
/// deleted or its incognito session ends (`close`), and at most `maxOpenChats` chats keep theirs loaded: opening
/// another closes the least recently used one (it reloads on its next turn).
public final class SheetSessions: @unchecked Sendable {
    public static let shared = SheetSessions()
    public static let maxOpenChats = 4
    private let lock = NSLock()
    private var loaded: [String: [String: SheetIntake.Loaded]] = [:]  // chat → attachment → tables + profile
    private var stores: [String: DuckDBStore] = [:]  // the loaded store a tool retains even if the LRU later evicts it
    private var recency: [String] = []  // chats with a store, least recently used first

    public init() {}

    public func hasTables(chatID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loaded[chatID]?.values.contains { !$0.tables.isEmpty } ?? false
    }

    public func profile(attachmentID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        for (_, m) in loaded { if let l = m[attachmentID] { return l.profile } }
        return nil
    }

    public func tables(chatID: String) -> [LoadedTable] {
        lock.lock(); defer { lock.unlock() }
        return loaded[chatID]?.values.flatMap(\.tables) ?? []
    }

    /// The loaded store and table metadata, retained by a query even if the LRU evicts them before it starts (#5).
    public func store(chatID: String) -> (store: DuckDBStore, tables: [LoadedTable])? {
        lock.lock(); defer { lock.unlock() }
        guard let store = stores[chatID] else { return nil }
        return (store, loaded[chatID]?.values.flatMap(\.tables) ?? [])
    }

    func record(chatID: String, attachmentID: String, _ l: SheetIntake.Loaded, store: DuckDBStore? = nil) {
        lock.lock(); defer { lock.unlock() }
        loaded[chatID, default: [:]][attachmentID] = l
        if let store { stores[chatID] = store }
    }

    func isLoaded(chatID: String, attachmentID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loaded[chatID]?[attachmentID] != nil
    }

    public func close(chatID: String) {
        lock.lock(); loaded[chatID] = nil; stores[chatID] = nil; recency.removeAll { $0 == chatID }; lock.unlock()
        DuckDBStore.close(chatID: chatID)
        DataRefStore.shared.drop(chatID: chatID)
    }

    public func close(chatIDs: some Sequence<String>) { for id in chatIDs { close(chatID: id) } }

    /// Every chat's store and results ("Delete all chats").
    public func closeAll() {
        lock.lock(); let ids = Set(loaded.keys).union(recency); lock.unlock()
        close(chatIDs: ids)
    }

    /// Marks `chatID` as the most recently used and closes the chats beyond `maxOpenChats`; returns the closed ids.
    @discardableResult
    func admit(chatID: String) -> [String] {
        lock.lock()
        recency.removeAll { $0 == chatID }
        recency.append(chatID)
        let evicted = Array(recency.dropLast(Self.maxOpenChats))
        lock.unlock()
        close(chatIDs: evicted)
        return evicted
    }

    /// Loads every ready sheet attachment of the chat (plus `extraIDs`, the send's new attachments not yet linked to a
    /// message) that is not loaded yet. Failures are logged and leave the sheet as a plain document.
    public func ensureLoaded(chatID: String, extraIDs: [String] = [], database: AppDatabase, tier: String) async {
        let rows: [(String, String, String)] = (try? database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.id, a.display_name, b.path FROM attachment a JOIN file_blob b ON b.id = a.blob_id
                LEFT JOIN message m ON m.id = a.message_id
                WHERE a.extract_state = ? AND (m.chat_id = ? OR a.id IN (SELECT value FROM json_each(?)))
                ORDER BY a.created_at
                """, arguments: [ExtractState.ready.rawValue, chatID, String(decoding: try JSONEncoder().encode(extraIDs), as: UTF8.self)])
                .map { ($0["id"], $0["display_name"], $0["path"]) }
        }) ?? []
        guard !rows.isEmpty else { return }
        admit(chatID: chatID)
        for (id, name, path) in rows where !isLoaded(chatID: chatID, attachmentID: id) {
            let url = URL(fileURLWithPath: path)
            guard let kind = try? TypeSniffer.sniff(url).kind, kind.isSheet else { continue }
            do {
                let store = try SheetIntake.store(chatID: chatID, tier: tier)
                let l = try await SheetIntake.load(url: url, displayName: name, kind: kind, into: store, tier: tier)
                record(chatID: chatID, attachmentID: id, l, store: store)
            } catch {
                AppLog.log(.harness, .error, "sheet load failed (\(kind.rawValue)): \(error)")
            }
        }
    }
}
