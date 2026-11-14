// M6.T10 step 3 (R-273): CSV per RFC 4180 — UTF-8 with a BOM (Excel opens it as UTF-8), CRLF line ends, fields quoted
// when they hold a comma, quote, CR or LF (quotes doubled). One sheet: header row, then the rows; numbers in plain
// decimal, booleans TRUE/FALSE, empty cells empty. Formulas do not exist in CSV (a spec with formulas is rejected).
import Foundation

public enum CSVWriter {
    public static func field(_ s: String) -> String {
        if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" || $0 == "\r\n" }) {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    public static func render(_ sheet: SheetSpec) -> Data {
        var out = "\u{FEFF}"
        let width = max(sheet.columns.count, sheet.rows.map(\.count).max() ?? 0)
        let header = (0..<width).map { $0 < sheet.columns.count ? sheet.columns[$0].header : "" }
        out += header.map(field).joined(separator: ",") + "\r\n"
        for row in sheet.rows {
            out += (0..<width).map { $0 < row.count ? field(row[$0].text) : "" }.joined(separator: ",") + "\r\n"
        }
        return Data(out.utf8)
    }
}
