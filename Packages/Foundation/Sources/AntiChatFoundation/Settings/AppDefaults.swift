// The app's own defaults domain, kept private to a DEBUG unit-test process (fix/shared-defaults-isolation).
//
// In a unit-test process (`swiftpm-testing-helper`, `xctest`) `UserDefaults.standard` is the test tool's own domain,
// which every test process on the Mac shares: every bundle of a `swift test` run and every worktree's concurrent run.
// A value one process wrote there showed in another process's snapshot (Settings › Privacy's Offline only,
// fix/vid3-flakes; the quick-panel shortcut, the chosen packs behind the Voice picker, …). Everything that is app
// state in the app's domain reads and writes `AppDefaults.standard` instead of `.standard`: the app domain in the
// app, and in a DEBUG test process an in-memory store of its own — empty at start, gone at exit, never a plist in
// ~/Library/Preferences (a removed persistent suite leaves an empty one behind).
import Foundation

public enum AppDefaults {
    /// The app domain (`.standard`), or (DEBUG test process) a private in-memory store that reads launch arguments,
    /// NSGlobalDomain and registered defaults like `.standard` does but never the shared test-tool domain.
    nonisolated(unsafe) public static let standard: UserDefaults = {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if let memory = testProcessMemory, let d = MemoryDefaults(memory: memory) { return d }
        #endif
        return .standard
    }()

    /// The `-DefaultsSuite <name>` suite of a probe or UI-test launch: the one on-disk suite a DEBUG product path makes
    /// (nil without the option, and always nil in Release, where no launch option is parsed). Every store that follows
    /// `-DefaultsSuite` reads it here. `-FreshDefaultsSuite YES` empties it first, once per process (a UI test's
    /// suite has a stable name, so runs reuse one plist instead of leaving one per run; fix/test-plist-hygiene).
    nonisolated(unsafe) public static let launchSuite: UserDefaults? = {
        guard let name = LaunchOptions.current.defaultsSuite, let d = UserDefaults(suiteName: name) else { return nil }
        if LaunchOptions.current.freshDefaultsSuite { d.removePersistentDomain(forName: name) }
        return d
    }()

    /// True when `standard` is not the real `.standard` (a DEBUG test process).
    public static var isPrivate: Bool { standard !== UserDefaults.standard }

    /// A unit-test process: the SwiftPM / Xcode test tool, or a process XCTest runs in.
    public static func isTestProcess(_ info: ProcessInfo = .processInfo) -> Bool {
        let env = info.environment
        return ["swiftpm-testing-helper", "xctest"].contains(info.processName)
            || env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
    }

    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// The values behind `standard` in a test process (nil elsewhere). `UserDefaults.antichat` falls back to the same
    /// store outside a test's settings scope, so the Settings keys and `AppDefaults.standard` agree there exactly as
    /// `.antichat` and `.standard` do in the app.
    public static let testProcessMemory: DefaultsMemory? = isTestProcess() ? DefaultsMemory(systemFallback: true) : nil
    #endif
}

#if DEBUG || ANTICHAT_PERF_HARNESS
public extension UserDefaults {
    /// A fresh in-memory defaults store for a test (DEBUG; fix/test-plist-hygiene), in place of
    /// `UserDefaults(suiteName: "<prefix>-\(UUID())")!`: each such suite was a plist in ~/Library/Preferences the
    /// first time a test wrote to it, and no test ever removed it (≈20,000 of them by M7). Misses read what a fresh
    /// suite reads (launch arguments, NSGlobalDomain, registered defaults), never the app or test-tool domain.
    /// Pass one `DefaultsMemory` to several calls for two objects over the same values (a relaunch).
    /// `TestPlistHygieneTests.noTestCreatesAnOnDiskSuite` keeps tests on it.
    static func inMemory(_ memory: DefaultsMemory = DefaultsMemory(systemFallback: true)) -> UserDefaults {
        MemoryDefaults(memory: memory)!  // a fixed suite name that is never written: cannot fail
    }
}

