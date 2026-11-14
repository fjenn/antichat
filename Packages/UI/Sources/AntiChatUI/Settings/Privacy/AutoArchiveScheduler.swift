// App wiring of the daily auto-archive run (M1.T22 step 5): the Harness `AutoArchiveService` with the Settings
// value (`autoArchiveDays`), the clock (`-FixedClock` in DEBUG) and the last-run stamp. The stamp is app state,
// not a setting, so it is not in Keys.swift / settings-map.
import AntiChatFoundation
import AntiChatHarness
import Defaults
import Foundation

public enum AutoArchiveScheduler {
    static let lastRunKey = "autoArchiveLastRun"

    @MainActor
    public static func start(chats: ChatListService) -> AutoArchiveService {
        let fixed = LaunchOptions.current.fixedClock
        let service = AutoArchiveService(
            chats: chats,
            now: { fixed ?? Date() },
            days: { Defaults[.autoArchiveDays] },
            lastRun: { UserDefaults.antichat.object(forKey: lastRunKey) as? Date },
            saveLastRun: { UserDefaults.antichat.set($0, forKey: lastRunKey) })
        service.start()
        return service
    }
}
