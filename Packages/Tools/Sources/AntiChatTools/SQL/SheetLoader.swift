// M6.T07 step 4 (R-272 AC1): spreadsheets → typed DuckDB tables, one per sheet, through the Appender only.
//   XLSX → vendored Osaurus `XLSXAdapter` (+ `XLSXDateStyles`: date-formatted numbers → ISO text)
//   XLS  → the caller passes the `Workbook` from AntiChatKnowledge `XLSAdapter` (libxls, A-M6-10; Tools may not import
//          Knowledge, architecture §3)
//   CSV/TSV → vendored `CSVAdapter` parsing in Swift. DuckDB `read_csv` is not used: with `enable_external_access =
//          false` it cannot read a local path (DuckDBStoreTests.testExternalAccessDenied proves it), M6.T07 step 4 fallback.
// Column types are inferred over all rows: BOOLEAN, BIGINT, DOUBLE, DATE, TIMESTAMP, TIME, else VARCHAR. Row 1 is the
// header; table names are sanitised (`[A-Za-z0-9_]`) and de-duplicated per chat.
import DuckDB
import Foundation
import OsaurusVendored

public struct LoadedTable: Sendable, Equatable {
    public struct Column: Sendable, Equatable {
        public var name: String
        public var type: SQLType
    }
    public var name: String
    /// File name, and the sheet name for workbooks.
    public var file: String
    public var sheet: String?
    public var columns: [Column]
    public var rowCount: Int
}

public enum SQLType: String, Sendable, Equatable {
    case boolean = "BOOLEAN", bigint = "BIGINT", double = "DOUBLE", date = "DATE", timestamp = "TIMESTAMP",
         time = "TIME", varchar = "VARCHAR"
}

public enum SheetLoaderError: Error, Equatable, Sendable {
    case read(String)
    case empty
}

public enum SheetLoader {
    /// A sheet as header + rows of cell values (dense, padded to the header width).
    struct Grid {
        var name: String
        var header: [String]
        var rows: [[Workbook.CellValue]]
    }

    // MARK: entry points

    /// Same file-size cap as intake (512 MB, R-020).
    public static let sizeLimit: Int64 = 512 * 1024 * 1024

    /// `file`: the name the user knows (the media store names blobs by hash); default the URL's last component.
    public static func load(xlsx url: URL, file: String? = nil, into store: DuckDBStore) async throws -> [LoadedTable] {
        let wb: Workbook
        do {
            let parsed = try await XLSXAdapter().parse(url: url, sizeLimit: sizeLimit)
            guard let w = parsed.representation.underlying as? Workbook else { throw SheetLoaderError.empty }
            wb = w
        } catch let e as SheetLoaderError {
            throw e
        } catch {
            throw SheetLoaderError.read(String(describing: error))
        }
        let dates = (try? XLSXDateStyles.dateCells(xlsx: Data(contentsOf: url))) ?? XLSXDateStyles.Result()
        return try load(workbook: XLSXDateStyles.apply(dates, to: wb), file: file ?? url.lastPathComponent, into: store)
    }

    /// XLSX after the date pass, or XLS from `XLSAdapter`: values are typed, `.string` is never re-parsed as a number.
    public static func load(workbook: Workbook, file: String, into store: DuckDBStore) throws -> [LoadedTable] {
        let grids = workbook.sheets.compactMap(grid)
        guard !grids.isEmpty else { throw SheetLoaderError.empty }
        return try grids.map { try load($0, file: file, sheet: $0.name, parseText: false, into: store) }
    }

    public static func load(csv url: URL, delimiter: CSVDelimiter = .comma, file: String? = nil,
                            into store: DuckDBStore) async throws -> [LoadedTable] {
        let rows: [[String]]
        do {
            let parsed = try await CSVAdapter(delimiter: delimiter).parse(url: url, sizeLimit: sizeLimit)
            guard let doc = parsed.representation.underlying as? CSVDocument else { throw SheetLoaderError.empty }
            rows = doc.rows.map { $0.cells.map(\.text) }
        } catch let e as SheetLoaderError {
            throw e
        } catch {
            throw SheetLoaderError.read(String(describing: error))
        }
        guard let head = rows.first else { throw SheetLoaderError.empty }
        let width = rows.map(\.count).max() ?? 0
        let header = (0..<width).map { $0 < head.count ? head[$0] : "" }
        let body = rows.dropFirst().filter { !$0.allSatisfy(\.isEmpty) }.map { r in
            (0..<width).map { i -> Workbook.CellValue in i < r.count && !r[i].isEmpty ? .string(r[i]) : .empty }
        }
        let name = file ?? url.lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        return [try load(Grid(name: stem, header: header, rows: Array(body)), file: name, sheet: nil,
                         parseText: true, into: store)]
    }

    // MARK: grid

    static func grid(_ sheet: Workbook.Sheet) -> Grid? {
        let rows = sheet.rows.sorted { $0.number < $1.number }
        guard let head = rows.first else { return nil }
        let width = rows.map { $0.cells.map(\.columnNumber).max() ?? 0 }.max() ?? 0
        guard width > 0 else { return nil }
        func dense(_ r: Workbook.Row) -> [Workbook.CellValue] {
            var out = Array(repeating: Workbook.CellValue.empty, count: width)
            for c in r.cells where c.columnNumber >= 1 && c.columnNumber <= width { out[c.columnNumber - 1] = c.value }
            return out
        }
        let header = dense(head).map(\.fallbackText)
        return Grid(name: sheet.name, header: header, rows: rows.dropFirst().map(dense))
    }

