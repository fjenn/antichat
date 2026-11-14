// M6.T12 follow-up (R-274 AC3; M6.md T12 "Known failure modes": "the host validates that the spec does not re-aggregate
// a data_ref that is already grouped … → fix"). A chart bound to a query result plots that result's exact rows; the
// model only chooses how to draw them. T1 models write specs that cannot draw those rows (AT-274 runs 2026-11-04:
// re-aggregating a grouped result, `encoding` nested in `mark`, facets on the plotted field, fields that are not
// columns, invalid channel types, a spec string with extra closing braces). The host repairs the drawing, never the
// numbers:
//   - grouped result: `aggregate` / `bin` dropped from channels and the spec's transforms dropped (the rows are the
//     answer); facets, layers and concats reduced to one view (the first layer's mark / encoding);
//   - `mark.encoding` / `mark.color` lifted into `encoding`; an unknown mark type → bar;
//   - a channel field that is not a column (or missing): x / y get the result's label and value columns, other
//     channels are dropped; channel types follow the column type (numbers quantitative, dates temporal, text nominal);
//   - x or y missing (or theta for arcs): the label column and the first unused numeric column.
// If the repaired spec still fails to render, `fallback` draws the rows as a plain chart of the requested mark (bar
// by default): label column × first numeric column. Inline (conversation) charts are never repaired.
import Foundation

public enum ChartSpecRepair {
    static let marks: Set<String> = ["bar", "line", "area", "point", "circle", "square", "tick", "rect", "rule", "text",
                                     "trail", "arc"]
    static let channels: Set<String> = ["x", "y", "x2", "y2", "color", "fill", "stroke", "opacity", "size", "shape",
                                        "theta", "radius", "text", "tooltip", "detail", "order", "strokeDash", "xOffset",
                                        "yOffset", "angle", "key", "href", "description"]
    static let types: Set<String> = ["quantitative", "nominal", "ordinal", "temporal"]
    static let keep: Set<String> = ["mark", "encoding", "title", "width", "height", "description", "config", "autosize",
                                    "padding", "background", "transform", "params", "name"]

    public static func isNumeric(_ type: String) -> Bool {
        let t = type.uppercased()
        return ["TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT", "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT",
                "FLOAT", "DOUBLE", "REAL"].contains(t) || t.hasPrefix("DECIMAL")
    }

    static func isTemporal(_ type: String) -> Bool {
        let t = type.uppercased()
        return t == "DATE" || t.hasPrefix("TIMESTAMP")
    }

