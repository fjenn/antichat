// M6.T10 step 2 (R-273 AC1/AC5, P-files-tools-05, A-M6-02): the libxlsxwriter v1.2.4 wrapper. Per sheet: a bold header
// row with a bottom border, typed cells (number / string / datetime / boolean) with the column's number format,
// formulas, frozen header (`worksheet_freeze_panes(1, 0)`), autofilter over the data, column widths (auto = max(header,
// p95 cell length) capped at 60, or the spec's numbers) and an optional native chart (column, bar, line, pie, scatter).
// Document properties author/company "AntiChat". Written to a temp file (libxlsxwriter writes files), read back, removed.
import Foundation
import libxlsxwriter

public enum XLSXWriter {
    /// Default number formats per column kind when the spec gives none.
    static func defaultFormat(_ k: SheetSpec.Column.Kind) -> String? {
        switch k {
        case .currency: "#,##0.00"
        case .percent: "0%"
        case .date: "yyyy-mm-dd"
        default: nil
        }
    }

    /// An Excel-legal, unique sheet name.
    static func sheetName(_ raw: String, used: inout Set<String>) -> String {
        var n = String(raw.map { "[]:*?/\\".contains($0) ? "-" : $0 }).trimmingCharacters(in: CharacterSet(charactersIn: "' "))
        if n.isEmpty { n = "Sheet" }
        n = String(n.prefix(31))
        var candidate = n, i = 2
        while used.contains(candidate.lowercased()) {
            let suffix = " (\(i))"
            candidate = String(n.prefix(31 - suffix.count)) + suffix
            i += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    /// "2026-03-31", "2026-03-31T10:20", "2026-03-31 10:20:30" → lxw_datetime.
    static func datetime(_ s: String) -> lxw_datetime? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == "T" || $0 == " " })
        guard let d = parts.first else { return nil }
        let ymd = d.split(separator: "-").compactMap { Int($0) }
        guard ymd.count == 3, (1...9999).contains(ymd[0]), (1...12).contains(ymd[1]), (1...31).contains(ymd[2]) else {
            if ymd.count == 2, (1...12).contains(ymd[1]) {  // "2026-03" → first of the month
                return lxw_datetime(year: Int32(ymd[0]), month: Int32(ymd[1]), day: 1, hour: 0, min: 0, sec: 0)
            }
            return nil
        }
        var h = 0, m = 0, sec = 0.0
        if parts.count > 1 {
            let t = parts[1].split(separator: ":")
            h = t.count > 0 ? Int(t[0]) ?? 0 : 0
            m = t.count > 1 ? Int(t[1]) ?? 0 : 0
            sec = t.count > 2 ? Double(t[2].prefix(while: { $0 != "Z" && $0 != "+" })) ?? 0 : 0
        }
        return lxw_datetime(year: Int32(ymd[0]), month: Int32(ymd[1]), day: Int32(ymd[2]), hour: Int32(h), min: Int32(m), sec: sec)
    }

    /// Excel's grid: columns A…XFD, rows 1…1,048,576.
    static let maxColumns = 16_384, maxRows = 1_048_576

    /// "A1" → (row, col), zero-based; nil for anything outside Excel's grid or not ASCII A–Z + digits (model-supplied
    /// refs: M6 review #3, a trap on an out-of-range value would kill the app).
    static func cell(_ ref: String) -> (row: UInt32, col: UInt16)? {
        let s = Array(ref.replacingOccurrences(of: "$", with: "").utf8)
        let isLetter = { (b: UInt8) in (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) }
        let letters = s.prefix(while: isLetter), digits = s.dropFirst(letters.count)
        guard (1...3).contains(letters.count), (1...7).contains(digits.count), digits.allSatisfy({ (0x30...0x39).contains($0) }),
              let r = Int(String(decoding: digits, as: UTF8.self)), (1...maxRows).contains(r) else { return nil }
        var c = 0
        for b in letters { c = c * 26 + Int((b & 0xDF) - 0x40) }
        guard (1...maxColumns).contains(c), let row = UInt32(exactly: r - 1), let col = UInt16(exactly: c - 1) else { return nil }
        return (row, col)
    }

    /// "A2:A13" (same sheet) → "='Sheet'!$A$2:$A$13"; an explicit sheet reference is kept.
    static func range(_ r: String, sheet: String) -> String {
        if r.contains("!") { return r.hasPrefix("=") ? r : "=" + r }
        let parts = r.replacingOccurrences(of: "$", with: "").split(separator: ":").map { p -> String in
            let letters = p.prefix(while: { $0.isLetter }), digits = p.dropFirst(letters.count)
            return "$\(letters.uppercased())$\(digits)"
        }
        return "='\(sheet.replacingOccurrences(of: "'", with: "''"))'!" + parts.joined(separator: ":")
    }

    static func chartType(_ s: String) -> UInt8 {
        switch s {
        case "bar": UInt8(LXW_CHART_BAR.rawValue)
        case "line": UInt8(LXW_CHART_LINE.rawValue)
        case "pie": UInt8(LXW_CHART_PIE.rawValue)
        case "scatter": UInt8(LXW_CHART_SCATTER_STRAIGHT_WITH_MARKERS.rawValue)
        default: UInt8(LXW_CHART_COLUMN.rawValue)
        }
    }

    /// Display width of a value in characters (East Asian wide characters count twice).
    static func width(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + ((0x1100...0x115F).contains($1.value) || (0x2E80...0xA4CF).contains($1.value)
            || (0xAC00...0xD7A3).contains($1.value) || (0xF900...0xFAFF).contains($1.value) || (0xFF00...0xFF60).contains($1.value) ? 2 : 1) }
    }

    static func autoWidths(_ sheet: SheetSpec, columns: Int) -> [Double] {
        (0..<columns).map { c in
            let header = c < sheet.columns.count ? width(sheet.columns[c].header) : 0
            var lens = sheet.rows.compactMap { c < $0.count ? width(display($0[c], kind: c < sheet.columns.count ? sheet.columns[c].type : .text)) : nil }
            lens.sort()
            let p95 = lens.isEmpty ? 0 : lens[min(lens.count - 1, Int((Double(lens.count) * 0.95).rounded(.down)))]
            return Double(min(max(header, p95, 6) + 2, 60))
        }
    }

    /// Roughly what a cell shows (for widths only).
    static func display(_ v: CellValue, kind: SheetSpec.Column.Kind) -> String {
        switch (v, kind) {
        case (.number(let d), .currency): String(format: "%.2f", d) + "000"
        case (.number(let d), .percent): String(format: "%.1f%%", d * 100)
        case (.number(let d), .number): d == d.rounded() ? String(Int64(clamping: Int64(d.isFinite ? d : 0))) + (abs(d) >= 1000 ? "000" : "") : String(format: "%.4f", d)
        default: v.text
        }
    }

    public static func render(_ spec: SpreadsheetSpec, now: Date = Date()) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-xlsx-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let wb = workbook_new(tmp.path) else { throw FileOutError.render("libxlsxwriter could not create the workbook") }
        var used = Set<String>()
        // Formats are workbook-owned (freed by workbook_close).
        let header = workbook_add_format(wb)
        format_set_bold(header)
        format_set_bottom(header, UInt8(LXW_BORDER_THIN.rawValue))
        var formats: [String: UnsafeMutablePointer<lxw_format>] = [:]
        func numFormat(_ f: String?) -> UnsafeMutablePointer<lxw_format>? {
            guard let f, !f.isEmpty else { return nil }
            if let x = formats[f] { return x }
            let x = workbook_add_format(wb)
            format_set_num_format(x, f)
            formats[f] = x
            return x
        }
        let dateTimeFallback = numFormat("yyyy-mm-dd")

        for sheet in spec.sheets {
            let name = sheetName(sheet.name, used: &used)
            guard let ws = workbook_add_worksheet(wb, name) else { continue }
            let cols = max(sheet.columns.count, sheet.rows.map(\.count).max() ?? 0)
            for (c, col) in sheet.columns.enumerated() {
                worksheet_write_string(ws, 0, UInt16(c), col.header, header)
            }
            for (r, row) in sheet.rows.enumerated() {
                let rr = UInt32(r + 1)
                for (c, v) in row.enumerated() {
                    let kind = c < sheet.columns.count ? sheet.columns[c].type : .text
                    let fmt = numFormat(c < sheet.columns.count ? (sheet.columns[c].format ?? defaultFormat(kind)) : nil)
                    let cc = UInt16(c)
                    switch (v, kind) {
                    case (.empty, _):
                        if fmt != nil { worksheet_write_blank(ws, rr, cc, fmt) }
                    case (.bool(let b), _):
                        worksheet_write_boolean(ws, rr, cc, b ? 1 : 0, fmt)
                    case (.number(let d), .text):
                        worksheet_write_string(ws, rr, cc, CellValue.format(d), fmt)
                    case (.number(let d), _):
                        worksheet_write_number(ws, rr, cc, d, fmt)
                    case (.text(let s), .date):
                        if var dt = datetime(s) {
                            worksheet_write_datetime(ws, rr, cc, &dt, fmt ?? dateTimeFallback)
                        } else {
                            worksheet_write_string(ws, rr, cc, s, nil)
                        }
                    case (.text(let s), .number), (.text(let s), .currency), (.text(let s), .percent):
                        let cleaned = s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
                        if kind == .percent, cleaned.hasSuffix("%"), let d = Double(cleaned.dropLast()) {
                            worksheet_write_number(ws, rr, cc, d / 100, fmt)
                        } else if let d = Double(cleaned) {
                            worksheet_write_number(ws, rr, cc, d, fmt)
                        } else {
                            worksheet_write_string(ws, rr, cc, s, nil)
                        }
                    case (.text(let s), .bool):
                        let l = s.lowercased()
                        if ["true", "yes", "1"].contains(l) { worksheet_write_boolean(ws, rr, cc, 1, fmt) }
                        else if ["false", "no", "0"].contains(l) { worksheet_write_boolean(ws, rr, cc, 0, fmt) }
                        else { worksheet_write_string(ws, rr, cc, s, nil) }
                    case (.text(let s), _):
                        worksheet_write_string(ws, rr, cc, s, fmt)
                    }
                }
            }
            // Formulas (the cell's column format applies; a cell below the data keeps the format of its column).
            for (ref, f) in sheet.formulas.sorted(by: { $0.key < $1.key }) {
                guard let (r, c) = cell(ref) else { continue }
                let kind = Int(c) < sheet.columns.count ? sheet.columns[Int(c)].type : .text
                let fmt = r == 0 ? header : numFormat(Int(c) < sheet.columns.count ? (sheet.columns[Int(c)].format ?? defaultFormat(kind)) : nil)
                let body = f.hasPrefix("=") ? f : "=" + f
                worksheet_write_formula(ws, r, c, body, fmt)
            }
            let widths = sheet.columnWidths ?? autoWidths(sheet, columns: cols)
            for c in 0..<cols {
                let w = c < widths.count ? widths[c] : (widths.last ?? 10)
                worksheet_set_column(ws, UInt16(c), UInt16(c), min(max(w, 1), 255), nil)
            }
            if sheet.freezeHeader { worksheet_freeze_panes(ws, 1, 0) }
            if sheet.autofilter, cols > 0 {
                worksheet_autofilter(ws, 0, 0, UInt32(max(sheet.rows.count, 1)), UInt16(cols - 1))
            }
            if let chart = sheet.chart, let ch = workbook_add_chart(wb, chartType(chart.type)) {
                for v in chart.values {
                    let series = chart_add_series(ch, range(chart.categories, sheet: name), range(v, sheet: name))
                    // Series name = the header above the values range.
                    if let start = cell(String(v.split(separator: ":").first ?? "")), start.row > 0,
                       Int(start.col) < sheet.columns.count {
                        chart_series_set_name(series, sheet.columns[Int(start.col)].header)
                    }
                }
                if let t = chart.title, !t.isEmpty { chart_title_set_name(ch, t) }
                worksheet_insert_chart(ws, 1, UInt16(cols + 1), ch)
            }
        }
        var props = lxw_doc_properties()
        let strings = [spec.outputName, "AntiChat", "AntiChat"].map { strdup($0) }
        defer { strings.forEach { free($0) } }
        props.title = UnsafePointer(strings[0])
        props.author = UnsafePointer(strings[1])
        props.company = UnsafePointer(strings[2])
        props.created = time_t(now.timeIntervalSince1970)
        workbook_set_properties(wb, &props)
        let err = workbook_close(wb)
        guard err.rawValue == 0 else { throw FileOutError.render("libxlsxwriter error \(err.rawValue)") }
        do { return try Data(contentsOf: tmp) } catch { throw FileOutError.render("\(error)") }
    }
}
