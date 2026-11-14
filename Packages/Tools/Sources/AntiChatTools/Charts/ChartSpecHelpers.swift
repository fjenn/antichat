// M6.T12 (R-274): helpers for `create_chart` — field names a Vega-Lite spec reads, typed values for injected rows and
// downsampling of very long series.
// Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Tools/RenderChartTool.swift (numericValue, downsample;
// MIT). The rest of that tool (delimited/JSON payload recovery, NativeChartView) is not used (D-07).
import Foundation

public enum ChartSpecHelpers {
    /// Rows above this are downsampled evenly before rendering (a line of 100 000 points renders slowly and adds nothing
    /// at chart size). Aggregates are computed by DuckDB before the chart, so grouped results are far below it.
    public static let maxRows = 5_000

    /// Every `field` the spec's encodings, transforms and layers name (`"a.b"` nested paths are kept as written).
    public static func fields(in spec: Any) -> Set<String> {
        var out: Set<String> = []
        func walk(_ v: Any, key: String?) {
            if let d = v as? [String: Any] {
                for (k, x) in d {
                    if (k == "field" || k == "groupby" || k == "fields"), let s = x as? String { out.insert(s) }
                    if k == "groupby" || k == "fields", let a = x as? [Any] { a.compactMap { $0 as? String }.forEach { out.insert($0) } }
                    if k == "data" { continue }  // inline values are not fields
                    walk(x, key: k)
                }
            } else if let a = v as? [Any] {
                a.forEach { walk($0, key: key) }
            }
        }
        walk(spec, key: nil)
        return out
    }

    /// The spec (or any layer / concat member) carries inline `data.values`.
    public static func hasInlineValues(_ spec: Any) -> Bool {
        if let d = spec as? [String: Any] {
            if let data = d["data"] as? [String: Any], data["values"] != nil { return true }
            return d.values.contains(where: hasInlineValues)
        }
        if let a = spec as? [Any] { return a.contains(where: hasInlineValues) }
        return false
    }

    /// The spec (or a nested member) loads data by URL; never allowed (the render is offline).
    public static func hasURLData(_ spec: Any) -> Bool {
        if let d = spec as? [String: Any] {
            if let data = d["data"] as? [String: Any], data["url"] != nil { return true }
            return d.values.contains(where: hasURLData)
        }
        if let a = spec as? [Any] { return a.contains(where: hasURLData) }
        return false
    }

    /// The spec aggregates (`aggregate` in an encoding or a transform).
    public static func aggregates(_ spec: Any) -> Bool {
        if let d = spec as? [String: Any] {
            if d["aggregate"] != nil { return true }
            return d.values.contains(where: aggregates)
        }
        if let a = spec as? [Any] { return a.contains(where: aggregates) }
        return false
    }

    /// A DuckDB text cell as the JSON value Vega should see (numbers stay numbers, NULL → null).
    public static func value(_ cell: String?, type: String) -> Any {
        guard let cell else { return NSNull() }
        let t = type.uppercased()
        let numeric = ["TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT", "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT",
                       "FLOAT", "DOUBLE", "REAL"].contains(t) || t.hasPrefix("DECIMAL")
        if numeric, let n = numericValue(cell) { return n }
        if t == "BOOLEAN" { return cell == "true" }
        return cell
    }

    static func numericValue(_ value: Any) -> Double? {
        if value is NSNull { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    static func downsample<T>(_ rows: [T], to maxCount: Int) -> [T] {
        guard rows.count > maxCount else { return rows }
        let step = Double(rows.count) / Double(maxCount)
        return (0..<maxCount).map { i in rows[Int(Double(i) * step)] }
    }

    /// The rows of `ref` as Vega records (column name → typed value), downsampled past `maxRows`.
    public static func records(_ ref: DataRef) -> [[String: Any]] {
        downsample(ref.rows, to: maxRows).map { row in
            var r: [String: Any] = [:]
            for (i, c) in ref.columns.enumerated() where i < row.count {
                r[c] = value(row[i], type: i < ref.types.count ? ref.types[i] : "VARCHAR")
            }
            return r
        }
    }
}
