// M2.T02 step 4 (R-297 AC2; P-platform-08): persists the gate's events as `network_activity` rows (the gate
// already drops incognito events before the sink). Rolling 7 days: rows older than that are pruned on install
// and once a day of writes. Installed once at the composition root.
import Foundation
import AntiChatFoundation
import AntiChatNetwork
import AntiChatStorage

public enum NetworkActivityStore {
    public static let window: TimeInterval = 7 * 24 * 3600

    /// Routes `NetworkGate.activitySink` into `database`.
    public static func install(database: AppDatabase) {
        try? NetworkActivityRecord.prune(database, before: Date().addingTimeInterval(-window))
        NetworkGate.activitySink = { e in write(e, to: database) }
    }

    public static func write(_ e: NetworkEvent, to database: AppDatabase) {
        guard NetworkGate.recordsActivity(incognito: e.incognito) else { return }
        if e.outcome != .blocked { NetworkPolicyStore.shared.recordUse(e.category, at: e.ts) }  // M8.T08: "More than 7 days ago" after the prune
        var r = NetworkActivityRecord(ts: e.ts, category: e.category.rawValue, host: e.host, bytes: e.bytes, outcome: e.outcome.rawValue)
        do { try database.write { try r.insert($0) } } catch {
            AppLog.log(.net, .error, "network_activity write failed: \(error)")
        }
    }
}
