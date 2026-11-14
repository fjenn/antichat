// StartSeparator (M1.T07 step 4; ChatGPT "Today 1:26 PM" centred at the top of a conversation): the chat's
// created date, `type.footnote` `text.secondary`.
import AntiChatDesign
import SwiftUI

struct StartSeparator: View {
    let date: Date
    var now = Date()
    var calendar = Calendar.current

    var body: some View {
        Text(verbatim: Self.label(date, now: now, calendar: calendar))
            .typeStyle(.footnote)
            .foregroundStyle(Color.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.space2)
            .probeID("startSeparator")
    }

    /// One formatter (M1.T09 perf: the transcript re-evaluates this row on every streamed delta; building a
    /// DateFormatter each time cost ~4 % of the main thread while a reply streamed).
    nonisolated(unsafe) private static let relative: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// "Today 1:26 PM", "Yesterday 9:02 AM", else "Oct 12, 2026 at 9:02 AM" (system formats, localised).
    static func label(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) || calendar.isDateInYesterday(date) {
            return "\(relative.string(from: date)) \(time)"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
