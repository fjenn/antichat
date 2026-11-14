// M8.T10 step 7 (R-205 AC4, NFR-D7; P-platform-07 removal plan, Hob design): one action that removes models, chats,
// media, caches, logs, preferences and Keychain items, then relaunches into onboarding (the app bundle stays; M8.T11's
// Uninstall reuses `plan` + `removeAppState` and adds the detached waiter). The app-specific steps are hooks (the
// composition root wires them: cancel jobs/downloads, evict + stop the helper, relay forget, login item, hotkeys), so
// the deletion order is testable with `ANTICHAT_ROOT` / a scratch `DataPaths`.
import Foundation

public struct RemovalHooks: Sendable {
    /// Cancel downloads, media jobs and index jobs.
    public var cancelJobs: @Sendable () async -> Void = {}
    /// Evict every model and stop the helper (`Evict` all, then the session ends; ≤ 5 s).
    public var stopEngine: @Sendable () async -> Void = {}
    /// Best-effort relay `forget` (5 s); returns a note for the result ("skipped: Offline only", "not configured" …).
    public var relayForget: @Sendable () async -> String = { "not configured" }
    /// `SMAppService.mainApp.unregister()`.
    public var unregisterLoginItem: @MainActor @Sendable () -> Void = {}
    /// `KeyboardShortcuts.reset(...)` for every registered name.
    public var resetShortcuts: @MainActor @Sendable () -> Void = {}
    /// `UNUserNotificationCenter.removeAllDeliveredNotifications()` (Uninstall).
    public var clearNotifications: @MainActor @Sendable () -> Void = {}

    /// The three main-actor steps, in order.
    func systemSteps() async {
        let h = self
        await MainActor.run {
            h.unregisterLoginItem()
            h.resetShortcuts()
            h.clearNotifications()
        }
    }
    public init() {}
}

public struct RemovalResult: Sendable, Equatable {
    public var removed: [String]
    /// Paths that still exist after deletion (should be empty).
    public var leftovers: [String]
    public var keychainLeft: [String]
    public var relayNote: String
}

public struct RemoveEverythingService: Sendable {
    public let paths: DataPaths
    public let hooks: RemovalHooks
    /// Keychain prefix (tests use a unique one).
    public var keychainPrefix = DataPaths.keychainPrefix
    /// UserDefaults domain to remove (nil = `paths.bundleID`).
    public var defaultsDomain: String?

    public init(paths: DataPaths, hooks: RemovalHooks = RemovalHooks()) { self.paths = paths; self.hooks = hooks }

    /// The absolute paths `run` deletes, in order (the Models folder first, wherever it is; `Models-internal` is inside
    /// the container). Never a path outside `DataPaths`.
    public func plan(fileManager fm: FileManager = .default) -> [URL] {
        var out: [URL] = []
        if !paths.modelsAreInsideContainer { out.append(paths.models) }
        out += paths.existing(fileManager: fm).filter { $0 != paths.models }
        if !out.contains(paths.container) { out.append(paths.container) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Steps 1–6 of NFR-D7 (everything but the relaunch).
    public func run() async -> RemovalResult {
        await hooks.cancelJobs()
        await hooks.stopEngine()
        let relay = await hooks.relayForget()
        // The system steps write preferences (KeyboardShortcuts.reset stores each default shortcut), so they run
        // before the domain is removed; the domain goes before the files, because cfprefsd leaves an empty
        // `<domain>.plist` behind when a populated domain is deleted (M8.T16 Tart run).
        await hooks.systemSteps()
        let keychainLeft = KeychainInventory.deleteAll(prefix: keychainPrefix)
        removeDefaults()
        let targets = plan()
        let fm = FileManager.default
        var removed: [String] = []
        for u in targets where fm.fileExists(atPath: u.path) {
            if (try? fm.removeItem(at: u)) != nil { removed.append(u.path) }
        }
        let left = plan(fileManager: fm).filter { fm.fileExists(atPath: $0.path) }.map(\.path)
        return RemovalResult(removed: removed, leftovers: left, keychainLeft: keychainLeft, relayNote: relay)
    }

    func removeDefaults() {
        let domain = defaultsDomain ?? paths.bundleID
        UserDefaults.standard.removePersistentDomain(forName: domain)
        CFPreferencesAppSynchronize(domain as CFString)
    }
}
