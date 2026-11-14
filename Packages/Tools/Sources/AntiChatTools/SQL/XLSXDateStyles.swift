// M6.T07 (R-272 AC1 "dates typed correctly"): the vendored `XLSXAdapter` keeps scalar values only (no styles), and XLSX
// stores dates as serial numbers plus a date number format. This pass reads `xl/styles.xml` (numFmts + cellXfs), the
// workbook's sheet → part map and each worksheet's `<c r=… s=…>` attributes, and returns the date-formatted cells per
// sheet; `apply` turns those numbers into ISO text (`SpreadsheetDates`) before type inference.
import AntiChatFoundation
import AntiChatStorage
import Foundation
import OsaurusVendored

enum XLSXDateStyles {
    /// sheet name → cell reference → date kind; plus the workbook's 1904 flag.
    struct Result { var cells: [String: [String: SpreadsheetDates.Kind]] = [:]; var is1904 = false }

    static func dateCells(xlsx data: Data) throws -> Result {
        // The shared bounded reader (M6 review #2): every part is capped by what it actually inflates to.
        let zip = try BoundedZip(data: data)
        func part(_ path: String) throws -> Data? { try zip.data(path) }
        var out = Result()
        guard let styles = try part("xl/styles.xml"), let workbook = try part("xl/workbook.xml") else { return out }
        let st = StylesParser.parse(styles)
        let xfKinds = st.xfFormats.map { SpreadsheetDates.kind(formatID: $0, code: st.formats[$0]) }
        guard xfKinds.contains(where: { $0 != nil }) else { return out }
        let wb = WorkbookParser.parse(workbook)
        out.is1904 = wb.is1904
        let rels = try part("xl/_rels/workbook.xml.rels").map(RelsParser.parse) ?? [:]
        for (name, rid) in wb.sheets {
            guard let target = rels[rid] else { continue }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            guard let sheet = try part(path) else { continue }
            let dates = CellStyleParser.parse(sheet, kinds: xfKinds)
            if !dates.isEmpty { out.cells[name] = dates }
        }
        return out
    }

    static func apply(_ r: Result, to wb: Workbook) -> Workbook {
        guard !r.cells.isEmpty else { return wb }
        let sheets = wb.sheets.map { sheet -> Workbook.Sheet in
            guard let dates = r.cells[sheet.name] else { return sheet }
            let rows = sheet.rows.map { row in
                Workbook.Row(number: row.number, cells: row.cells.map { c in
                    guard case .number(let d) = c.value, let k = dates[c.reference],
                          let iso = SpreadsheetDates.iso(serial: d, kind: k, is1904: r.is1904) else { return c }
                    return Workbook.Cell(reference: c.reference, rowNumber: c.rowNumber, columnNumber: c.columnNumber,
                                         value: .string(iso), formula: c.formula, anchor: c.anchor)
                }, anchor: row.anchor)
            }
            return Workbook.Sheet(name: sheet.name, index: sheet.index, rows: rows, mergedRanges: sheet.mergedRanges,
                                  anchor: sheet.anchor)
        }
        return Workbook(sheets: sheets, sharedStrings: wb.sharedStrings)
    }

    // MARK: parsers (local names: prefixes are ignored)

    final class StylesParser: NSObject, XMLParserDelegate {
        var formats: [Int: String] = [:]
        var xfFormats: [Int] = []
        private var inCellXfs = false
        static func parse(_ d: Data) -> StylesParser {
            let p = StylesParser(); let x = XMLParser(data: d); x.delegate = p; x.parse(); return p
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String] = [:]) {
            switch local(name) {
            case "numFmt": if let id = a["numFmtId"].flatMap(Int.init), let code = a["formatCode"] { formats[id] = code }
            case "cellXfs": inCellXfs = true
            case "xf" where inCellXfs: xfFormats.append(a["numFmtId"].flatMap(Int.init) ?? 0)
            default: break
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if local(name) == "cellXfs" { inCellXfs = false }
        }
    }

    final class WorkbookParser: NSObject, XMLParserDelegate {
        var sheets: [(String, String)] = []
        var is1904 = false
        static func parse(_ d: Data) -> WorkbookParser {
            let p = WorkbookParser(); let x = XMLParser(data: d); x.delegate = p; x.parse(); return p
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String] = [:]) {
            switch local(name) {
            case "sheet":
                if let n = a["name"], let rid = a.first(where: { local($0.key) == "id" && $0.key != "sheetId" })?.value {
                    sheets.append((n, rid))
                }
            case "workbookPr": is1904 = ["1", "true"].contains(a["date1904"] ?? "")
            default: break
            }
        }
    }

    final class RelsParser: NSObject, XMLParserDelegate {
        var map: [String: String] = [:]
        static func parse(_ d: Data) -> [String: String] {
            let p = RelsParser(); let x = XMLParser(data: d); x.delegate = p; x.parse(); return p.map
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String] = [:]) {
            if local(name) == "Relationship", let id = a["Id"], let t = a["Target"] { map[id] = t }
        }
    }

    final class CellStyleParser: NSObject, XMLParserDelegate {
        let kinds: [SpreadsheetDates.Kind?]
        var out: [String: SpreadsheetDates.Kind] = [:]
        init(kinds: [SpreadsheetDates.Kind?]) { self.kinds = kinds }
        static func parse(_ d: Data, kinds: [SpreadsheetDates.Kind?]) -> [String: SpreadsheetDates.Kind] {
            let p = CellStyleParser(kinds: kinds); let x = XMLParser(data: d); x.delegate = p; x.parse(); return p.out
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String] = [:]) {
            guard name == "c" || local(name) == "c", let r = a["r"], let s = a["s"].flatMap(Int.init),
                  s >= 0, s < kinds.count, let k = kinds[s] else { return }
            if let t = a["t"], t != "n" { return }  // strings/bools/errors keep their type
            out[r] = k
        }
    }
}

private func local(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }
