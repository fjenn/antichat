// M6.T10 step 1 (R-273): the `create_spreadsheet` / `export_table` schemas and the spreadsheet spec model. A sheet has
// typed columns (number | text | date | currency | percent | bool, optional Excel number format) and at most one of
// `rows` (literal values) or `data_ref` (a `query_data` result, `qr_…`); when a sheet repeats a query result's columns
// the model must pass that `data_ref` instead of retyping the numbers (R-274 AC1 spirit). Optional formulas
// ({"B14": "SUM(B2:B13)"}), frozen header and autofilter (default on), column widths ("auto" or numbers) and a native
// chart. A sheet with neither rows nor data_ref is a header-only template (what small models make when the prompt
// gives no data). `revises` (all create tools) makes the file the next version of an earlier artifact (R-273 AC4).
import Foundation

public enum SpreadsheetSchemas {
    public static let createName = "create_spreadsheet"
    public static let exportName = "export_table"

    public static let createDescription = """
        Create a downloadable spreadsheet (Excel .xlsx or .csv). Give each sheet typed columns and either `rows` (values) \
        or `data_ref` (the data_ref of a query_data result — required when the data came from an attached file). Optional: \
        Excel formulas by cell ({"B14": "SUM(B2:B13)"}, no "="), number formats, a native chart (on the sheet that holds \
        its data). A CSV is one sheet of plain values: no formulas, no chart, no second sheet. The whole call must fit \
        in one reply: write at most 40 `rows` per sheet; for a bigger ask (hundreds of items, a year of daily values) \
        write a representative 40-row sample and say the user can ask for more. To change a file you made \
        earlier, pass its artifact_id as `revises`. Runs on this Mac; nothing is uploaded.
        """

    public static let exportDescription = """
        Save a query_data result (its data_ref) as a downloadable .csv or .xlsx file. Use it when the user wants the \
        table itself as a file.
        """

    static let column = #"{"type":"object","properties":{"header":{"type":"string","minLength":1},"type":{"type":"string","enum":["number","text","date","currency","percent","bool"]},"format":{"type":"string","description":"Excel number format, e.g. #,##0.00 or 0% or yyyy-mm-dd"}},"required":["header","type"],"additionalProperties":false}"#
    static let chart = #"{"type":"object","properties":{"type":{"type":"string","enum":["column","bar","line","pie","scatter"]},"title":{"type":"string"},"categories":{"type":"string","description":"Cell range, e.g. A2:A13"},"values":{"type":"array","minItems":1,"maxItems":8,"items":{"type":"string"}}},"required":["type","categories","values"],"additionalProperties":false}"#
    static let sheet = #"{"type":"object","properties":{"name":{"type":"string","minLength":1,"maxLength":31},"columns":{"type":"array","minItems":1,"maxItems":200,"items":"# + column + #"},"rows":{"type":"array","maxItems":100000,"items":{"type":"array","items":{"type":["string","number","boolean","null"]}}},"data_ref":{"type":"string","minLength":1},"formulas":{"type":"object","description":"Cell → formula, e.g. {\"B14\": \"SUM(B2:B13)\"}; keys are cells, not names.","additionalProperties":{"type":"string"}},"freeze_header":{"type":"boolean"},"autofilter":{"type":"boolean"},"column_widths":{"anyOf":[{"type":"string","enum":["auto"]},{"type":"array","items":{"type":"number","minimum":1,"maximum":255}}]},"chart":"# + chart + #"},"required":["name"],"additionalProperties":false}"#

    public static let createJSON = #"{"type":"object","properties":{"filename":{"type":"string","minLength":1,"maxLength":200},"format":{"type":"string","enum":["xlsx","csv"],"description":"The format the user asked for. csv = exactly one sheet, no formulas, no chart."},"sheets":{"type":"array","minItems":1,"maxItems":20,"description":"A JSON array of sheet objects (never a string).","items":"# + sheet + #"},"revises":{"type":"string","description":"artifact_id of the file this replaces with a new version"}},"required":["filename","sheets"],"additionalProperties":false}"#

    public static let exportJSON = #"{"type":"object","properties":{"data_ref":{"type":"string","minLength":1},"format":{"type":"string","enum":["csv","xlsx"]},"filename":{"type":"string","minLength":1,"maxLength":200},"revises":{"type":"string"}},"required":["data_ref","format","filename"],"additionalProperties":false}"#
}

/// One cell value of a spec row.
public enum CellValue: Sendable, Equatable {
    case number(Double)
    case text(String)
    case bool(Bool)
    case empty

