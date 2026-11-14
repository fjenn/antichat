// Sidebar sections (M1.T07 step 5): Pinned, Today, Previous 7 days, Older — order kept, empty sections dropped.
import AntiChatHarness
import Foundation
import Testing
@testable import AntiChatUI

@Suite(.isolatedSettings) struct SidebarGroupingTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return c
    }

    /// 2026-10-30 15:00 Amsterdam.
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 15))! }

    func chat(_ id: String, daysAgo: Int, hour: Int = 10, pinned: Bool = false) -> ChatSummary {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
        let date = calendar.date(byAdding: .hour, value: hour, to: day)!
        return ChatSummary(id: id, title: id, pinned: pinned, createdAt: date, updatedAt: date)
    }

    @Test func groupsIntoTheFourSections() {
        let chats = [
            chat("p-old", daysAgo: 40, pinned: true),
            chat("today-1", daysAgo: 0, hour: 14),
            chat("today-0h", daysAgo: 0, hour: 0),
            chat("yesterday", daysAgo: 1, hour: 23),
            chat("week-7", daysAgo: 7, hour: 1),
            chat("older-8", daysAgo: 8, hour: 23),
            chat("older-400", daysAgo: 400),
        ]
        let g = SidebarGrouping.group(chats, now: now, calendar: calendar)
        #expect(g.map(\.section) == [.pinned, .today, .week, .older])
        #expect(g[0].chats.map(\.id) == ["p-old"])
        #expect(g[1].chats.map(\.id) == ["today-1", "today-0h"])
        #expect(g[2].chats.map(\.id) == ["yesterday", "week-7"])
        #expect(g[3].chats.map(\.id) == ["older-8", "older-400"])
    }

    @Test func emptySectionsAreDropped() {
        let g = SidebarGrouping.group([chat("a", daysAgo: 0)], now: now, calendar: calendar)
        #expect(g.map(\.section) == [.today])
        #expect(SidebarGrouping.group([], now: now, calendar: calendar).isEmpty)
    }

    @Test func pinnedWinsOverDate() {
        let g = SidebarGrouping.group([chat("a", daysAgo: 0, pinned: true)], now: now, calendar: calendar)
        #expect(g.map(\.section) == [.pinned])
    }

    @Test func sectionTitlesAreDeckKeys() {
        #expect(SidebarSection.allCases.map(\.title.rawValue) == ["side.pinned", "side.today", "side.week", "side.older"])
        #expect(SidebarSection.allCases.allSatisfy { $0.title.isKnown })
    }

    @Test func tenThousandChatsGroupFast() {
        let chats = (0..<10_000).map { chat("c\($0)", daysAgo: $0 % 60) }
        // This thread's CPU time (the grouping is synchronous): wall time measured the parallel suite's load.
        func threadCPUns() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
        let start = threadCPUns()
        _ = SidebarGrouping.group(chats, now: now, calendar: calendar)
        #expect(threadCPUns() - start < 100_000_000)
    }
}