/// One in-memory defaults store (thread-safe; values are property-list objects as UserDefaults stores them).
public final class DefaultsMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var argumentDomain: [String: Any] = [:]
    /// On a miss: true = the suite's own search list (launch arguments, NSGlobalDomain, registered defaults — never the
    /// app domain), false = the registered defaults only (a test's settings scope).
    public let systemFallback: Bool

    public init(systemFallback: Bool = false) { self.systemFallback = systemFallback }

    public func value(_ key: String) -> Any? { lock.withLock { values[key] } }
    public func set(_ value: Any?, _ key: String) { lock.withLock { values[key] = value } }
    public var all: [String: Any] { lock.withLock { values } }
    /// The store's own NSArgumentDomain overlay (launch overrides), so a test of `-key YES` handling stays in it.
    public var arguments: [String: Any] {
        get { lock.withLock { argumentDomain } }
        set { lock.withLock { argumentDomain = newValue } }
    }
}

/// A UserDefaults whose values live in a `DefaultsMemory` (DEBUG). `memory` nil = the inherited UserDefaults
/// behaviour of the suite it was created with; subclasses pick the store per call (`UserDefaults.antichat`: the
/// test's settings scope). The suite is only a search list for misses and is never written, so no plist appears.
open class MemoryDefaults: UserDefaults {
    private let fixedMemory: DefaultsMemory?
    /// The suite name used for misses: one that nothing ever writes.
    public static let missSuite = "app.antichat.test-process-defaults"

    /// A store of its own (`AppDefaults.standard` in a test process).
    public init?(memory: DefaultsMemory) {
        fixedMemory = memory
        super.init(suiteName: Self.missSuite)
    }

    /// For subclasses that choose the store themselves (`memory`).
    public init?(suiteName: String?, memory: DefaultsMemory?) {
        fixedMemory = memory
        super.init(suiteName: suiteName)
    }

    /// The store reads and writes go to; nil = inherited behaviour.
    open var memory: DefaultsMemory? { fixedMemory }

    private func registered(_ key: String) -> Any? { super.volatileDomain(forName: UserDefaults.registrationDomain)[key] }

    /// Writes notify this object's observers (Defaults' and @AppStorage's KVO-based observation), like a stored write.
    private func write(_ m: DefaultsMemory, _ key: String, _ value: Any?) {
        willChangeValue(forKey: key)
        m.set(value, key)
        didChangeValue(forKey: key)
    }

    /// Launch arguments, then the stored values, then the fallback (UserDefaults' order).
    override open func object(forKey defaultName: String) -> Any? {
        guard let m = memory else { return super.object(forKey: defaultName) }
        if let v = m.arguments[defaultName] ?? m.value(defaultName) { return v }
        return m.systemFallback ? super.object(forKey: defaultName) : registered(defaultName)
    }

    override open func volatileDomain(forName domainName: String) -> [String: Any] {
        guard let m = memory, domainName == UserDefaults.argumentDomain else { return super.volatileDomain(forName: domainName) }
        return m.systemFallback ? super.volatileDomain(forName: domainName).merging(m.arguments) { _, new in new } : m.arguments
    }

    override open func setVolatileDomain(_ domain: [String: Any], forName domainName: String) {
        guard let m = memory, domainName == UserDefaults.argumentDomain else {
            return super.setVolatileDomain(domain, forName: domainName)
        }
        m.arguments = domain
    }

    override open func removeVolatileDomain(forName domainName: String) {
        guard let m = memory, domainName == UserDefaults.argumentDomain else { return super.removeVolatileDomain(forName: domainName) }
        m.arguments = [:]
    }

    override open func set(_ value: Any?, forKey defaultName: String) {
        guard let m = memory else { return super.set(value, forKey: defaultName) }
        write(m, defaultName, value)
    }