    init(json: Any?) {
        switch json {
        case nil, is NSNull: self = .empty
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let s as String: self = .text(s)
        default: self = .text("\(json!)")
        }
    }

    public var text: String {
        switch self {
        case .number(let d): CellValue.format(d)
        case .text(let s): s
        case .bool(let b): b ? "TRUE" : "FALSE"
        case .empty: ""
        }
    }

    /// Shortest round-tripping decimal (no exponent for everyday magnitudes, no trailing ".0").
    static func format(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return "\(d)"
    }
}

public struct SheetSpec: Sendable, Equatable {
    public struct Column: Sendable, Equatable {
        public enum Kind: String, Sendable { case number, text, date, currency, percent, bool }
        public var header: String
        public var type: Kind
        public var format: String?
    }
    public struct Chart: Sendable, Equatable {
        public var type: String
        public var title: String?
        public var categories: String
        public var values: [String]
    }

    public var name: String
    public var columns: [Column]
    public var rows: [[CellValue]]
    public var dataRef: String?
    public var formulas: [String: String]
    public var freezeHeader: Bool
    public var autofilter: Bool
    /// nil = auto.
    public var columnWidths: [Double]?
    public var chart: Chart?
}

public struct SpreadsheetSpec: Sendable, Equatable {
    public enum Format: String, Sendable { case xlsx, csv }
    public var filename: String
    public var format: Format
    public var sheets: [SheetSpec]
    public var revises: String?

    /// The file name with the format's extension.
    public var outputName: String {
        let base = (filename as NSString).pathExtension.lowercased() == format.rawValue
            ? (filename as NSString).deletingPathExtension : filename
        return FileOutNames.filename(title: base, ext: format.rawValue)
    }

