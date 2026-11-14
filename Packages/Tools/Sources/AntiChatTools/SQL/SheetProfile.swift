// M6.T07 step 5 (R-272 AC1): what the model sees of a loaded sheet: per table its name, columns with types, row
// count, first and last rows, and column stats from DuckDB `SUMMARIZE` (min, max, avg, null %, approx unique). Never
// the full table. The block is untrusted document content (NFR-SEC5) and is capped by tokens per tier
// (tier-budgets.json `files.sheet_profile_tokens`: T0 1.5K, T1+ 3K); detail drops (5+5 rows → 2+2 → 0 → no stats)
// until it fits.
import AntiChatFoundation
import Foundation
import OsaurusVendored

public enum SheetProfile {
    public static func block(_ tables: [LoadedTable], store: DuckDBStore, tokenCap: Int) throws -> String {
        var stats: [String: [[String?]]] = [:]
        var heads: [String: (cols: [String], first: [[String?]], last: [[String?]])] = [:]
        for t in tables {
            let q = DuckDBStore.quote(t.name)
            stats[t.name] = try store.stringRows("""
                SELECT column_name, min, max, avg, null_percentage, approx_unique FROM (SUMMARIZE \(q))
                """).rows
            let first = try store.stringRows("SELECT * FROM \(q) LIMIT 5")
            let last = try store.stringRows("SELECT * FROM \(q) OFFSET \(max(5, t.rowCount - 5))")
            heads[t.name] = (first.columns, first.rows, last.rows)
        }
        for level in [5, 2, 0, -1] {
            let text = render(tables, stats: stats, heads: heads, rows: level)
            if TokenEstimator.estimate(text) <= tokenCap || level == -1 { return text }
        }
        return ""
    }

    /// `rows`: rows shown from each end (−1 = no rows and no stats).
    static func render(_ tables: [LoadedTable], stats: [String: [[String?]]],
                       heads: [String: (cols: [String], first: [[String?]], last: [[String?]])], rows: Int) -> String {
        var out = ""
        out += "Spreadsheet data loaded as SQL tables (DuckDB). Query them with the query_data tool; this is a profile, not the full data.\n"
        for t in tables {
            let src = t.sheet.map { "\(t.file) › \($0)" } ?? t.file
            out += "\nTable \(DuckDBStore.quote(t.name)) from \(src): \(t.rowCount) rows\n"
            out += "Columns: " + t.columns.map { "\(DuckDBStore.quote($0.name)) \($0.type.rawValue)" }.joined(separator: ", ") + "\n"
            if rows >= 0, let st = stats[t.name] {
                out += "Stats (min | max | avg | null % | approx unique):\n"
                for r in st {
                    let v = r.map { cell($0) }
                    out += "- \(v[0]): \(v[1]) | \(v[2]) | \(r[3] == nil ? "-" : v[3]) | \(v[4]) | \(v[5])\n"
                }
            }
            if rows > 0, let h = heads[t.name] {
                out += "First rows:\n" + table(h.cols, Array(h.first.prefix(rows)))
                if t.rowCount > 5 {
                    out += "Last rows:\n" + table(h.cols, Array(h.last.suffix(rows)))
                }
            }
        }
        return "<sheet_tables untrusted=\"true\">\n" + UntrustedText.neutralised(out) + "</sheet_tables>"
    }

    static func cell(_ s: String?) -> String {
        guard let s else { return "NULL" }
        let t = s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        return t.count > 40 ? String(t.prefix(39)) + "…" : t
    }

    static func table(_ cols: [String], _ rows: [[String?]]) -> String {
        var s = "| " + cols.map { cell($0) }.joined(separator: " | ") + " |\n"
        s += "|" + String(repeating: " --- |", count: cols.count) + "\n"
        for r in rows { s += "| " + r.map(cell).joined(separator: " | ") + " |\n" }
        return s
    }
}