    override open func removeObject(forKey defaultName: String) {
        guard let m = memory else { return super.removeObject(forKey: defaultName) }
        write(m, defaultName, nil)
    }

    /// KVO reads the old/new values of a change through `value(forKey:)`.
    override open func value(forKey key: String) -> Any? {
        guard memory != nil else { return super.value(forKey: key) }
        return object(forKey: key)
    }

    override open func dictionaryRepresentation() -> [String: Any] {
        guard let m = memory else { return super.dictionaryRepresentation() }
        let base = m.systemFallback ? super.dictionaryRepresentation() : super.volatileDomain(forName: UserDefaults.registrationDomain)
        return base.merging(m.all) { _, new in new }.merging(m.arguments) { _, new in new }
    }

    // The typed accessors, so they read and write the same store (without one they are the inherited implementations).
    override open func set(_ value: Bool, forKey defaultName: String) {
        guard memory != nil else { return super.set(value, forKey: defaultName) }
        set(NSNumber(value: value), forKey: defaultName)
    }
    override open func set(_ value: Int, forKey defaultName: String) {
        guard memory != nil else { return super.set(value, forKey: defaultName) }
        set(NSNumber(value: value), forKey: defaultName)
    }
    override open func set(_ value: Double, forKey defaultName: String) {
        guard memory != nil else { return super.set(value, forKey: defaultName) }
        set(NSNumber(value: value), forKey: defaultName)
    }
    override open func set(_ value: Float, forKey defaultName: String) {
        guard memory != nil else { return super.set(value, forKey: defaultName) }
        set(NSNumber(value: value), forKey: defaultName)
    }
    override open func set(_ url: URL?, forKey defaultName: String) {
        guard memory != nil else { return super.set(url, forKey: defaultName) }
        set(url.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }, forKey: defaultName)
    }
    override open func bool(forKey defaultName: String) -> Bool {
        guard memory != nil else { return super.bool(forKey: defaultName) }
        switch object(forKey: defaultName) {
        case let n as NSNumber: return n.boolValue
        case let s as String: return (s as NSString).boolValue
        default: return false
        }
    }
    override open func integer(forKey defaultName: String) -> Int {
        guard memory != nil else { return super.integer(forKey: defaultName) }
        switch object(forKey: defaultName) {
        case let n as NSNumber: return n.intValue
        case let s as String: return (s as NSString).integerValue
        default: return 0
        }
    }
    override open func double(forKey defaultName: String) -> Double {
        guard memory != nil else { return super.double(forKey: defaultName) }
        switch object(forKey: defaultName) {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return (s as NSString).doubleValue
        default: return 0
        }
    }
    override open func float(forKey defaultName: String) -> Float { Float(double(forKey: defaultName)) }
    override open func string(forKey defaultName: String) -> String? {
        guard memory != nil else { return super.string(forKey: defaultName) }
        switch object(forKey: defaultName) {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
    override open func array(forKey defaultName: String) -> [Any]? {
        guard memory != nil else { return super.array(forKey: defaultName) }
        return object(forKey: defaultName) as? [Any]
    }
    override open func dictionary(forKey defaultName: String) -> [String: Any]? {
        guard memory != nil else { return super.dictionary(forKey: defaultName) }
        return object(forKey: defaultName) as? [String: Any]
    }
    override open func data(forKey defaultName: String) -> Data? {
        guard memory != nil else { return super.data(forKey: defaultName) }
        return object(forKey: defaultName) as? Data
    }
    override open func stringArray(forKey defaultName: String) -> [String]? {
        guard memory != nil else { return super.stringArray(forKey: defaultName) }
        return object(forKey: defaultName) as? [String]
    }
    override open func url(forKey defaultName: String) -> URL? {
        guard memory != nil else { return super.url(forKey: defaultName) }
        switch object(forKey: defaultName) {
        case let d as Data: return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: d) as URL?
        case let s as String: return URL(string: s)
        default: return nil
        }
    }
}
#endif
