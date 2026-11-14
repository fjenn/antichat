import AntiChatEngineProtocol
import Foundation

public actor SessionIdleReaper {
    /// The app's one reaper (review #11: a reaper per registration left the old one's pending reset running, which
    /// reset a chat still in use 10 minutes after its last touch with the old reaper).
    public static let shared = SessionIdleReaper()

    public let idle: Duration
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(idle: Duration = .seconds(FileToolsProtocol.idleSeconds)) { self.idle = idle }

    public func touch<C: Clock>(chatID: String, clock: C, reset: @escaping @Sendable () async -> Void) where C.Duration == Duration {
        tasks[chatID]?.cancel()
        let delay = idle
        tasks[chatID] = Task {
            do {
                try await clock.sleep(for: delay)
                await reset()
            } catch {}
        }
    }

    public func cancel(chatID: String) {
        tasks.removeValue(forKey: chatID)?.cancel()
    }

    public func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }
}
