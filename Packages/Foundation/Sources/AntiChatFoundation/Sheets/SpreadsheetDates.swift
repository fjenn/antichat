// M6.T07 (R-272 AC1): spreadsheet number formats → dates. Both readers that see Excel serial numbers use it: the BIFF
// reader (AntiChatKnowledge XLSAdapter, libxls XF formats) and the XLSX style pass (AntiChatTools SheetLoader). A
// date-formatted cell becomes ISO text ("2026-03-01", "2026-03-01 14:30:00", "14:30:00") so every later consumer
// (intake Markdown, DuckDB type inference) sees the same value a CSV export would hold.
import Foundation

public enum SpreadsheetDates {
    /// Built-in number-format ids that are dates/times (ECMA-376 §18.8.30; BIFF8 uses the same table), incl. the
    /// East-Asian locale ids 27–36 and 50–58.
    public static let builtinDateFormats: Set<Int> = Set(14...22).union(27...36).union(45...47).union(50...58)

    public enum Kind: Equatable, Sendable { case date, dateTime, time }

    /// Whether a number format is a date/time format, and which. `code` is the custom format string when the id is
    /// not built-in.
    public static func kind(formatID: Int, code: String?) -> Kind? {
        if let code, !code.isEmpty { return kind(code: code) }
        guard builtinDateFormats.contains(formatID) else { return nil }
        switch formatID {
        case 18, 19, 20, 21, 45, 46, 47: return .time
        case 22: return .dateTime
        default: return .date
        }
    }

    /// Format-code test: strip quoted literals, escapes and `[...]` sections (colours, locales; `[h]` elapsed time
    /// stays a time), then look for date/time tokens.
    public static func kind(code: String) -> Kind? {
        var plain = ""
        var inQuote = false
        var inBracket = false
        var bracket = ""
        var escape = false
        for ch in code {
            if escape { escape = false; continue }
            if inQuote { if ch == "\"" { inQuote = false }; continue }
            if inBracket {
                if ch == "]" {
                    inBracket = false
                    let b = bracket.lowercased()
                    if b.allSatisfy({ "hms".contains($0) }) && !b.isEmpty { plain.append("h") }
                } else { bracket.append(ch) }
                continue
            }
            switch ch {
            case "\\": escape = true
            case "\"": inQuote = true
            case "[": inBracket = true; bracket = ""
            case "_", "*": escape = true  // padding: skip the next char
            default: plain.append(ch)
            }
        }
        let s = plain.lowercased()
        if s.contains("general") { return nil }
        let hasDate = s.contains("y") || s.contains("d")
        let hasTime = s.contains("h") || s.contains("s")
        // A bare "m" is month next to y/d and minutes next to h/s; with neither it is no date token.
        if hasDate { return hasTime ? .dateTime : .date }
        if hasTime { return .time }
        return nil
    }

    /// Excel serial day number → ISO text in UTC (no time zone: spreadsheet dates are wall-clock values).
    public static func iso(serial: Double, kind: Kind, is1904: Bool = false) -> String? {
        guard serial.isFinite, serial > -1, serial < 2_958_466 else { return nil }  // ≤ 9999-12-31
        // 1900 system: day 0 = 1899-12-30 (Excel's phantom 1900-02-29 makes serials ≥ 61 line up with that epoch).
        let epoch: TimeInterval = is1904 ? -2_082_844_800 : -2_209_161_600
        let seconds = (serial * 86_400).rounded()
        let date = Date(timeIntervalSince1970: epoch + seconds)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let y = c.year, let mo = c.month, let d = c.day else { return nil }
        let day = String(format: "%04d-%02d-%02d", y, mo, d)
        let time = String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        switch kind {
        case .date: return seconds.truncatingRemainder(dividingBy: 86_400) == 0 ? day : day + " " + time
        case .dateTime: return day + " " + time
        case .time: return time
        }
    }
}
