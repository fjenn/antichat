// M6.T10 steps 1–4 (R-273 AC1/AC2/AC4): `create_spreadsheet` (XLSX via libxlsxwriter, CSV per RFC 4180) and
// `export_table` (a query_data result → the same cards). Validation = schema + semantics (a CSV has one sheet and no
// formulas or charts; a data_ref must exist in this chat; a sheet whose columns repeat a query result must use that
// data_ref; formula / chart ranges are cell refs; `revises` names a file of this chat) → the one repair turn. No model,
// no network, no process: the writer is in-process C.
import Foundation

public enum CreateSpreadsheetTool {
    public static let name = SpreadsheetSchemas.createName

    public static func problems(argumentsJSON: String, refs: (String) -> DataRef?, chatRefs: [DataRef] = [],
                                revisesProblem: (String?) -> String? = { _ in nil }) -> [String] {
        var out = SpecValidator.problems(json: argumentsJSON, schemaJSON: SpreadsheetSchemas.createJSON)
        guard out.isEmpty else { return out }
        let spec: SpreadsheetSpec
        do { spec = try SpreadsheetSpec.parse(argumentsJSON, refs: refs) } catch let FileOutError.invalidSpec(p) { return p } catch {
            return ["$: \(error)"]
        }
        if let p = revisesProblem(spec.revises) { out.append(p) }
        // AT-273 (T05 xlsx-18 / csv-24: sheets with a name and nothing else): an empty file is not what was asked for.
        if spec.sheets.allSatisfy({ $0.columns.isEmpty && $0.rows.isEmpty && $0.dataRef == nil }) {
            out.append("$.sheets: every sheet is empty; give the sheet columns and rows with the content the user asked for"
                       + " (when the user gave no data, write realistic example rows that fit the request yourself)")
        }
        if spec.format == .csv {
            if spec.sheets.count != 1 { out.append("$.sheets: a CSV file has exactly one sheet (got \(spec.sheets.count))") }
            if spec.sheets.contains(where: { !$0.formulas.isEmpty }) { out.append("$.sheets[0].formulas: CSV cannot hold formulas; use xlsx") }
            if spec.sheets.contains(where: { $0.chart != nil }) { out.append("$.sheets[0].chart: CSV cannot hold a chart; use xlsx") }
        }
        let raw = ((try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any])?["sheets"] as? [[String: Any]] ?? []
        for (i, s) in raw.enumerated() where s["rows"] != nil && s["data_ref"] != nil {
            out.append("$.sheets[\(i)]: give either rows or data_ref, not both")
        }
        for (i, s) in spec.sheets.enumerated() {
            if s.dataRef == nil, !s.rows.isEmpty {
                let headers = s.columns.map { $0.header.lowercased() }
                if let ref = chatRefs.first(where: { $0.columns.count >= 2 && $0.columns.map { $0.lowercased() } == headers }) {
                    out.append("$.sheets[\(i)].rows: these columns are the query result \(ref.id); pass \"data_ref\": \"\(ref.id)\" instead of typing the values")
                }
            }
            for ref in s.formulas.keys where XLSXWriter.cell(ref) == nil { out.append("$.sheets[\(i)].formulas: \"\(ref)\" is not a cell like B14") }
            if let c = s.chart {
                for r in [c.categories] + c.values where !Self.isRange(r) {
                    out.append("$.sheets[\(i)].chart: \"\(r)\" is not a cell range like A2:A13")
                }
            }
        }
        return out
    }

    static func isRange(_ r: String) -> Bool {
        let body = r.split(separator: "!").last.map(String.init) ?? r
        let parts = body.split(separator: ":")
        return (1...2).contains(parts.count) && parts.allSatisfy { XLSXWriter.cell(String($0)) != nil }
    }

    public static func render(_ spec: SpreadsheetSpec) throws -> Data {
        if spec.format == .xlsx { return try XLSXWriter.render(spec) }
        guard let s = spec.sheets.first else { throw FileOutError.invalidSpec(["$.sheets: empty"]) }
        return CSVWriter.render(s)
    }

    public static func run(argumentsJSON: String, chatID: String, messageID: String?, store: ArtifactStore,
                           refs: (String) -> DataRef?) throws -> String {
        let spec = try SpreadsheetSpec.parse(argumentsJSON, refs: refs)
        let data = try render(spec)
        return try save(data, spec: spec, specJSON: argumentsJSON, chatID: chatID, messageID: messageID, store: store)
    }

    static func save(_ data: Data, spec: SpreadsheetSpec, specJSON: String, chatID: String, messageID: String?,
                     store: ArtifactStore) throws -> String {
        let saved = try store.save(chatID: chatID, kind: spec.format.rawValue, filename: spec.outputName, data: data,
                                   specJSON: specJSON, messageID: messageID, revises: spec.revises)
        let chain = saved.version > 1 ? VersioningService(store: store).versions(of: saved.artifactID) : []
        return FileOutResult.text(saved, format: spec.format.rawValue, pages: nil, versions: chain)
    }
}

public enum ExportTableTool {
    public static let name = SpreadsheetSchemas.exportName

    public static func problems(argumentsJSON: String, refs: (String) -> DataRef?,
                                revisesProblem: (String?) -> String? = { _ in nil }) -> [String] {
        var out = SpecValidator.problems(json: argumentsJSON, schemaJSON: SpreadsheetSchemas.exportJSON)
        guard out.isEmpty, let o = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] else { return out }
        if let id = o["data_ref"] as? String, refs(id) == nil { out.append("$.data_ref: no query result \"\(id)\" in this chat") }
        if let p = revisesProblem(o["revises"] as? String) { out.append(p) }
        return out
    }

    /// The export as a one-sheet spreadsheet spec.
    public static func spec(_ argumentsJSON: String, refs: (String) -> DataRef?) throws -> (SpreadsheetSpec, String) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any],
              let id = o["data_ref"] as? String, let ref = refs(id) else {
            throw FileOutError.invalidSpec(["$.data_ref: no such query result"])
        }
        let format = SpreadsheetSpec.Format(rawValue: o["format"] as? String ?? "csv") ?? .csv
        let columns = SpreadsheetSpec.columns(of: ref)
        let sheet = SheetSpec(name: "Data", columns: columns, rows: SpreadsheetSpec.rows(of: ref, columns: columns), dataRef: id,
                              formulas: [:], freezeHeader: true, autofilter: true, columnWidths: nil, chart: nil)
        let spec = SpreadsheetSpec(filename: o["filename"] as? String ?? "Export", format: format, sheets: [sheet],
                                   revises: o["revises"] as? String)
        return (spec, id)
    }

    public static func run(argumentsJSON: String, chatID: String, messageID: String?, store: ArtifactStore,
                           refs: (String) -> DataRef?) throws -> String {
        let (spec, _) = try spec(argumentsJSON, refs: refs)
        let data = try CreateSpreadsheetTool.render(spec)
        return try CreateSpreadsheetTool.save(data, spec: spec, specJSON: argumentsJSON, chatID: chatID, messageID: messageID, store: store)
    }
}
