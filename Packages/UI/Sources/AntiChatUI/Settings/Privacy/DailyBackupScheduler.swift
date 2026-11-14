// M8.T01 step 2 (R-301 AC2): the daily rolling backup. Every 10 minutes (and 2 minutes after launch) it checks:
// the app has been idle ≥ 60 s (no input event: `CGEventSource` combined session state), no reply is streaming or
// pending, and the newest `daily-*` is older than 24 h; then `BackupService.dailyIfDue` runs at `.utility` and prunes
// to 7 daily + 3 pre-update copies. Never for the in-memory (incognito / fallback) database.
import AntiChatFoundation
import AntiChatStorage
import CoreGraphics
import Foundation
import GRDB

@MainActor
public final class DailyBackupScheduler {
    public static let idleSeconds: Double = 60
    private var timer: Timer?
    private let database: AppDatabase
    private let service: BackupService
    private var running = false

    public init?(database: AppDatabase) {
        guard let url = database.fileURL else { return nil }
        self.database = database
        let fixed = LaunchOptions.current.fixedClock
        service = BackupService(databaseURL: url, now: { fixed ?? Date() })
    }

    @discardableResult
    public static func start(database: AppDatabase) -> DailyBackupScheduler? {
        guard let s = DailyBackupScheduler(database: database) else { return nil }
        s.timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak s] _ in MainActor.assumeIsolated { s?.tick() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak s] in s?.tick() }
        return s
    }

    /// Seconds since the last keyboard/mouse event in this login session.
    static func systemIdleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func tick() {
        guard !running, Self.systemIdleSeconds() >= Self.idleSeconds else { return }
        let busy = (try? database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM message WHERE status IN ('pending', 'streaming')") }) ?? 1
        guard busy == 0 else { return }
        running = true
        let service = service, reader = database.reader
        Task.detached(priority: .utility) {
            do { try service.dailyIfDue(from: reader) } catch { AppLog.log(.store, .error, "backup: daily failed: \(error)") }
            await MainActor.run { self.running = false }
        }
    }
}