    /// The result is already aggregated (GROUP BY / an aggregate function over the whole table).
    public static func isGrouped(_ ref: DataRef) -> Bool {
        ref.sql.range(of: #"\bgroup\s+by\b|\b(sum|avg|count|min|max|median)\s*\("#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    struct Columns {
        let ref: DataRef
        func type(_ c: String) -> String { ref.columns.firstIndex(of: c).map { $0 < ref.types.count ? ref.types[$0] : "VARCHAR" } ?? "VARCHAR" }
        var label: String? { ref.columns.first { !isNumeric(type($0)) } ?? ref.columns.first }
        var numeric: [String] { ref.columns.filter { isNumeric(type($0)) } }
        func vlType(_ c: String) -> String { isNumeric(type(c)) ? "quantitative" : isTemporal(type(c)) ? "temporal" : "nominal" }
        func has(_ c: String?) -> Bool { c.map { ref.columns.contains($0) } ?? false }
    }

    static func markType(_ mark: Any?) -> String? {
        if let s = mark as? String { return s }
        return (mark as? [String: Any])?["type"] as? String
    }

    /// The spec redrawn to plot `ref`'s rows as they are (see the header).
    public static func repair(_ input: [String: Any], ref: DataRef) -> [String: Any] {
        let cols = Columns(ref: ref)
        let grouped = isGrouped(ref)
        var s = input
        // One view: the first layer / concat member when the top level has no mark.
        if s["mark"] == nil {
            for key in ["layer", "hconcat", "vconcat", "concat"] {
                if let first = (s[key] as? [[String: Any]])?.first(where: { $0["mark"] != nil }) {
                    s["mark"] = first["mark"]
                    if s["encoding"] == nil { s["encoding"] = first["encoding"] }
                    break
                }
            }
            if s["mark"] == nil, let inner = s["spec"] as? [String: Any] {
                s["mark"] = inner["mark"]
                if s["encoding"] == nil { s["encoding"] = inner["encoding"] }
            }
        }
        s = s.filter { keep.contains($0.key) }
        if grouped { s["transform"] = nil }
        // Mark: a known type; `mark.encoding` and channel-like mark keys move into `encoding`.
        var encoding = (s["encoding"] as? [String: Any]) ?? [:]
        let markType = markType(s["mark"]).flatMap { marks.contains($0) ? $0 : nil } ?? "bar"
        if var m = s["mark"] as? [String: Any] {
            if let inner = m["encoding"] as? [String: Any] {
                for (k, v) in inner where encoding[k] == nil { encoding[k] = v }
                m["encoding"] = nil
            }
            for k in Array(m.keys) where channels.contains(k) && (m[k] as? [String: Any])?["field"] != nil {
                if encoding[k] == nil { encoding[k] = m[k] }
                m[k] = nil
            }
            m["type"] = markType
            s["mark"] = m
        } else {
            s["mark"] = markType
        }
        // Channels: dictionaries (tooltip may be a list); fields must be columns.
        var out: [String: Any] = [:]
        for (k, v) in encoding where channels.contains(k) {
            if k == "tooltip" {
                if let list = v as? [[String: Any]] {
                    let ok = list.filter { cols.has($0["field"] as? String) }.map { t -> [String: Any] in
                        var t = t; t["aggregate"] = nil; t["bin"] = nil; return t
                    }
                    if !ok.isEmpty { out[k] = ok }
                }
                continue
            }
            guard var ch = v as? [String: Any] else { continue }
            if let agg = ch["aggregate"] as? [String: Any], ch["field"] == nil { ch["field"] = agg["field"] }
            if grouped { ch["aggregate"] = nil; ch["bin"] = nil; ch["timeUnit"] = nil }
            if !cols.has(ch["field"] as? String) {
                guard k == "x" || k == "y" || k == "theta" else { continue }
                ch["field"] = nil
            }
            out[k] = ch
        }
        // Positions: the label column on the categorical axis, the first unused number on the value axis.
        let used = Set(out.values.compactMap { ($0 as? [String: Any])?["field"] as? String })
        let value = cols.numeric.first { !used.contains($0) } ?? cols.numeric.first
        func fill(_ k: String, wantNumber: Bool) {
            var ch = (out[k] as? [String: Any]) ?? [:]
            if ch["field"] == nil { ch["field"] = wantNumber ? value : cols.label }
            if ch["field"] == nil { out[k] = nil; return }
            out[k] = ch
        }
        if markType == "arc" {
            fill("theta", wantNumber: true)
            if out["color"] == nil, let l = cols.label { out["color"] = ["field": l] }
            out["x"] = nil; out["y"] = nil
        } else {
            let xNumeric = (out["x"] as? [String: Any])?["field"].flatMap { $0 as? String }.map { isNumeric(cols.type($0)) }
            let yNumeric = (out["y"] as? [String: Any])?["field"].flatMap { $0 as? String }.map { isNumeric(cols.type($0)) }
            // Horizontal bars when the model put the number on x.
            let horizontal = xNumeric == true || yNumeric == false
            fill("x", wantNumber: horizontal)
            fill("y", wantNumber: !horizontal)
        }
        // Types from the columns (a number shown as quantitative, a date as temporal, text as nominal / ordinal).
        for (k, v) in out {
            guard var ch = v as? [String: Any], let f = ch["field"] as? String else { continue }
            let natural = cols.vlType(f)
            let given = ch["type"] as? String
            if given == nil || !types.contains(given!) || (natural == "quantitative") != (given == "quantitative") {
                ch["type"] = natural
            }
            if grouped, let sort = ch["sort"], !(sort is String) && !(sort is [Any]) && !(sort is NSNull) {
                if let d = sort as? [String: Any], d["op"] != nil || d["field"] != nil { ch["sort"] = nil }
            }
            out[k] = ch
        }
        s["encoding"] = out
        for k in ["width", "height"] {
            if let v = s[k], !(v is NSNumber), !((v as? [String: Any])?["step"] is NSNumber) { s[k] = nil }
        }
        if s["title"] != nil, !(s["title"] is String), (s["title"] as? [String: Any])?["text"] == nil { s["title"] = nil }
        return s
    }

    /// A plain chart of the rows: the requested mark (bar by default), label column × first numeric column.
    public static func fallback(_ spec: [String: Any], ref: DataRef, title: String) -> [String: Any] {
        let cols = Columns(ref: ref)
        let mark = markType(spec["mark"]).flatMap { ["bar", "line", "area", "point"].contains($0) ? $0 : nil } ?? "bar"
        var enc: [String: Any] = [:]
        if let l = cols.label { enc["x"] = ["field": l, "type": cols.vlType(l) == "quantitative" ? "nominal" : cols.vlType(l), "sort": NSNull()] }
        if let v = cols.numeric.first(where: { $0 != cols.label }) ?? cols.numeric.first { enc["y"] = ["field": v, "type": "quantitative"] }
        return ["mark": mark, "encoding": enc, "title": title]
    }

    /// The spec object in a model's spec string: strict JSON first; else the brackets repaired — a closer that skips
    /// open containers closes them, a closer with nothing to close is dropped, the text after the root object is ignored
    /// and unclosed containers are closed at the end (AT-274 T1 runs: extra and missing braces around nested layers).
    public static func firstObject(_ text: String) -> [String: Any]? {
        if let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { return o }
        var out = ""
        var stack: [Character] = []
        var inString = false, escaped = false, started = false
        loop: for c in text {
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"":
                guard started else { continue }
                inString = true
                out.append(c)
            case "{", "[":
                if !started { guard c == "{" else { continue }; started = true }
                stack.append(c == "{" ? "}" : "]")
                out.append(c)
            case "}", "]":
                guard started, stack.contains(c) else { continue }  // nothing to close: dropped
                while let top = stack.popLast() {
                    // A dangling comma before an auto-closed container is not JSON.
                    while out.last == "," || out.last == " " { out.removeLast() }
                    out.append(top)
                    if top == c { break }
                }
                if stack.isEmpty { break loop }
            default:
                if started { out.append(c) }
            }
        }
        if inString { out.append("\"") }
        while let top = stack.popLast() {
            while out.last == "," || out.last == " " || out.last == ":" { out.removeLast() }
            out.append(top)
        }
        return (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
    }
}
