// Last-shown chat per window, kept in the app's own store (M10.T09 AT-FA-10 finding 8; R-208 AC2, NFR-S2).
// macOS window restoration (WindowRestoration: the WindowGroup value) reopens each window's chat after a normal quit,
// but it saves its state lazily: a `kill -9`, force quit or crash shortly after the user opened or started a chat
// reopened the killed chat in only 1 of 2 AT-FA-10 runs. So the app writes what each window shows to
// `<container>/last-shown-chats.json` itself:
//   - a switch of the shown chat is written at once (flushed); the window that became key only reorders the entries,
//     which is written debounced (1 s);
//   - an incognito chat is never written (R-090: the window keeps the entry of the last saved chat it showed, so the
//     incognito session leaves no file change) and never reopened;
//   - `running` is true while the app runs; a normal quit (applicationWillTerminate) sets it false.
// At launch after an unclean exit (`running` still true), each main window takes its entry back: a window macOS
// restored by its SceneStorage key (the store's entry is newer than the restored value), the first window macOS did
// not restore the most recently active entry, and entries left over open their own windows. A normal quit keeps
// macOS's own restoration untouched. Off when the user chose to close windows when quitting
// (`NSQuitAlwaysKeepsWindows` false in the global domain), for `-ApplePersistenceIgnoreState YES` launches (UI tests,
// probes: no reads and no writes), in-memory databases and test hosts.
import AntiChatFoundation
import AntiChatStorage
import Foundation

/// The file's content.
public struct LastShownSnapshot: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        /// The window's own key (SceneStorage `windowKey`, so a window macOS restores keeps it).
        public var key: String
        /// The saved chat the window showed; nil = no chat (a new chat, a page).
        public var chatID: String?
        /// When the window last switched chat or became key (orders the entries, newest first).
        public var active: Date

        public init(key: String, chatID: String?, active: Date) {
            self.key = key; self.chatID = chatID; self.active = active
        }
    }

    /// True from launch until a normal quit: still true at the next launch = the app was killed or crashed.
    public var running: Bool
    public var windows: [Window]

    public init(running: Bool, windows: [Window]) {
        self.running = running; self.windows = windows
    }
}

/// What a window shows at launch (the pure launch decision).
public enum LaunchReopen {
    public enum Claim: Equatable, Sendable {
        /// Keep what the window has (its restored value, or a new chat).
        case keep
        /// Show this saved chat.
        case open(String)
    }

    /// The entries to reopen at this launch: the previous run's windows, most recently active first; none after a
    /// normal quit (macOS restoration covers it) or when reopening is off.
    public static func pending(previous: LastShownSnapshot?, reopenAllowed: Bool) -> [LastShownSnapshot.Window] {
        guard reopenAllowed, let previous, previous.running else { return [] }
        return previous.windows.sorted { $0.active > $1.active }
    }

    /// One window's claim. `key`: the window's restored SceneStorage key (nil when macOS did not restore it);
    /// `restored`: its restored WindowGroup value; `freshClaimed`: a non-restored window already took the newest entry.
    /// Claimed entries leave `pending`. A chat that no longer exists is never opened.
    public static func claim(key: String?, restored: MainWindowValue?, pending: inout [LastShownSnapshot.Window],
                             freshClaimed: inout Bool, exists: (String) -> Bool) -> Claim {
        guard !pending.isEmpty, restored != .incognito else { return .keep }
        let entry: LastShownSnapshot.Window
        if let key, let i = pending.firstIndex(where: { $0.key == key }) {
            entry = pending.remove(at: i)
        } else if key == nil, restored == nil, !freshClaimed {
            freshClaimed = true
            entry = pending.removeFirst()
        } else {
            return .keep
        }
        guard let id = entry.chatID, id != restored?.chatID, exists(id) else { return .keep }
        return .open(id)
    }

    /// The user's "reopen windows" choice: System Settings › Desktop & Dock › "Close windows when quitting an
    /// application" writes `NSQuitAlwaysKeepsWindows` to the global domain; unset, the app keeps its windows
    /// (AppDelegate registers true).
    public static func userKeepsWindows(_ defaults: UserDefaults = AppDefaults.standard) -> Bool {
        defaults.object(forKey: "NSQuitAlwaysKeepsWindows") as? Bool ?? true
    }
}

@MainActor
public final class LastShownChatStore {
    /// The app's store (`<container>/last-shown-chats.json`); `start()` turns it on at launch.
    public static let shared = LastShownChatStore(url: AppDatabase.containerURL().appendingPathComponent(fileName))
    public static let fileName = "last-shown-chats.json"
    /// Window-became-key reorders are written this long after the last one (a switch is written at once).
    public static let debounce: Duration = .seconds(1)
    /// Entries no window claimed by then open their own windows (restored windows appear within the first second).
    public static let extrasDelay: Duration = .milliseconds(1500)

    public let url: URL
    private let now: () -> Date
    private let debounce: Duration
    public private(set) var isOn = false
    private var snapshot = LastShownSnapshot(running: true, windows: [])
    /// The previous run's entries still to be claimed (empty after a normal quit).
    public private(set) var pending: [LastShownSnapshot.Window] = []
    private var freshClaimed = false
    private var extrasScheduled = false
    private var liveKeys: Set<String> = []
    private var dirty = false
    private var writeTask: Task<Void, Never>?
    /// What `start()` found (diagnostics, the AT-FA-10 probe).
    public private(set) var launchSummary = "off"
    /// The chats the windows took back at this launch (diagnostics, the AT-FA-10 probe).
    public private(set) var reopened: [String] = []
    /// Number of file writes (tests).
    public private(set) var writes = 0

