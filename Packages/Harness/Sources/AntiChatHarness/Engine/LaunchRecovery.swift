// LaunchRecovery (M1.T12 step 6; R-208 AC2/AC4): runs once when the app opens its database, before the UI reads
// it. After a crash or a kill of the app: replies that were streaming come back `interrupted` (UI: the partial
// reply + InterruptedNotice + [Retry], NFR-S2), media jobs that were running become `lost` (UI `img.lost` +
// [Retry]; the M4 job card renders it, M1 renders an ErrorInline "Interrupted" + Retry for fixture rows), and
// downloads that were in flight go back to `queued` so the M2 download coordinator resumes them.
import AntiChatFoundation
import AntiChatStorage
import Foundation

public enum LaunchRecovery {
    public typealias Report = RecoveryRepository.Result

    /// The sweep on an open database; logs what it changed.
    @discardableResult
    public static func run(on database: AppDatabase) throws -> Report {
        let report = try RecoveryRepository(database).sweepAfterCrash()
        if !report.isEmpty {
            AppLog.log(
                .store, .notice,
                "launch recovery: \(report.interruptedMessages.count) message(s) interrupted, \(report.lostJobs.count) job(s) lost, \(report.requeuedDownloads.count) download(s) re-queued")
        }
        return report
    }

    /// Opens the app database (`-ANTICHAT_DEV_CONTAINER` aware) and runs the sweep: the one entry point the app
    /// uses at launch.
    public static func openDatabase(options: LaunchOptions = .current) throws -> (AppDatabase, Report) {
        let db = try AppDatabase.openDefault(options: options)
        return (db, try run(on: db))
    }
}
