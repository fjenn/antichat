// M7.T03 step 1 (R-080 AC1, R-267): web search is offered only when the user's switch is on (the gate's `.search`
// category, `net.category.search`, seeded by onboarding step 4, default on, D-007), Offline only is off and the
// network path is up. Otherwise `web_search` / `read_url` are not offered at all and the app works offline as before.
import AntiChatNetwork
import Foundation

public struct WebSearchAvailability: Sendable {
    public enum State: String, Sendable, Equatable { case available, switchedOff, offlineOnly, noNetwork }

    public let policy: NetworkPolicyStore
    public let path: PathStatus
    private let fixed: State?
    public init(policy: NetworkPolicyStore = .shared, path: PathStatus = .shared) { self.policy = policy; self.path = path; fixed = nil }
    /// A constant state (tests of modules that must not see AntiChatNetwork, e.g. Harness).
    public init(fixed: State) { policy = .shared; path = .shared; self.fixed = fixed }

    public var state: State {
        if let fixed { return fixed }
        if policy.offlineOnly { return .offlineOnly }
        if !policy.storedValue(.search) { return .switchedOff }
        if path.isOffline { return .noNetwork }
        return .available
    }
    public var isAvailable: Bool { state == .available }

    /// The copy key shown when search is asked for but not available (chip / activity line).
    public var unavailableKey: String? {
        switch state {
        case .available: nil
        case .offlineOnly: "network.blockedByOfflineOnly"
        case .noNetwork: "network.offlineForSearch"
        case .switchedOff: "set.tools.web"
        }
    }

    /// Calls `f` on every change of the switch, Offline only or the path (registry availability follows).
    public static func observe(_ f: @escaping @Sendable () -> Void) -> [NSObjectProtocol] {
        [NetworkPolicyStore.didChange, PathStatus.didChange].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: nil) { _ in f() }
        }
    }
}
