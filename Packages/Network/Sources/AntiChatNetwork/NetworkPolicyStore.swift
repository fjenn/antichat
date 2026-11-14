// M2.T02/T03 (R-297, R-209 AC3; P-platform-08): per-category enabled flags (`net.category.<name>`) and the
// Offline only switch (`net.offlineOnly`). Offline only overrides every category without touching the stored
// values, so turning it off restores each category to what it was (R-209 step 1). Read on any thread
// (GateURLProtocol.canInit), so it is a locked cache over UserDefaults.
import Foundation
import AntiChatFoundation

public final class NetworkPolicyStore: @unchecked Sendable {
    /// The app's policy (the `-DefaultsSuite` suite in DEBUG probes, else the app domain).
    public static let shared = NetworkPolicyStore(defaults: NetworkPolicyStore.appDefaults(), launch: .current)

    /// Fresh-container defaults (R-209 AC3): updates, catalog, models, search on (search follows onboarding step
    /// 4, default on); connectors, mcp, relay off until a connection is added; crash reports off. `other` (untagged
    /// hosts not in the host table) is on.
    public static let defaultEnabled: [NetworkCategory: Bool] = [
        .updates: true, .catalog: true, .models: true, .search: true,
        .connectors: false, .mcp: false, .relay: false, .crashReport: false, .other: true,
    ]

    public static func key(_ c: NetworkCategory) -> String { "net.category.\(c.rawValue)" }
    public static let offlineOnlyKey = "net.offlineOnly"
    /// Posted (object = the store) after any change; the NetworkIndicator and Privacy page observe it.
    public static let didChange = Notification.Name("AntiChatNetworkPolicyDidChange")

    public let id = UUID().uuidString
    private let defaults: UserDefaults
    /// M8.T08: the same store for the per-category last-use stamps (NetworkActivity+Summary).
    var defaultsStore: UserDefaults { defaults }
    private let lock = NSLock()
    private var launchOfflineOnly: Bool

    public init(defaults: UserDefaults, launch: LaunchOptions = LaunchOptions()) {
        self.defaults = defaults
        launchOfflineOnly = launch.offlineOnly
        Self.registry.add(self)
    }

    /// The `-DefaultsSuite` probe suite, else the app domain — in a DEBUG unit-test process its private store
    /// (`AppDefaults`): the test tool's `.standard` is shared by every test process on the Mac, and a test that
    /// switched Offline only on for a turn (SkillsTurnTests) showed in another process's Settings › Privacy snapshot
    /// (toggle on, every category Paused: perceptual 0.969 < 0.98 in a full run).
    static func appDefaults() -> UserDefaults {
        AppDefaults.launchSuite ?? AppDefaults.standard
    }

    #if DEBUG || ANTICHAT_PERF_HARNESS
    static func isTestProcess(_ info: ProcessInfo = .processInfo) -> Bool { AppDefaults.isTestProcess(info) }
    #endif

    /// The stored per-category value (ignores Offline only).
    public func storedValue(_ c: NetworkCategory) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // `bool(forKey:)` also reads a launch override (`-net.category.search NO` arrives as the string "NO", which
        // `as? Bool` dropped; Q-015 r2 FreshnessHintUITests).
        return defaults.object(forKey: Self.key(c)) != nil ? defaults.bool(forKey: Self.key(c)) : Self.defaultEnabled[c] ?? false
    }

    /// Whether a request of category `c` may leave the Mac right now.
    public func isEnabled(_ c: NetworkCategory) -> Bool { !offlineOnly && storedValue(c) }

    public func setEnabled(_ c: NetworkCategory, _ on: Bool) {
        lock.lock()
        defaults.set(on, forKey: Self.key(c))
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Offline only (`-OfflineOnly YES` forces it on for the launch).
    public var offlineOnly: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return launchOfflineOnly || defaults.bool(forKey: Self.offlineOnlyKey)
        }
        set {
            lock.lock()
            defaults.set(newValue, forKey: Self.offlineOnlyKey)
            if !newValue { launchOfflineOnly = false }
            lock.unlock()
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// The categories that are on now (NetworkIndicator tooltip "Online: …").
    public var enabledCategories: [NetworkCategory] { NetworkCategory.allCases.filter(isEnabled) }

    /// Resets every key to the fresh-container defaults (tests, Settings "Reset").
    public func reset() {
        lock.lock()
        for c in NetworkCategory.allCases {
            defaults.removeObject(forKey: Self.key(c))
            defaults.removeObject(forKey: Self.lastUsedKey(c))
        }
        defaults.removeObject(forKey: Self.offlineOnlyKey)
        launchOfflineOnly = false
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: - Registry (GateURLProtocol resolves a request's `ac.policy` id to its store)

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var stores: [String: WeakStore] = [:]
        struct WeakStore { weak var store: NetworkPolicyStore? }
        func add(_ s: NetworkPolicyStore) { lock.lock(); stores[s.id] = WeakStore(store: s); lock.unlock() }
        func store(_ id: String) -> NetworkPolicyStore? { lock.lock(); defer { lock.unlock() }; return stores[id]?.store }
    }
    static let registry = Registry()
}
