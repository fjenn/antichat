// M6.T07 (R-272 AC1, P-files-tools-03): one in-memory DuckDB per chat for the spreadsheet SQL tool (`query_data`,
// M6.T08). Locked down at open: no external access (no local file reads/writes beyond what we append, no network,
// no ATTACH), no extension install/autoload, memory and thread caps per tier, then `lock_configuration` (set last) so
// no SQL can undo any of it. Rows arrive only through `SheetLoader` (Appender); nothing is ever written to disk.
import DuckDB
import Foundation

public enum DuckDBStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case open(String)
    case query(String)
    public var description: String {
        switch self {
        case .open(let m): "DuckDB open failed: \(m)"
        case .query(let m): m
        }
    }
}

public final class DuckDBStore: @unchecked Sendable {
    public struct Config: Sendable, Equatable {
        /// `memory_limit` in MB (tier-budgets.json `files.duckdb_memory_mb`, per tier).
        public var memoryMB: Int
        /// `threads` = min(4, performance cores / 2), at least 1.
        public var threads: Int
        public init(memoryMB: Int = 512, threads: Int = DuckDBStore.defaultThreads) {
            self.memoryMB = memoryMB; self.threads = threads
        }
    }

    public static var defaultThreads: Int {
        var perf: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &perf, &size, nil, 0) != 0 || perf <= 0 {
            perf = Int32(ProcessInfo.processInfo.activeProcessorCount)
        }
        return max(1, min(4, Int(perf) / 2))
    }

    /// The settings applied at open, in order (`lock_configuration` last). Exposed for the tests.
    public static func settings(_ c: Config) -> [(String, String)] {
        [("enable_external_access", "false"), ("autoinstall_known_extensions", "false"),
         ("autoload_known_extensions", "false"), ("allow_community_extensions", "false"),
         ("memory_limit", "\(c.memoryMB)MB"), ("threads", "\(c.threads)"),
         ("lock_configuration", "true")]  // no disk spill either: the temp directory is a file access, denied
    }

    public let chatID: String
    public let config: Config
    let database: Database
    let connection: Connection
    private let lock = NSLock()
    private var tableNames: Set<String> = []

    public init(chatID: String, config: Config = Config()) throws {
        self.chatID = chatID
        self.config = config
        let conf = Database.Configuration()
        do {
            for (k, v) in Self.settings(config) { try conf.setValue(v, forKey: k) }
            database = try Database(store: .inMemory, configuration: conf)
            connection = try database.connect()
        } catch {
            throw DuckDBStoreError.open(String(describing: error))
        }
    }

    // MARK: per-chat registry

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: DuckDBStore] = [:]

    /// The chat's store, created on first use (R-272: per-chat, in memory).
    public static func open(chatID: String, config: Config = Config()) throws -> DuckDBStore {
        registryLock.lock(); defer { registryLock.unlock() }
        if let s = registry[chatID] { return s }
        let s = try DuckDBStore(chatID: chatID, config: config)
        registry[chatID] = s
        return s
    }

    /// The chat has a store in the registry (tests; diagnostics).
    public static func isOpen(chatID: String) -> Bool {
        registryLock.lock(); defer { registryLock.unlock() }
        return registry[chatID] != nil
    }

    /// Drop the chat's tables (chat closed / deleted).
    public static func close(chatID: String) {
        registryLock.lock(); defer { registryLock.unlock() }
        registry[chatID] = nil
    }

    // MARK: SQL

    /// Run one statement under the store lock. Errors carry DuckDB's message.
    @discardableResult
    public func query(_ sql: String) throws -> ResultSet {
        lock.lock(); defer { lock.unlock() }
        return try Self.run(connection, sql)
    }

    static func run(_ c: Connection, _ sql: String) throws -> ResultSet {
        do { return try c.query(sql) } catch let e as DatabaseError {
            if case .connectionQueryError(let reason) = e { throw DuckDBStoreError.query(reason ?? "query failed") }
            throw DuckDBStoreError.query(String(describing: e))
        }
    }

    /// Every value as text (NULL → nil), column names in order. Wraps the statement in `COLUMNS(*)::VARCHAR`.
    public func stringRows(_ sql: String) throws -> (columns: [String], rows: [[String?]]) {
        let rs = try query("SELECT COLUMNS(*)::VARCHAR FROM (\(sql))")
        let cols = (0..<rs.columnCount).map { rs.columnName(at: $0) }
        let typed = (0..<rs.columnCount).map { rs[$0].cast(to: String.self) }
        var rows: [[String?]] = []
        rows.reserveCapacity(Int(rs.rowCount))
        for r in 0..<rs.rowCount { rows.append(typed.map { $0[r] }) }
        return (cols, rows)
    }

    /// Bulk load under the store lock (SheetLoader).
    func withConnection<T>(_ body: (Connection) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(connection)
    }

    // MARK: the query connection (M6.T08)

    private let queryLock = NSLock()
    private var queryConn: Connection?

    /// A second connection, used only by `query_data`, so a timeout interrupts the model's query and never a load.
    func queryConnection() throws -> Connection {
        queryLock.lock(); defer { queryLock.unlock() }
        if let c = queryConn { return c }
        do { let c = try database.connect(); queryConn = c; return c } catch { throw DuckDBStoreError.open(String(describing: error)) }
    }

    private let queryRunLock = NSLock()
    /// Serialises the query connection's statements.
    func withQueryConnection<T>(_ body: (Connection) throws -> T) throws -> T {
        let c = try queryConnection()
        queryRunLock.lock(); defer { queryRunLock.unlock() }
        return try body(c)
    }

    /// The loaded tables (for the tool's availability).
    public var hasTables: Bool { lock.lock(); defer { lock.unlock() }; return !tableNames.isEmpty }

    /// A free table name: `[A-Za-z0-9_]` only, never empty, not starting with a digit, unique in this store.
    func claimTableName(_ raw: String) -> String {
        lock.lock(); defer { lock.unlock() }
        var base = String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "_" })
        while base.contains("__") { base = base.replacingOccurrences(of: "__", with: "_") }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if base.isEmpty { base = "sheet" }
        if base.first!.isNumber { base = "t_" + base }
        var name = base, n = 2
        while tableNames.contains(name.lowercased()) { name = "\(base)_\(n)"; n += 1 }
        tableNames.insert(name.lowercased())
        return name
    }

    public static func quote(_ ident: String) -> String { "\"" + ident.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}
