// M6.T08 (R-272 AC2/AC3, P-files-tools-03): the `query_data` tool. One read-only statement (SELECT / WITH /
// SUMMARIZE / DESCRIBE / PIVOT, all planned as SELECT) over the chat's DuckDB tables; anything else is a tool error the
// model sees (one retry under the M1 tool-loop rules). Runs on the store's dedicated query connection with a 10 s
// timeout (`duckdb_interrupt`, QueryTimeout.swift); the model sees ≤ 200 rows (`truncated` beyond), every row up to
// 100,000 is kept in `DataRefStore` as `qr_<uuid>` (the result carries `data_ref`). Local, read-only, offline.
import DuckDB
import Foundation

public struct QueryResult: Sendable, Equatable {
    public var sql: String
    public var columns: [String]
    public var types: [String]
    /// The rows the model sees (≤ `QueryDataTool.shownRows`).
    public var rows: [[String?]]
    public var rowCount: Int
    public var truncated: Bool
    public var elapsedMS: Int
    public var dataRef: String
}

public enum QueryDataError: Error, Equatable, Sendable, CustomStringConvertible {
    case notReadOnly(String)
    case oneStatement(Int)
    case invalid(String)
    case timeout(seconds: Double)
    case failed(String)
    case noTables

    public var description: String {
        switch self {
        case .notReadOnly(let k): "query_data runs read-only queries only (SELECT, WITH, SUMMARIZE, DESCRIBE, PIVOT); got a \(k) statement."
        case .oneStatement(let n): "query_data runs exactly one statement; got \(n)."
        case .invalid(let m): "SQL error: \(m)"
        case .timeout(let s): "The query took longer than \(Int(s)) s and was stopped. Simplify it (filter, aggregate, LIMIT)."
        case .failed(let m): "SQL error: \(m)"
        case .noTables: "No spreadsheet is loaded in this chat."
        }
    }
}

public enum QueryDataTool {
    public static let name = "query_data"
    public static let shownRows = 200
    public static let timeout: Duration = .seconds(10)

    public static let description = """
        Run one read-only SQL query (DuckDB dialect) over the spreadsheets attached to this chat. Each sheet is a \
        table; the table names, columns and types are in the <sheet_tables> block. Use SELECT / WITH / SUMMARIZE / \
        DESCRIBE / PIVOT only; quote names with double quotes. Per month: select strftime("date", '%Y-%m') AS month and \
        GROUP BY that same expression (grouping by the raw date gives one row per day). Returns up to 200 rows plus a \
        data_ref for charts and exports.
        """

    public static let parametersJSON = #"""
        {"type":"object","properties":{"sql":{"type":"string","description":"One read-only DuckDB SQL statement (SELECT, WITH, SUMMARIZE, DESCRIBE or PIVOT)."},"purpose":{"type":"string","description":"Optional: what the query answers, in a few words."}},"required":["sql"],"additionalProperties":false}
        """#

    public struct Arguments: Decodable, Sendable {
        public var sql: String
        public var purpose: String?
    }

    /// Statement guard (step 2): exactly one statement, and it must plan as SELECT.
    public static func check(_ sql: String, store: DuckDBStore) throws {
        switch try store.withQueryConnection({ c in DuckDBC.kind(sql, on: c) }) {
        case .select: return
        case .multiple(let n):
            // DuckDB expands a PIVOT without an IN list into CREATE TYPE + SELECT.
            if sql.range(of: #"^\s*PIVOT\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                throw QueryDataError.invalid("PIVOT needs its values listed: PIVOT t ON col IN ('a', 'b') USING sum(x)")
            }
            throw QueryDataError.oneStatement(n)
        case .parseError(let m): throw QueryDataError.invalid(m)
        case .other(let t): throw QueryDataError.notReadOnly(statementName(t))
        }
    }

    public static func run(sql raw: String, store: DuckDBStore, chatID: String, refs: DataRefStore = .shared,
                           timeout: Duration = timeout) async throws -> QueryResult {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(";") { trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        let sql = trimmed
        try check(sql, store: store)
        let conn = try store.queryConnection()
        let started = ContinuousClock.now
        // Types first (LIMIT 0 plans without scanning), then the rows as text, capped at the DataRef limit + 1.
        let job: @Sendable () throws -> (types: [String], cols: [String], rows: [[String?]]) = {
            try store.withQueryConnection { c in
                let probe = try DuckDBStore.run(c, "SELECT * FROM (\(sql)) LIMIT 0")
                let types = (0..<probe.columnCount).map { typeName(probe[$0].underlyingDatabaseType) }
                let rs = try DuckDBStore.run(c, "SELECT COLUMNS(*)::VARCHAR FROM (\(sql)) LIMIT \(DataRefStore.maxRows + 1)")
                let cols = (0..<rs.columnCount).map { rs.columnName(at: $0) }
                let typed = (0..<rs.columnCount).map { rs[$0].cast(to: String.self) }
                var rows: [[String?]] = []
                rows.reserveCapacity(Int(rs.rowCount))
                for r in 0..<rs.rowCount { rows.append(typed.map { $0[r] }) }
                return (types, cols, rows)
            }
        }
        let out: (types: [String], cols: [String], rows: [[String?]])
        do {
            out = try await withDeadline(timeout, onTimeout: { DuckDBC.interrupt(conn) }, job)
        } catch let e as DuckDBStoreError {
            throw QueryDataError.failed(e.description)
        }
        let elapsed = ContinuousClock.now - started
        let keep = Array(out.rows.prefix(DataRefStore.maxRows))
        let ref = DataRef(id: DataRefStore.newID(), sql: sql, columns: out.cols, types: out.types, rows: keep,
                          truncated: out.rows.count > DataRefStore.maxRows)
        refs.put(chatID: chatID, ref)
        return QueryResult(sql: sql, columns: out.cols, types: out.types, rows: Array(keep.prefix(shownRows)),
                           rowCount: keep.count, truncated: keep.count > shownRows,
                           elapsedMS: Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000),
                           dataRef: ref.id)
    }

    /// Runs `job` on its own thread; past `deadline`, `onTimeout` interrupts it and the call throws `.timeout` once the
    /// job has returned (so the connection is free again).
    static func withDeadline<T: Sendable>(_ deadline: Duration, onTimeout: @escaping @Sendable () -> Void,
                                          _ job: @escaping @Sendable () throws -> T) async throws -> T {
        let state = DeadlineState()
        let timer = Task {
            try? await Task.sleep(for: deadline)
            if !Task.isCancelled, state.markTimedOut() { onTimeout() }
        }
        defer { timer.cancel() }
        let result: Result<T, Error> = await withCheckedContinuation { cont in
            Thread.detachNewThread {
                let r = Result { try job() }
                state.markDone()
                cont.resume(returning: r)
            }
        }
        if state.timedOut {
            throw QueryDataError.timeout(seconds: Double(deadline.components.seconds))
        }
        return try result.get()
    }

    final class DeadlineState: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false, fired = false
        var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return fired }
        func markDone() { lock.lock(); done = true; lock.unlock() }
        /// True when the deadline wins (the job is still running).
        func markTimedOut() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; fired = true; return true }
    }

    // MARK: result text

    /// The tool result for the model (and the activity line): line 1 is the JSON summary
    /// `{columns, data_ref, elapsed_ms, file, row_count, truncated, types}`, then the shown rows as a Markdown table
    /// (the rows are not repeated in the JSON: fewer tokens; the activity line keeps only the first 2,000 chars).
    public static func resultText(_ r: QueryResult, file: String? = nil) -> String {
        struct Summary: Encodable {
            var columns: [String]; var data_ref: String; var elapsed_ms: Int; var file: String?; var row_count: Int
            var truncated: Bool; var types: [String]
        }
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? e.encode(Summary(columns: r.columns, data_ref: r.dataRef, elapsed_ms: r.elapsedMS, file: file,
                                          row_count: r.rowCount, truncated: r.truncated, types: r.types)))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var md = "| " + r.columns.map(SheetProfile.cell).joined(separator: " | ") + " |\n"
        md += "|" + String(repeating: " --- |", count: r.columns.count) + "\n"
        for row in r.rows { md += "| " + row.map(SheetProfile.cell).joined(separator: " | ") + " |\n" }
        if r.truncated { md += "(showing \(r.rows.count) of \(r.rowCount) rows)\n" }
        if let note = groupingNote(r) { md += note + "\n" }
        if let note = monthLabelNote(r) { md += note + "\n" }
        if let note = castLengthNote(r) { md += note + "\n" }
        return json + "\n" + md
    }

    /// M6.T12 follow-up (AT-274 T1 runs: `SELECT date::VARCHAR(7) AS month … GROUP BY date` gave one row per day and the
    /// model repeated the same call): a grouped result whose first text column repeats its values gets a factual note.
    static func groupingNote(_ r: QueryResult) -> String? {
        guard r.sql.range(of: #"\bgroup\s+by\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let i = r.types.indices.first(where: { !ChartSpecRepair.isNumeric(r.types[$0]) }), r.rows.count > 1 else { return nil }
        let values = r.rows.compactMap { i < $0.count ? $0[i] : nil }
        let distinct = Set(values).count
        guard distinct < values.count else { return nil }
        return "Note: \"\(r.columns[i])\" repeats (\(values.count) rows, \(distinct) distinct values): the query groups by something "
            + "finer than \"\(r.columns[i])\". GROUP BY the same expression you select (e.g. GROUP BY 1) for one row per value."
    }

    /// M6.T21 (AT-274 on the merged head, sc-12: `date::VARCHAR(7) AS month … GROUP BY date` meant "2026-01" but gave one
    /// row per day, and the model re-sent the same call): DuckDB ignores the length in VARCHAR(n) / CHAR(n), so a text
    /// column with values longer than the n in the SQL gets a factual note naming what does cut text.
    static func castLengthNote(_ r: QueryResult) -> String? {
        let re = try! NSRegularExpression(pattern: #"\b(?:var)?char\s*\(\s*(\d+)\s*\)"#, options: [.caseInsensitive])
        let ns = r.sql as NSString
        let lengths = re.matches(in: r.sql, range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range(at: 1))) }
        guard let n = lengths.min() else { return nil }
        for i in r.types.indices where !ChartSpecRepair.isNumeric(r.types[i]) {
            guard let long = r.rows.lazy.compactMap({ i < $0.count ? $0[i] : nil }).first(where: { $0.count > n }) else { continue }
            return "Note: DuckDB ignores the length in VARCHAR(\(n)), so the cast does not shorten text: \"\(r.columns[i])\" "
                + "has values longer than \(n) characters (e.g. \"\(long)\"). To cut text use left(x, \(n)); for YYYY-MM months "
                + "select strftime(date, '%Y-%m') and GROUP BY 1."
        }
        return nil
    }

    /// M6.T21 (AT-274 run on the merged head, sc-11: `year || '-' || month` gave "2025-1" … "2025-12", which also sorts
    /// out of order): a text column of year-month labels whose month is not two digits gets a factual note.
    static func monthLabelNote(_ r: QueryResult) -> String? {
        let unpadded = try! NSRegularExpression(pattern: #"^\d{4}-\d$"#)
        let yearMonth = try! NSRegularExpression(pattern: #"^\d{4}-\d{1,2}$"#)
        func all(_ re: NSRegularExpression, _ v: [String]) -> Bool {
            v.allSatisfy { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        }
        for i in r.types.indices where !ChartSpecRepair.isNumeric(r.types[i]) {
            let values = r.rows.compactMap { i < $0.count ? $0[i] : nil }
            guard !values.isEmpty, all(yearMonth, values), values.contains(where: { all(unpadded, [$0]) }) else { continue }
            return "Note: \"\(r.columns[i])\" has months without a leading zero (e.g. \"\(values.first { all(unpadded, [$0]) }!)\"), "
                + "so they are not YYYY-MM and sort out of order. For YYYY-MM select strftime(date, '%Y-%m')."
        }
        return nil
    }

    /// The summary line of a result (activity line: `act.queried` {file} · {rows}).
    public struct Summary: Decodable, Sendable, Equatable {
        public var row_count: Int
        public var file: String?
        public var truncated: Bool
        public var data_ref: String
    }

    public static func summary(ofResult text: String) -> Summary? {
        guard let line = text.split(separator: "\n", maxSplits: 1).first else { return nil }
        return try? JSONDecoder().decode(Summary.self, from: Data(line.utf8))
    }

    /// The source files of the tables `sql` names (for `{file}`).
    public static func files(in sql: String, tables: [LoadedTable]) -> [String] {
        let lower = sql.lowercased()
        var out: [String] = []
        for t in tables where lower.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: t.name.lowercased()) + #"\b"#,
                                          options: .regularExpression) != nil && !out.contains(t.file) {
            out.append(t.file)
        }
        return out
    }

    static func typeName(_ t: DatabaseType) -> String {
        switch t {
        case .boolean: "BOOLEAN"
        case .tinyint: "TINYINT"
        case .smallint: "SMALLINT"
        case .integer: "INTEGER"
        case .bigint: "BIGINT"
        case .hugeint: "HUGEINT"
        case .ubigint: "UBIGINT"
        case .float: "FLOAT"
        case .double: "DOUBLE"
        case .decimal: "DECIMAL"
        case .date: "DATE"
        case .time: "TIME"
        case .timestamp, .timestampS, .timestampMS, .timestampNS, .timestampTz: "TIMESTAMP"
        case .interval: "INTERVAL"
        case .varchar: "VARCHAR"
        default: "\(t)".uppercased()
        }
    }

    static func statementName(_ t: Int) -> String {
        let names = [2: "INSERT", 3: "UPDATE", 4: "EXPLAIN", 5: "DELETE", 6: "PREPARE", 7: "CREATE", 8: "EXECUTE",
                     9: "ALTER", 10: "TRANSACTION", 11: "COPY", 12: "ANALYZE", 13: "SET VARIABLE", 14: "CREATE FUNCTION",
                     15: "DROP", 16: "EXPORT", 17: "PRAGMA", 18: "VACUUM", 19: "CALL", 20: "SET", 21: "LOAD",
                     23: "EXTENSION", 25: "ATTACH", 26: "DETACH"]
        return names[t] ?? "non-SELECT"
    }
}
