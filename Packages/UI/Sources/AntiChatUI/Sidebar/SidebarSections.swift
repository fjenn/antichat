// Sidebar grouping (M1.T07 step 5; components.md §1 SectionHeader): Pinned, Today, Previous 7 days, Older.
// Pure and calendar-injected so SidebarGroupingTests can pin "now" and the time zone.
import AntiChatDesign
import AntiChatHarness
import Foundation

public enum SidebarSection: String, CaseIterable, Sendable, Identifiable {
    case pinned, today, week, older

    public var id: String { rawValue }

    public var title: CopyKey {
        switch self {
        case .pinned: CopyKey("side.pinned")
        case .today: CopyKey("side.today")
        case .week: CopyKey("side.week")
        case .older: CopyKey("side.older")
        }
    }
}

public struct SidebarGroup: Identifiable, Equatable, Sendable {
    public let section: SidebarSection
    public let chats: [ChatSummary]
    public var id: SidebarSection { section }
}

public enum SidebarGrouping {
    /// Groups `chats` (already in sidebar order) into non-empty sections, keeping the input order inside each.
    /// Pinned chats go to Pinned whatever their date; the others by the calendar day of `updatedAt`:
    /// today → Today, the 7 calendar days before today → Previous 7 days, earlier → Older.
    public static func group(_ chats: [ChatSummary], now: Date, calendar: Calendar = .current) -> [SidebarGroup] {
        var buckets: [SidebarSection: [ChatSummary]] = [:]
        let startOfToday = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
        for chat in chats {
            let section: SidebarSection
            if chat.pinned {
                section = .pinned
            } else if chat.updatedAt >= startOfToday {
                section = .today
            } else if chat.updatedAt >= weekStart {
                section = .week
            } else {
                section = .older
            }
            buckets[section, default: []].append(chat)
        }
        return SidebarSection.allCases.compactMap { s in
            guard let list = buckets[s], !list.isEmpty else { return nil }
            return SidebarGroup(section: s, chats: list)
        }
    }
}