    public init(url: URL, debounce: Duration = LastShownChatStore.debounce, now: @escaping () -> Date = Date.init) {
        self.url = url; self.debounce = debounce; self.now = now
    }

    /// Whether this process keeps the store: the app itself (not a test host), saved state not ignored, an on-disk
    /// database.
    public static func wanted(defaults: UserDefaults = AppDefaults.standard, environment: [String: String] = ProcessInfo.processInfo.environment,
                              bundleURL: URL = Bundle.main.bundleURL, inMemoryDatabase: Bool) -> Bool {
        !inMemoryDatabase && bundleURL.pathExtension == "app" && !defaults.bool(forKey: "ApplePersistenceIgnoreState")
            && environment["XCTestConfigurationFilePath"] == nil && environment["XCTestBundlePath"] == nil
    }

    /// Launch (once, before any window): reads the previous run's file, decides what to reopen, and marks this run
    /// as running. After an unclean exit the previous entries stay in the file until the windows have claimed them,
    /// so a crash during launch loses nothing.
    public func start(reopenAllowed: Bool) {
        guard !isOn else { return }
        isOn = true
        let previous = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.lastShown.decode(LastShownSnapshot.self, from: $0) }
        pending = LaunchReopen.pending(previous: previous, reopenAllowed: reopenAllowed)
        let carried = previous?.running == true ? previous?.windows ?? [] : []
        snapshot = LastShownSnapshot(running: true, windows: carried)
        launchSummary = "previous run \(previous == nil ? "none" : previous!.running ? "unclean" : "clean"), reopen \(pending.count) window(s)"
        AppLog.log(.ui, .info, "last-shown chats: \(launchSummary)")
        flush()
    }

    // MARK: Launch claims

    /// A main window's launch decision (`WindowRestoration.apply`); see `LaunchReopen.claim`.
    public func claim(key: String?, restored: MainWindowValue?, exists: (String) -> Bool) -> LaunchReopen.Claim {
        guard isOn else { return .keep }
        let c = LaunchReopen.claim(key: key, restored: restored, pending: &pending, freshClaimed: &freshClaimed, exists: exists)
        if case .open(let id) = c { reopened.append(id) }
        return c
    }

    /// Once per launch, after `extrasDelay`: the chats of entries no window claimed (each opens its own window);
    /// entries of windows that are gone leave the file.
    public func scheduleExtras(open: @escaping @MainActor ([String]) -> Void) {
        guard isOn, !extrasScheduled else { return }
        extrasScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.extrasDelay)
            self?.settleLaunch(open: open)
        }
    }

    /// The extras step itself (tests call it directly).
    public func settleLaunch(open: @MainActor ([String]) -> Void) {
        let ids = pending.compactMap(\.chatID)
        pending = []
        freshClaimed = true
        let before = snapshot.windows.count
        snapshot.windows.removeAll { !liveKeys.contains($0.key) }
        if snapshot.windows.count != before { flush() }
        reopened += ids
        if !ids.isEmpty { open(ids) }
    }

    // MARK: Updates

    /// The window shows `chatID` (nil: no saved chat). Written at once when it changed. Incognito: nothing is
    /// written (the window keeps its last saved chat's entry).
    public func shown(key: String, chatID: String?, incognito: Bool) {
        guard isOn, !key.isEmpty else { return }
        liveKeys.insert(key)
        guard !incognito else { return }
        if let i = snapshot.windows.firstIndex(where: { $0.key == key }) {
            guard snapshot.windows[i].chatID != chatID else { return }
            snapshot.windows[i].chatID = chatID
            snapshot.windows[i].active = now()
        } else {
            snapshot.windows.append(.init(key: key, chatID: chatID, active: now()))
        }
        flush()
    }

    /// The window became key: it moves to the front (debounced write). Incognito windows are not recorded.
    public func activated(key: String, incognito: Bool) {
        guard isOn, !incognito, let i = snapshot.windows.firstIndex(where: { $0.key == key }) else { return }
        snapshot.windows[i].active = now()
        dirty = true
        writeTask?.cancel()
        let d = debounce
        writeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: d)
            guard !Task.isCancelled, let self, self.dirty else { return }
            self.flush()
        }
    }

    /// The window was closed: its entry goes (a closed window is not reopened).
    public func closed(key: String) {
        guard isOn else { return }
        liveKeys.remove(key)
        let before = snapshot.windows.count
        snapshot.windows.removeAll { $0.key == key }
        if snapshot.windows.count != before { flush() }
    }

    /// A normal quit (applicationWillTerminate): the next launch leaves reopening to macOS restoration.
    public func cleanExit() {
        guard isOn else { return }
        snapshot.running = false
        flush()
    }

    /// The current content (tests, diagnostics).
    public var current: LastShownSnapshot { snapshot }

    /// Writes the snapshot now (atomic replace; a few hundred bytes).
    public func flush() {
        writeTask?.cancel()
        writeTask = nil
        dirty = false
        guard isOn, let data = try? JSONEncoder.lastShown.encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            writes += 1
        } catch {
            AppLog.log(.ui, .error, "last-shown chats: write failed: \(error)")
        }
    }
}

private extension JSONEncoder {
    static var lastShown: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

private extension JSONDecoder {
    static var lastShown: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
