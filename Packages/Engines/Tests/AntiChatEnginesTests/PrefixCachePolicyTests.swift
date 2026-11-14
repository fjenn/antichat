// AT-279 unit leg (M6.T03 step 3): eviction order of kept prompt prefixes — pinned document prefixes outlive the
// unpinned LRU, go first under memory pressure, after the keep-alive and when the budget needs room; incognito is
// never persisted.
//   make test-unit FILTER=PrefixCachePolicyTests
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct PrefixCachePolicyTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func e(_ n: Int, pinned: Bool, ago: TimeInterval, priority: Int = 1, bytes: UInt64 = 100, incognito: Bool = false)
        -> PrefixCachePolicy.Entry {
        .init(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!, pinned: pinned,
              priority: priority, lastUsed: now.addingTimeInterval(-ago), bytes: bytes, incognito: incognito)
    }

    @Test func pinnedOutliveTheUnpinnedLRU() {
        let p = PrefixCachePolicy(maxSessions: 2, maxPinned: 2, keepAlive: 600)
        let entries = [e(1, pinned: true, ago: 500), e(2, pinned: false, ago: 30), e(3, pinned: false, ago: 20),
                       e(4, pinned: false, ago: 10)]
        #expect(p.evictAfterStore(entries, now: now) == [entries[1].id], "oldest unpinned goes; the older pin stays")
    }

    @Test func tooManyPinsDropTheLowestPriorityThenOldest() {
        let p = PrefixCachePolicy(maxSessions: 2, maxPinned: 2)
        let entries = [e(1, pinned: true, ago: 10, priority: 2), e(2, pinned: true, ago: 5), e(3, pinned: true, ago: 50)]
        #expect(p.evictAfterStore(entries, now: now) == [entries[2].id])
    }

    @Test func keepAliveReleasesIdlePins() {
        let p = PrefixCachePolicy(keepAlive: 600)
        let entries = [e(1, pinned: true, ago: 601), e(2, pinned: true, ago: 599), e(3, pinned: false, ago: 9999)]
        #expect(p.evictIdle(entries, now: now) == [entries[0].id])
    }

    @Test func pressureDropsPinsFirst() {
        let p = PrefixCachePolicy()
        let entries = [e(1, pinned: false, ago: 1), e(2, pinned: true, ago: 1), e(3, pinned: false, ago: 2)]
        #expect(p.evictOnPressure(entries) == [entries[1].id, entries[0].id, entries[2].id])
    }

    @Test func budgetFreesPinsBeforeOtherSessions() {
        let p = PrefixCachePolicy()
        let entries = [e(1, pinned: false, ago: 100, bytes: 500), e(2, pinned: true, ago: 1, bytes: 300),
                       e(3, pinned: true, ago: 50, priority: 0, bytes: 300)]
        #expect(p.evictForBudget(entries, needed: 400) == [entries[2].id, entries[1].id])
        #expect(p.evictForBudget(entries, needed: 0).isEmpty)
    }

    @Test func incognitoIsNeverPersisted() {
        let p = PrefixCachePolicy()
        #expect(!p.persists(e(1, pinned: true, ago: 0, incognito: true)))
        #expect(p.persists(e(2, pinned: true, ago: 0)))
    }
}
