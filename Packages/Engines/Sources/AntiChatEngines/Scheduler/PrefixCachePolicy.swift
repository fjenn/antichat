// M6.T03 step 3 (R-279; NFR-M4, NFR-R1): which kept prompt prefixes (MLX session snapshots) go, and when. Pinned
// document prefixes (ChatRequest.prefixPin) outlive the plain LRU of unpinned sessions, but (a) a memory-pressure
// warning drops them first, within the pressure handler (≤ 2 s), (b) one idle longer than the keep-alive goes, and
// (c) when the budget B needs room they go before anything resident is evicted. Incognito prefixes are never saved
// to disk (architecture §5.4). Pure decisions: MLXPrefixCache applies them.
import Foundation

public struct PrefixCachePolicy: Sendable {
    public struct Entry: Sendable, Equatable {
        public var id: UUID
        public var pinned: Bool
        public var priority: Int
        public var lastUsed: Date
        public var bytes: UInt64
        public var incognito: Bool
        public init(id: UUID, pinned: Bool, priority: Int = 0, lastUsed: Date, bytes: UInt64 = 0, incognito: Bool = false) {
            self.id = id; self.pinned = pinned; self.priority = priority; self.lastUsed = lastUsed; self.bytes = bytes
            self.incognito = incognito
        }
    }

    /// Unpinned sessions kept (LRU).
    public var maxSessions: Int
    /// Pinned document prefixes kept at once.
    public var maxPinned: Int
    /// An idle pin goes after this long (the chat is closed / not used).
    public var keepAlive: TimeInterval

    public init(maxSessions: Int = 2, maxPinned: Int = 2, keepAlive: TimeInterval = 600) {
        self.maxSessions = maxSessions; self.maxPinned = maxPinned; self.keepAlive = keepAlive
    }

    /// After a store: unpinned beyond `maxSessions` (oldest first), pinned beyond `maxPinned` (lowest priority, then
    /// oldest), and idle pins.
    public func evictAfterStore(_ entries: [Entry], now: Date = Date()) -> [UUID] {
        var out = evictIdle(entries, now: now)
        let live = entries.filter { !out.contains($0.id) }
        let unpinned = live.filter { !$0.pinned }.sorted { $0.lastUsed > $1.lastUsed }
        out += unpinned.dropFirst(maxSessions).map(\.id)
        let pinned = live.filter(\.pinned).sorted { ($0.priority, $0.lastUsed) > ($1.priority, $1.lastUsed) }
        out += pinned.dropFirst(maxPinned).map(\.id)
        return out
    }

    /// (b) keep-alive.
    public func evictIdle(_ entries: [Entry], now: Date = Date()) -> [UUID] {
        entries.filter { $0.pinned && now.timeIntervalSince($0.lastUsed) > keepAlive }.map(\.id)
    }

    /// (a) memory-pressure warning: pinned prefixes first, then every other session snapshot.
    public func evictOnPressure(_ entries: [Entry]) -> [UUID] {
        entries.filter(\.pinned).map(\.id) + entries.filter { !$0.pinned }.map(\.id)
    }

    /// (c) the budget B needs `needed` more bytes: pinned (lowest priority, oldest) first, then unpinned oldest,
    /// until enough is freed.
    public func evictForBudget(_ entries: [Entry], needed: UInt64) -> [UUID] {
        let order = entries.filter(\.pinned).sorted { ($0.priority, $0.lastUsed) < ($1.priority, $1.lastUsed) }
            + entries.filter { !$0.pinned }.sorted { $0.lastUsed < $1.lastUsed }
        var freed: UInt64 = 0
        var out: [UUID] = []
        for e in order where freed < needed {
            out.append(e.id)
            freed += e.bytes
        }
        return out
    }

    /// Never saved to disk for incognito (llama slot save / KV snapshot).
    public func persists(_ e: Entry) -> Bool { !e.incognito }
}
