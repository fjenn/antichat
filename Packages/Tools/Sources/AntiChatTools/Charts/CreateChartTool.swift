// M6.T12 (R-274 AC1–AC3, D-07): `create_chart {title, vega_lite_spec, data_ref?}`. When the chat has sheet or query data
// (or the spec's fields name a loaded table's columns), the numbers must come from the file: `data_ref` is required and
// inline `data.values` are rejected with `chart.modelData` (AC1). The host injects the query result's exact rows into
// `spec.data.values`, compiles and renders headless in RenderHost (VegaRenderer: SVG + PNG@2x, no network, AC2), and
// stores artifact kind `chart` — the PNG as the file, `spec_json` = the injected spec + the data_ref rows + the SVG,
// so the chart (and View data) survive the chat's DuckDB being freed. Without file data (numbers from the
// conversation), inline values are allowed. Model tolerance (AT-274 T1 run: 0/5 before): a spec sent as a JSON string
// is parsed; a spec without data_ref whose fields are all columns of one of the chat's query results binds to the newest
// such result — its typed-in values are dropped, never plotted.
import Foundation

public enum ChartSchemas {
    public static let name = "create_chart"
    public static let description = """
        Draw a chart inline in the chat from a Vega-Lite v6 spec (bar, line, area, point, arc/pie, heatmap…). When the data \
        comes from an attached sheet or a query_data result, pass that result's `data_ref` and leave `data.values` out of \
        the spec — the app injects the exact rows; encode the result's column names as fields and do not re-aggregate a \
        grouped result. Only for numbers the user typed in the conversation may the spec carry inline `data.values`. \
        To change a chart you made earlier, pass its artifact_id as `revises`. Runs on this Mac; nothing is uploaded.
        """
    public static let json = #"{"type":"object","properties":{"title":{"type":"string","minLength":1,"maxLength":200},"vega_lite_spec":{"type":"object"},"data_ref":{"type":"string","description":"the data_ref of a query_data result in this chat"},"revises":{"type":"string","description":"artifact_id of a chart made earlier in this chat that this replaces with a new version"}},"required":["title","vega_lite_spec"],"additionalProperties":false}"#

    /// `chart.modelData` (copy deck): the tool error a model-typed spec gets when the chat has file data.
    public static let modelDataText = "Charts use the numbers from your file, not typed-in values."
}

/// What `spec_json` of a chart artifact version holds (the ChartCard's Save SVG and View data read it back).
public struct ChartSnapshot: Codable, Sendable, Equatable {
    public var title: String
    public var data_ref: String?
    public var columns: [String]
    public var rows: [[String?]]
    /// The rendered spec, with the injected values.
    public var spec: String
    public var svg: String

    public init(title: String, data_ref: String?, columns: [String], rows: [[String?]], spec: String, svg: String) {
        self.title = title; self.data_ref = data_ref; self.columns = columns; self.rows = rows; self.spec = spec; self.svg = svg
    }

    /// The snapshot file beside the chart's PNG (same name, .chart.json).
    public static func sidecar(for png: URL) -> URL { png.deletingPathExtension().appendingPathExtension("chart.json") }

    public static func load(png: URL) -> ChartSnapshot? {
        (try? Data(contentsOf: sidecar(for: png))).flatMap { try? JSONDecoder().decode(ChartSnapshot.self, from: $0) }
    }

    public static func decode(_ json: String) -> ChartSnapshot? { try? JSONDecoder().decode(ChartSnapshot.self, from: Data(json.utf8)) }
}

public enum CreateChartTool {
    public static let name = ChartSchemas.name

