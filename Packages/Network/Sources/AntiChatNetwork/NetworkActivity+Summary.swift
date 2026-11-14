// M8.T08 step 3 (R-091 AC2, R-297; S-21 Privacy & Data, components.md NetworkActivityList): the per-category
// summary of the gate's activity. One row per user-facing group — Updates, Model catalog & downloads, Web search,
// Connections (+ Crash reports once one was sent) — with its state (On / Off / Paused by Offline only), when it was
// last used and its last 20 events. Generated from the gate's records and policy only, never hand-written.
import Foundation

/// The rows of Settings › Privacy & Data › Network activity, in display order.
public enum NetworkActivityGroup: String, Sendable, CaseIterable, Codable {
    case updates, catalog, search, connections, crashReports

    /// The gate categories that make up the row (`other` has no row: it is listed only inside the turn ledger).
    public var categories: [NetworkCategory] {
        switch self {
        case .updates: [.updates]
        case .catalog: [.catalog, .models]
        case .search: [.search]
        case .connections: [.connectors, .mcp, .relay]
        case .crashReports: [.crashReport]
        }
    }

    public static func group(of category: NetworkCategory) -> NetworkActivityGroup? {
        allCases.first { $0.categories.contains(category) }
    }
}

/// One stored request (a `network_activity` row, decoupled from the storage record type).
public struct NetworkActivityEntry: Sendable, Equatable, Hashable {
    public var ts: Date
    public var category: String
    public var host: String
    public var bytes: Int64
    public var outcome: String

    public init(ts: Date, category: String, host: String, bytes: Int64, outcome: String) {
        self.ts = ts; self.category = category; self.host = host; self.bytes = bytes; self.outcome = outcome
    }
}

public struct NetworkActivityGroupSummary: Sendable, Equatable, Identifiable {
    public enum State: String, Sendable, Equatable { case on, off, paused }
    public enum LastUsed: Sendable, Equatable {
        case never
        /// Inside the rolling window.
        case at(Date)
        /// Used before, but not in the rolling window (its rows were pruned).
        case beforeWindow
    }

    public var group: NetworkActivityGroup
    public var state: State
    public var lastUsed: LastUsed
    /// Newest first, at most `NetworkActivitySummary.eventLimit`.
    public var events: [NetworkActivityEntry]
    public var id: String { group.rawValue }
}

public enum NetworkActivitySummary {
    public static let window: TimeInterval = 7 * 24 * 3600
    public static let eventLimit = 20

    /// - Parameters:
    ///   - entries: the stored rows (any order; rows outside the window are ignored).
    ///   - enabled: the stored per-category switch (ignores Offline only).
    ///   - lastEver: the newest use of each category ever seen (survives the 7-day prune).
    /// "Last used" counts requests that left the Mac: a request the gate refused (`blocked`) is listed, not "used".
    public static func summarize(entries: [NetworkActivityEntry], now: Date, offlineOnly: Bool,
                                 enabled: (NetworkCategory) -> Bool,
                                 lastEver: (NetworkCategory) -> Date? = { _ in nil }) -> [NetworkActivityGroupSummary] {
        let since = now.addingTimeInterval(-window)
        let recent = entries.filter { $0.ts >= since }.sorted { $0.ts > $1.ts }
        var out: [NetworkActivityGroupSummary] = []
        for group in NetworkActivityGroup.allCases {
            let names = Set(group.categories.map(\.rawValue))
            let events = recent.filter { names.contains($0.category) }
            let usedBefore = group.categories.contains { lastEver($0) != nil }
            // Crash reports: the row exists only once a report was sent (opt-in; nothing is sent by default).
            if group == .crashReports, events.isEmpty, !usedBefore { continue }
            let state: NetworkActivityGroupSummary.State =
                offlineOnly ? .paused : (group.categories.contains(where: enabled) ? .on : .off)
            let lastUsed: NetworkActivityGroupSummary.LastUsed =
                events.first { $0.outcome != NetworkEvent.Outcome.blocked.rawValue }.map { .at($0.ts) }
                    ?? (usedBefore ? .beforeWindow : .never)
            out.append(.init(group: group, state: state, lastUsed: lastUsed, events: Array(events.prefix(eventLimit))))
        }
        return out
    }
}

public extension NetworkPolicyStore {
    static func lastUsedKey(_ c: NetworkCategory) -> String { "net.lastUsed.\(c.rawValue)" }

    /// The newest recorded use of `c` (kept past the 7-day prune of `network_activity`, for "More than 7 days ago").
    func lastUsed(_ c: NetworkCategory) -> Date? {
        let t = defaultsStore.double(forKey: Self.lastUsedKey(c))
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Records a use (written at most once a minute per category).
    func recordUse(_ c: NetworkCategory, at ts: Date) {
        let key = Self.lastUsedKey(c)
        if ts.timeIntervalSince1970 - defaultsStore.double(forKey: key) < 60 { return }
        defaultsStore.set(ts.timeIntervalSince1970, forKey: key)
    }
}