    /// Parses `create_spreadsheet` arguments; `data_ref` sheets are filled from `refs` (columns from the result unless
    /// the sheet gives its own).
    public static func parse(_ json: String, refs: (String) -> DataRef? = { _ in nil }) throws -> SpreadsheetSpec {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            throw FileOutError.invalidSpec(["$: not a JSON object"])
        }
        let format = Format(rawValue: (o["format"] as? String) ?? (((o["filename"] as? String) ?? "").lowercased().hasSuffix(".csv") ? "csv" : "xlsx")) ?? .xlsx
        var sheets: [SheetSpec] = []
        for (i, s) in ((o["sheets"] as? [[String: Any]]) ?? []).enumerated() {
            var columns: [SheetSpec.Column] = ((s["columns"] as? [[String: Any]]) ?? []).map {
                SheetSpec.Column(header: $0["header"] as? String ?? "", type: SheetSpec.Column.Kind(rawValue: $0["type"] as? String ?? "") ?? .text,
                                 format: $0["format"] as? String)
            }
            var rows: [[CellValue]] = ((s["rows"] as? [[Any]]) ?? []).map { $0.map { CellValue(json: $0 is NSNull ? nil : $0) } }
            let dataRef = s["data_ref"] as? String
            if let dataRef {
                guard let ref = refs(dataRef) else { throw FileOutError.invalidSpec(["$.sheets[\(i)].data_ref: no query result \"\(dataRef)\" in this chat"]) }
                let fromRef = Self.columns(of: ref)
                if columns.isEmpty { columns = fromRef } else if columns.count < fromRef.count { columns += fromRef.dropFirst(columns.count) }
                rows = Self.rows(of: ref, columns: columns)
            }
            if dataRef == nil, columns.isEmpty, !rows.isEmpty {
                // Small models often omit `columns` and put the header in the first row: accept that (header = an
                // all-text first row, else "Column n"), types inferred from the values.
                let first = rows[0]
                let headerRow = first.allSatisfy { if case .text = $0 { true } else { false } } && rows.count > 1
                let body = headerRow ? Array(rows.dropFirst()) : rows
                let width = rows.map(\.count).max() ?? 0
                columns = (0..<width).map { c in
                    let name = headerRow && c < first.count ? first[c].text : "Column \(c + 1)"
                    return SheetSpec.Column(header: name, type: Self.infer(body.compactMap { c < $0.count ? $0[c] : nil }), format: nil)
                }
                rows = body
            }
            var formulas = s["formulas"] as? [String: String] ?? [:]
            if dataRef != nil, formulas.keys.contains(where: { XLSXWriter.cell($0) == nil }) {
                // M9 review F3: formulas keyed by a column name on a query-result sheet ("Total": "SUM(Hours)") → cells
                // for the result's real row count: the total in the first row below the data, never over a data row.
                var d: [String: Any] = [
                    "columns": columns.map { ["header": $0.header, "type": $0.type.rawValue] as [String: Any] },
                    "rows": rows.map { $0.map { $0 == .empty ? NSNull() as Any : 1 as Any } },
                    "formulas": formulas,
                ]
                var ignored: [String] = []
                FileOutNormalizer.formulas(&d, csv: false, notes: &ignored)
                formulas = d["formulas"] as? [String: String] ?? [:]
                for c in ((d["columns"] as? [[String: Any]]) ?? []).dropFirst(columns.count) {
                    columns.append(SheetSpec.Column(header: c["header"] as? String ?? "", type: .number, format: nil))
                }
            }
            let widths: [Double]? = (s["column_widths"] as? [NSNumber])?.map(\.doubleValue)
            // A chart may name its columns by header ("Region") instead of a range: resolve to the data range.
            let lastRow = rows.count + 1
            func range(_ r: String) -> String {
                guard let c = columns.firstIndex(where: { $0.header.caseInsensitiveCompare(r.trimmingCharacters(in: .whitespaces)) == .orderedSame }) else { return r }
                var letters = "", n = c + 1
                while n > 0 { let m = (n - 1) % 26; letters = String(UnicodeScalar(65 + m)!) + letters; n = (n - 1) / 26 }
                return "\(letters)2:\(letters)\(max(lastRow, 2))"
            }
            let chart = (s["chart"] as? [String: Any]).map {
                SheetSpec.Chart(type: $0["type"] as? String ?? "column", title: $0["title"] as? String,
                                categories: range($0["categories"] as? String ?? ""), values: ($0["values"] as? [String] ?? []).map(range))
            }
            sheets.append(SheetSpec(name: s["name"] as? String ?? "Sheet\(i + 1)", columns: columns, rows: rows, dataRef: dataRef,
                                    formulas: formulas,
                                    freezeHeader: s["freeze_header"] as? Bool ?? true, autofilter: s["autofilter"] as? Bool ?? true,
                                    columnWidths: widths, chart: chart))
        }
        return SpreadsheetSpec(filename: o["filename"] as? String ?? "Spreadsheet", format: format, sheets: sheets,
                               revises: o["revises"] as? String)
    }

    /// The column kind of literal values: all numbers → number, all booleans → bool, all ISO dates → date, else text.
    static func infer(_ values: [CellValue]) -> SheetSpec.Column.Kind {
        let v = values.filter { $0 != .empty }
        guard !v.isEmpty else { return .text }
        if v.allSatisfy({ if case .number = $0 { true } else { false } }) { return .number }
        if v.allSatisfy({ if case .bool = $0 { true } else { false } }) { return .bool }
        if v.allSatisfy({ if case .text(let s) = $0 { s.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil } else { false } }) {
            return .date
        }
        return .text
    }

    /// DuckDB result types → column kinds (DATE/TIMESTAMP → date, numerics → number, BOOLEAN → bool, else text).
    public static func columns(of ref: DataRef) -> [SheetSpec.Column] {
        zip(ref.columns, ref.types + Array(repeating: "VARCHAR", count: max(0, ref.columns.count - ref.types.count))).map { name, t in
            let u = t.uppercased()
            let kind: SheetSpec.Column.Kind = u.hasPrefix("DATE") || u.hasPrefix("TIMESTAMP") ? .date
                : ["TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT", "UBIGINT", "FLOAT", "DOUBLE", "DECIMAL", "REAL"].contains { u.hasPrefix($0) } ? .number
                : u == "BOOLEAN" ? .bool : .text
            return SheetSpec.Column(header: name, type: kind, format: kind == .date ? (u.hasPrefix("TIMESTAMP") ? "yyyy-mm-dd hh:mm" : "yyyy-mm-dd") : nil)
        }
    }

    static func rows(of ref: DataRef, columns: [SheetSpec.Column]) -> [[CellValue]] {
        ref.rows.map { row in
            row.enumerated().map { i, v in
                guard let v else { return .empty }
                let kind = i < columns.count ? columns[i].type : .text
                switch kind {
                case .number, .currency, .percent: return Double(v).map(CellValue.number) ?? .text(v)
                case .bool: return v.lowercased() == "true" ? .bool(true) : v.lowercased() == "false" ? .bool(false) : .text(v)
                default: return .text(v)
                }
            }
        }
    }
}