    /// Validator → the repair turn. `chatRefs` are the chat's query results; `tableColumns` the loaded sheets' columns.
    /// Tolerated shapes (T1 models send them; AT-274 runs): `vega_lite_spec` as a JSON string → the object; the result
    /// handle named inside the spec (`data: {name: "qr_…"}`, `data: {url: "qr_…"}`, nested deeper in `data`, or `data_ref` as a spec key) with no
    /// top-level `data_ref` → `data_ref`, the spec's `data` dropped (the host injects the rows). Anything else as sent.
    public static func normalized(_ argumentsJSON: String) -> String {
        guard var o = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] else {
            return argumentsJSON
        }
        var changed = false
        if let str = o["vega_lite_spec"] as? String, let spec = ChartSpecRepair.firstObject(str) {
            o["vega_lite_spec"] = spec
            changed = true
        }
        if o["data_ref"] == nil, var spec = o["vega_lite_spec"] as? [String: Any] {
            let isRef = { (v: Any?) -> String? in (v as? String).flatMap { $0.hasPrefix("qr_") ? $0 : nil } }
            if let id = isRef(spec["data_ref"]) {
                o["data_ref"] = id
                spec["data_ref"] = nil
                if let d = spec["data"] as? [String: Any], d["values"] == nil { spec["data"] = nil }
                o["vega_lite_spec"] = spec
                changed = true
            } else if let d = spec["data"] as? [String: Any], d["values"] == nil, let id = Self.nestedRef(d) {
                o["data_ref"] = id
                spec["data"] = nil
                o["vega_lite_spec"] = spec
                changed = true
            }
        }
        // A data_ref call that also typed the numbers in: the typed values are dropped, the result's rows are plotted
        // (A-M6-T12a: bind to the file's numbers, never plot typed ones).
        if o["data_ref"] is String, var spec = o["vega_lite_spec"] as? [String: Any],
           let d = spec["data"] as? [String: Any], d["values"] != nil {
            spec["data"] = nil
            o["vega_lite_spec"] = spec
            changed = true
        }
        guard changed, let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return argumentsJSON }
        return String(decoding: data, as: UTF8.self)
    }

    /// M6.T21 (AT-274 sc-14 on the merged head: `data: {external: {name: "qr_…"}}`): the one result handle named anywhere
    /// inside the spec's `data` object (`name`, `url`, or nested one level deeper or more); nil when none or several differ.
    static func nestedRef(_ data: [String: Any]) -> String? {
        var found: Set<String> = []
        func walk(_ v: Any) {
            if let s = v as? String, s.hasPrefix("qr_") { found.insert(s) }
            else if let d = v as? [String: Any] { d.values.forEach(walk) }
            else if let a = v as? [Any] { a.forEach(walk) }
        }
        walk(data)
        return found.count == 1 ? found.first : nil
    }

    /// The newest query result whose columns hold every field the spec names (nil when none or no fields).
    public static func implicitRef(_ spec: Any, chatRefs: [DataRef]) -> DataRef? {
        let fields = ChartSpecHelpers.fields(in: spec)
        guard !fields.isEmpty else { return nil }
        return chatRefs.last { fields.isSubset(of: Set($0.columns)) }
    }

    public static func problems(argumentsJSON raw: String, refs: (String) -> DataRef?, chatRefs: [DataRef] = [],
                                tableColumns: [[String]] = [], revisesProblem: (String?) -> String? = { _ in nil }) -> [String] {
        let argumentsJSON = normalized(raw)
        var out = SpecValidator.problems(json: argumentsJSON, schemaJSON: ChartSchemas.json)
        guard out.isEmpty, let o = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any],
              let spec = o["vega_lite_spec"] as? [String: Any] else { return out }
        if let p = revisesProblem(o["revises"] as? String) { out.append(p) }
        if ChartSpecHelpers.hasURLData(spec) { out.append("$.vega_lite_spec.data.url: charts cannot load URLs; use data_ref") }
        let fields = ChartSpecHelpers.fields(in: spec)
        let inline = ChartSpecHelpers.hasInlineValues(spec)
        if let id = o["data_ref"] as? String {
            // Typed values next to a data_ref are dropped by `normalized`; fields that are not columns and a re-aggregated
            // grouped result are redrawn by ChartSpecRepair (the rows are plotted as they are).
            if refs(id) == nil { out.append("$.data_ref: no query result \"\(id)\" in this chat") }
        } else if implicitRef(spec, chatRefs: chatRefs) != nil {
            // Bound to the chat's newest matching result at run time; inline values are dropped.
        } else {
            let lowerFields = Set(fields.map { $0.lowercased() })
            let matchesTable = !lowerFields.isEmpty && (tableColumns + chatRefs.map(\.columns)).contains { cols in
                lowerFields.isSubset(of: Set(cols.map { $0.lowercased() }))
            }
            if !chatRefs.isEmpty || !tableColumns.isEmpty || matchesTable {
                let hint = chatRefs.isEmpty ? "Run query_data first, then pass its result's data_ref"
                    : "Pass a query result's data_ref (\(chatRefs.suffix(3).map(\.id).joined(separator: ", "))) or encode that result's column names"
                out.append("$.data_ref: \(ChartSchemas.modelDataText) \(hint), and leave data.values out.")
            } else if !inline {
                out.append("$.vega_lite_spec.data: give the values (data.values) or a data_ref")
            }
        }
        return out
    }

    /// The spec with `data_ref`'s rows injected (and a title when it has none), as JSON.
    public static func injectedSpec(_ argumentsJSON: String, refs: (String) -> DataRef?, chatRefs: [DataRef] = []) throws
        -> (spec: String, ref: DataRef?, title: String) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(normalized(argumentsJSON).utf8))) as? [String: Any],
              var spec = o["vega_lite_spec"] as? [String: Any], let title = o["title"] as? String else {
            throw FileOutError.invalidSpec(["$: needs title and vega_lite_spec"])
        }
        var ref: DataRef?
        if let id = o["data_ref"] as? String {
            guard let r = refs(id) else { throw FileOutError.invalidSpec(["$.data_ref: no query result \"\(id)\""]) }
            ref = r
        } else if let r = implicitRef(spec, chatRefs: chatRefs) {
            ref = r
        }
        if let r = ref {
            spec = ChartSpecRepair.repair(spec, ref: r)
            spec["data"] = ["values": ChartSpecHelpers.records(r)]
        }
        if spec["title"] == nil { spec["title"] = title }
        spec["$schema"] = nil
        let data = try JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys, .withoutEscapingSlashes])
        return (String(decoding: data, as: UTF8.self), ref, title)
    }

    /// The table of a spec's inline `data.values` records: columns by name (JSON objects carry no order), cells as text (whole numbers
    /// without ".0"); nil when the spec has no inline records.
    static func inlineTable(specJSON: String) -> (columns: [String], rows: [[String?]])? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(specJSON.utf8))) as? [String: Any],
              let records = (o["data"] as? [String: Any])?["values"] as? [[String: Any]], !records.isEmpty else { return nil }
        var columns: [String] = []
        for r in records { for k in r.keys.sorted() where !columns.contains(k) { columns.append(k) } }
        func text(_ v: Any?) -> String? {
            switch v {
            case nil, is NSNull: return nil
            case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return n.boolValue ? "true" : "false"
            case let n as NSNumber:
                let d = n.doubleValue
                return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
            case let s as String: return s
            default: return "\(v!)"
            }
        }
        return (columns, records.map { r in columns.map { text(r[$0]) } })
    }

    @MainActor
    public static func run(argumentsJSON: String, chatID: String, messageID: String?, store: ArtifactStore,
                           refs: (String) -> DataRef?, chatRefs: [DataRef] = [], host: RenderHost = .shared) async throws -> String {
        var (spec, ref, title) = try injectedSpec(argumentsJSON, refs: refs, chatRefs: chatRefs)
        let rendered: ChartRender
        do {
            rendered = try await VegaRenderer.render(specJSON: spec, host: host)
        } catch {
            // A file-bound chart whose (repaired) drawing still fails: the same rows as a plain chart of its mark.
            guard let r = ref, let o = (try? JSONSerialization.jsonObject(with: Data(spec.utf8))) as? [String: Any] else { throw error }
            var plain = ChartSpecRepair.fallback(o, ref: r, title: title)
            plain["data"] = ["values": ChartSpecHelpers.records(r)]
            spec = String(decoding: try JSONSerialization.data(withJSONObject: plain, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            rendered = try await VegaRenderer.render(specJSON: spec, host: host)
        }
        let o = (try? JSONSerialization.jsonObject(with: Data(normalized(argumentsJSON).utf8))) as? [String: Any]
        // Q-015 r3: a chart whose values the model wrote into the spec (no data_ref) had no table, so View data stayed
        // disabled; its inline `data.values` records are the table.
        let inline = ref == nil ? inlineTable(specJSON: spec) : nil
        let snapshot = ChartSnapshot(title: title, data_ref: ref?.id, columns: ref?.columns ?? inline?.columns ?? [],
                                     rows: ref?.rows ?? inline?.rows ?? [], spec: spec, svg: rendered.svg)
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let saved = try store.save(chatID: chatID, kind: "chart", filename: FileOutNames.filename(title: title, ext: "png"),
                                   data: rendered.png, specJSON: String(decoding: try e.encode(snapshot), as: UTF8.self),
                                   messageID: messageID, revises: o?["revises"] as? String)
        // The ChartCard (Save SVG, View data) reads this sidecar next to the PNG; it lives where the PNG lives (the
        // incognito temp dir for an incognito chat) and holds the same snapshot as spec_json.
        try? e.encode(snapshot).write(to: ChartSnapshot.sidecar(for: URL(fileURLWithPath: saved.path)), options: .atomic)
        let chain = saved.version > 1 ? VersioningService(store: store).versions(of: saved.artifactID) : []
        let first = FileOutResult.text(saved, format: "chart", pages: nil, versions: chain).split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "{}"
        let rows = ref.map { " from \($0.rows.count) row\($0.rows.count == 1 ? "" : "s") of \($0.id)" } ?? ""
        return first + "\nDrew the chart \"\(title)\"\(rows). The user sees it inline with Save PNG, Save SVG, Copy and View data; do not repeat the numbers unless asked. To change it, call create_chart again with revises: \"\(saved.artifactID)\"."
    }
}
