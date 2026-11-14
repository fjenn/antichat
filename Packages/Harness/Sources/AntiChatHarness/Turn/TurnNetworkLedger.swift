// M2.T03 step 4 (R-209 AC5; P-platform-08): which hosts a turn contacted. The gate tags every request with the
// turn's `TurnContext.requestID`; this ledger collects the events for open turns and hands the host list to the
// turn at finalisation (`provenance_json.network`, the globe chip under the reply). No hosts → no chip.
// Harness never imports AntiChatNetwork (architecture §3): the event source is a protocol, conformed to in
// AntiChatUI and connected at the composition root.
import Foundation
import AntiChatStorage

/// A gate event as the ledger needs it.
public struct TurnNetworkEvent: Sendable, Equatable {
    public var turnID: String
    public var host: String
    public var category: String
    public init(turnID: String, host: String, category: String) {
        self.turnID = turnID; self.host = host; self.category = category
    }
}

/// The gate's event stream (AntiChatUI's `GateNetworkEventSource` wraps `NetworkGate.addObserver`).
public protocol NetworkEventSource: Sendable {
    /// Calls `handler` for every request tagged with a turn id; the returned token stops it.
    func observe(_ handler: @escaping @Sendable (TurnNetworkEvent) -> Void) -> any Sendable
}

public final class TurnNetworkLedger: @unchecked Sendable {
    /// The app's ledger (TurnController reads it); `connect` is called once at launch.
    public static let shared = TurnNetworkLedger()

    private let lock = NSLock()
    private var open: [String: [NetworkHost]] = [:]
    private var token: (any Sendable)?

    public init() {}

    /// Starts receiving events from `source` (idempotent: a second call replaces the first).
    public func connect(_ source: any NetworkEventSource) {
        let t = source.observe { [weak self] in self?.record($0) }
        lock.lock(); token = t; lock.unlock()
    }

    /// Opens the ledger for a turn (events for unknown turns are dropped).
    public func begin(_ turnID: String) { lock.lock(); open[turnID] = []; lock.unlock() }

    func record(_ e: TurnNetworkEvent) {
        lock.lock(); defer { lock.unlock() }
        guard open[e.turnID] != nil else { return }
        let h = NetworkHost(host: e.host, category: e.category)
        if !open[e.turnID]!.contains(h) { open[e.turnID]!.append(h) }
    }

    /// Closes the turn and returns its hosts in first-contact order; nil when it contacted none.
    public func end(_ turnID: String) -> [NetworkHost]? {
        lock.lock(); defer { lock.unlock() }
        let hosts = open.removeValue(forKey: turnID)
        return hosts?.isEmpty == false ? hosts : nil
    }
}
