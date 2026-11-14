// M6.T07 (A-M6-10, R-272 AC1 XLS): legacy BIFF `.xls` → the same `Workbook` model the vendored `XLSXAdapter` returns, via
// vendored libxls (Vendor/libxls@93f1ad5, reached through CLibXLSBridge). Cells keep their scalar type; numbers whose
// XF format is a date/time come out as ISO text (`SpreadsheetDates`), so intake Markdown and DuckDB (SheetLoader) read
// dates, not serials. Formula cells carry their cached value (libxls does not keep formula text).
import AntiChatFoundation
import CLibXLSBridge
import Foundation
import OsaurusVendored

public enum XLSAdapterError: Error, Equatable, Sendable {
    case open(String)
    case encrypted
    case empty
}

public enum XLSAdapter {
    // BIFF record ids libxls stores in `cell.id`.
    static let formula: UInt16 = 0x0006, formulaAlt: UInt16 = 0x0406, boolErr: UInt16 = 0x0205
    static let blank: UInt16 = 0x0201, mulBlank: UInt16 = 0x00BE
    static let number: UInt16 = 0x0203, rk: UInt16 = 0x027E, mulRK: UInt16 = 0x00BD

    public static func workbook(url: URL) throws -> Workbook {
        var err = LIBXLS_OK
        guard let wb = xls_open_file(url.path, "UTF-8", &err) else {
            if err == LIBXLS_ERROR_UNSUPPORTED_ENCRYPTION { throw XLSAdapterError.encrypted }
            throw XLSAdapterError.open(String(cString: xls_getError(err)))
        }
        defer { xls_close_WB(wb) }
        let is1904 = acx_xls_is1904(wb) != 0
        var sheets: [Workbook.Sheet] = []
        for i in 0..<Int(wb.pointee.sheets.count) {
            let name = wb.pointee.sheets.sheet[i].name.map { String(cString: $0) } ?? "Sheet\(i + 1)"
            guard let ws = xls_getWorkSheet(wb, Int32(i)) else { continue }
            defer { xls_close_WS(ws) }
            guard xls_parseWorkSheet(ws) == LIBXLS_OK else { continue }
            sheets.append(sheet(ws, wb: wb, name: name, index: i, is1904: is1904))
        }
        guard sheets.contains(where: { !$0.rows.isEmpty }) else { throw XLSAdapterError.empty }
        return Workbook(sheets: sheets)
    }

    static func sheet(_ ws: UnsafeMutablePointer<xlsWorkSheet>, wb: UnsafeMutablePointer<xlsWorkBook>, name: String,
                      index: Int, is1904: Bool) -> Workbook.Sheet {
        let sheetAnchor = DocumentAnchor(kind: .sheet, path: [.init(kind: .document), .init(kind: .sheet, identifier: name, index: index)],
                                         label: name)
        var rows: [Workbook.Row] = []
        guard ws.pointee.rows.row != nil else {
            return Workbook.Sheet(name: name, index: index, rows: [], anchor: sheetAnchor)
        }
        let lastRow = Int(ws.pointee.rows.lastrow), lastCol = Int(ws.pointee.rows.lastcol)
        var kinds: [UInt16: SpreadsheetDates.Kind?] = [:]  // xf → date kind
        for r in 0...lastRow {
            let row = ws.pointee.rows.row[r]
            guard let cellsPtr = row.cells.cell else { continue }
            var cells: [Workbook.Cell] = []
            for c in 0..<min(Int(row.cells.count), lastCol + 1) {
                let cell = cellsPtr[c]
                let value = value(cell, wb: wb, is1904: is1904, kinds: &kinds)
                if value == .empty { continue }
                let ref = reference(column: c + 1, row: r + 1)
                cells.append(Workbook.Cell(
                    reference: ref, rowNumber: r + 1, columnNumber: c + 1, value: value,
                    anchor: DocumentAnchor(kind: .cell, path: [.init(kind: .document), .init(kind: .sheet, identifier: name, index: index),
                                                              .init(kind: .cell, identifier: ref)],
                                           label: "\(name)!\(ref)")))
            }
            guard !cells.isEmpty else { continue }
            rows.append(Workbook.Row(number: r + 1, cells: cells,
                                     anchor: DocumentAnchor(kind: .row, path: [.init(kind: .document),
                                                                              .init(kind: .sheet, identifier: name, index: index),
                                                                              .init(kind: .row, index: r)])))
        }
        return Workbook.Sheet(name: name, index: index, rows: rows, anchor: sheetAnchor)
    }

    static func value(_ cell: xlsCell, wb: UnsafeMutablePointer<xlsWorkBook>, is1904: Bool,
                      kinds: inout [UInt16: SpreadsheetDates.Kind?]) -> Workbook.CellValue {
        let id = cell.id
        if id == blank || id == mulBlank { return .empty }
        let str = cell.str.map { String(cString: $0) }
        if id == boolErr {
            return str == "bool" ? .bool(cell.d != 0) : .string("#ERROR")
        }
        if id == formula || id == formulaAlt {
            // libxls: l == 0 → numeric result in d; else str is the string result, "bool" or "error".
            if cell.l != 0 {
                switch str {
                case "bool": return .bool(cell.d != 0)
                case "error": return .string("#ERROR")
                case let s?: return s.isEmpty ? .empty : .string(s)
                case nil: return .empty
                }
            }
            return numeric(cell, wb: wb, is1904: is1904, kinds: &kinds)
        }
        if id == number || id == rk || id == mulRK { return numeric(cell, wb: wb, is1904: is1904, kinds: &kinds) }
        guard let str, !str.isEmpty else { return .empty }
        return .string(str)
    }

    static func numeric(_ cell: xlsCell, wb: UnsafeMutablePointer<xlsWorkBook>, is1904: Bool,
                        kinds: inout [UInt16: SpreadsheetDates.Kind?]) -> Workbook.CellValue {
        let kind: SpreadsheetDates.Kind?
        if let k = kinds[cell.xf] {
            kind = k
        } else {
            let fmt = acx_xls_cell_format(wb, cell.xf)
            let code = acx_xls_format_string(wb, fmt).map { String(cString: $0) }
            kind = SpreadsheetDates.kind(formatID: Int(fmt), code: code)
            kinds[cell.xf] = kind
        }
        if let kind, let iso = SpreadsheetDates.iso(serial: cell.d, kind: kind, is1904: is1904) { return .string(iso) }
        return .number(cell.d)
    }

    static func reference(column: Int, row: Int) -> String {
        var n = column, s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(UInt8(65 + r))) + s
            n = (n - 1) / 26
        }
        return "\(s)\(row)"
    }
}