    // MARK: load one grid

    static func load(_ g: Grid, file: String, sheet: String?, parseText: Bool, into store: DuckDBStore) throws -> LoadedTable {
        let names = columnNames(g.header)
        let types = names.indices.map { i in infer(g.rows.lazy.map { i < $0.count ? $0[i] : .empty }, parseText: parseText) }
        let table = store.claimTableName(sheet ?? g.name)
        let cols = zip(names, types).map { "\(DuckDBStore.quote($0)) \($1.rawValue)" }.joined(separator: ", ")
        try store.withConnection { c in
            _ = try DuckDBStore.run(c, "CREATE TABLE \(DuckDBStore.quote(table)) (\(cols))")
            let app: Appender
            do { app = try Appender(connection: c, table: table) } catch { throw DuckDBStoreError.query(String(describing: error)) }
            do {
                for row in g.rows {
                    for (i, t) in types.enumerated() { try append(i < row.count ? row[i] : .empty, as: t, to: app) }
                    try app.endRow()
                }
                try app.flush()
            } catch let e as DuckDBStoreError {
                throw e
            } catch {
                throw DuckDBStoreError.query("load \(table): \(error)")
            }
        }
        return LoadedTable(name: table, file: file, sheet: sheet,
                           columns: zip(names, types).map { LoadedTable.Column(name: $0, type: $1) }, rowCount: g.rows.count)
    }

    /// Header text → unique, non-empty column names (DuckDB identifiers are case-insensitive).
    static func columnNames(_ header: [String]) -> [String] {
        var seen: Set<String> = []
        return header.enumerated().map { i, raw in
            var base = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
            if base.isEmpty { base = "column_\(i + 1)" }
            var name = base, n = 2
            while seen.contains(name.lowercased()) { name = "\(base)_\(n)"; n += 1 }
            seen.insert(name.lowercased())
            return name
        }
    }

    // MARK: type inference

    static func infer<S: Sequence>(_ values: S, parseText: Bool) -> SQLType where S.Element == Workbook.CellValue {
        var bool = true, int = true, dbl = true, date = true, ts = true, time = true, any = false
        for v in values {
            switch v {
            case .empty: continue
            case .bool:
                int = false; dbl = false; date = false; ts = false; time = false
            case .number(let d):
                bool = false; date = false; ts = false; time = false
                if !(d.isFinite && d.rounded() == d && abs(d) < 9.007e15) { int = false }
            case .string(let s):
                let t = s.trimmingCharacters(in: .whitespaces)
                if !(parseText && Self.bool(t) != nil) { bool = false }
                if !(parseText && Int64(t) != nil) { int = false }
                if !(parseText && Self.double(t) != nil) { dbl = false }
                let k = Temporal.kind(t)
                if k != .date { date = false }
                if k != .date && k != .timestamp { ts = false }
                if k != .time { time = false }
            }
            any = true
            if !(bool || int || dbl || date || ts || time) { return .varchar }
        }
        guard any else { return .varchar }
        if bool { return .boolean }
        if int { return .bigint }
        if dbl { return .double }
        if date { return .date }
        if ts { return .timestamp }
        if time { return .time }
        return .varchar
    }

    static func bool(_ s: String) -> Bool? {
        switch s.lowercased() { case "true": true; case "false": false; default: nil }
    }

    static func double(_ s: String) -> Double? {
        guard let d = Double(s), d.isFinite, s.rangeOfCharacter(from: .letters.subtracting(CharacterSet(charactersIn: "eE"))) == nil
        else { return nil }
        return d
    }

    enum Temporal {
        case date, timestamp, time
        nonisolated(unsafe) static let dateRX = /^\d{4}-\d{2}-\d{2}$/
        nonisolated(unsafe) static let tsRX = /^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(:\d{2}(\.\d{1,6})?)?$/
        nonisolated(unsafe) static let timeRX = /^\d{2}:\d{2}:\d{2}(\.\d{1,6})?$/
        static func kind(_ s: String) -> Temporal? {
            guard s.count >= 8, s.count <= 26, let f = s.first, f.isNumber else { return nil }
            if s.wholeMatch(of: dateRX) != nil { return .date }
            if s.wholeMatch(of: tsRX) != nil { return .timestamp }
            if s.wholeMatch(of: timeRX) != nil { return .time }
            return nil
        }
    }

    static func append(_ v: Workbook.CellValue, as t: SQLType, to app: Appender) throws {
        switch (t, v) {
        case (_, .empty): try app.append(nil as String?)
        case (.boolean, .bool(let b)): try app.append(b)
        case (.boolean, .string(let s)): try app.append(Self.bool(s.trimmingCharacters(in: .whitespaces)))
        case (.bigint, .number(let d)): try app.append(Int64(d))
        case (.bigint, .string(let s)): try app.append(Int64(s.trimmingCharacters(in: .whitespaces)))
        case (.double, .number(let d)): try app.append(d)
        case (.double, .string(let s)): try app.append(Self.double(s.trimmingCharacters(in: .whitespaces)))
        // DATE/TIMESTAMP/TIME columns hold ISO text only (inference guarantees it); the appender casts VARCHAR.
        case (.date, .string(let s)), (.timestamp, .string(let s)), (.time, .string(let s)):
            try app.append(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "T", with: " "))
        default: try app.append(v.fallbackText)
        }
    }
}
