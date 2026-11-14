// Date and time context (M1.T14 step 1; R-003 AC5; D-022). Split in two so a new minute never breaks the KV /
// prefix cache:
//   - `dateLine` (day granularity, in the user's time zone) is the last stable layer of the system turn. It changes
//     once a day, so only a day change invalidates the prefix.
//   - `timeLine` (local time to the minute + UTC offset) is ephemeral: the engine adapter appends it to the newest
//     user turn after the history (`ChatRequest.turnContext`), and it is never persisted. A new minute only changes
//     the tokens of the newest turn.
import Foundation

public struct VolatileContext: Sendable, Hashable {
    public var now: Date
    public var timeZone: TimeZone

    public init(now: Date = Date(), timeZone: TimeZone = .current) {
        self.now = now
        self.timeZone = timeZone
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }

    /// e.g. `Current date: 2026-10-30 (Friday), time zone Europe/Berlin.` The calendar day in the user's time zone;
    /// fixed English wording and the POSIX locale, so the bytes depend on the day and the zone only (no UTC offset:
    /// a DST switch happens mid-day and would otherwise invalidate the prefix a second time that day).
    public var dateLine: String {
        let cal = calendar
        let c = cal.dateComponents([.year, .month, .day, .weekday], from: now)
        let weekday = cal.weekdaySymbols[(c.weekday ?? 1) - 1]
        let date = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return "Current date: \(date) (\(weekday)), time zone \(timeZone.identifier)."
    }

    /// e.g. `Current local time: 14:05 (UTC+01:00).` Attached to the newest user turn only (D-022).
    public var timeLine: String {
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let offset = timeZone.secondsFromGMT(for: now)
        let sign = offset < 0 ? "-" : "+"
        let off = abs(offset)
        let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        let utc = String(format: "UTC%@%02d:%02d", sign, off / 3600, (off % 3600) / 60)
        return "Current local time: \(time) (\(utc))."
    }
}
