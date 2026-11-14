// AutoArchiveService (M1.T22 step 5; R-011 AC4 "Auto-archive inactive chats", settings-map §9): once a day,
// archives every chat inactive for the chosen number of days (Never = 0 = off). The clock, the setting and the
// "last run" stamp are injected, so tests drive it on a virtual clock (`-FixedClock` in the app).
import AntiChatFoundation
import Foundation

public final class AutoArchiveService: @unchecked Sendable {
    public static let interval: TimeInterval = 86_400

    private let chats: ChatListService
    private let now: @Sendable () -> Date
    private let days: @Sendable () -> Int
    private let loadLastRun: @Sendable () -> Date?
    private let saveLastRun: @Sendable (Date) -> Void
    private let lock = NSLock()
    private var timer: Timer?

    /// - Parameters:
    ///   - days: the setting (0 = Never).
    ///   - lastRun / saveLastRun: the persisted stamp of the previous daily run.
    public init(chats: ChatListService, now: @escaping @Sendable () -> Date = { Date() },
                days: @escaping @Sendable () -> Int, lastRun: @escaping @Sendable () -> Date?,
                saveLastRun: @escaping @Sendable (Date) -> Void) {
        self.chats = chats
        self.now = now
        self.days = days
        self.loadLastRun = lastRun
        self.saveLastRun = saveLastRun
    }

    /// True when a daily run is due at `date`: never run, or ≥ 24 h since the last run (or the clock went back).
    public func isDue(at date: Date) -> Bool {
        guard let last = loadLastRun() else { return true }
        let elapsed = date.timeIntervalSince(last)
        return elapsed >= Self.interval || elapsed < 0
    }

    /// The daily run: when due, stamps the run and (unless the setting is Never) archives inactive chats.
    /// Returns the archived ids (empty when not due or Never).
    @discardableResult
    public func runIfDue() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let t = now()
        guard isDue(at: t) else { return [] }
        saveLastRun(t)
        let d = days()
        guard d > 0 else { return [] }
        do {
            let ids = try chats.archiveInactive(days: d, now: t)
            if !ids.isEmpty { AppLog.log(.harness, .info, "auto-archive: \(ids.count) chat(s) inactive ≥ \(d) days") }
            return ids
        } catch {
            AppLog.log(.harness, .error, "auto-archive failed: \(error)")
            return []
        }
    }

    /// Runs now if due, then checks hourly (a sleeping Mac catches up on wake through the next check).
    @MainActor
    public func start(checkEvery: TimeInterval = 3600) {
        runIfDue()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: checkEvery, repeats: true) { [weak self] _ in self?.runIfDue() }
    }

    @MainActor
    public func stop() {
        timer?.invalidate()
        timer = nil
    }
}
