// M5.T10 step 5 (R-040 AC2 "notifies on completion", R-108): when a media job ends with a result (`jobResult`), the
// app posts `MediaJobCompleted{kind, chatID}` to the `MediaCompletionService` interface (the default only logs; tests
// install a recording sink). The system notification itself (`notif.video`, the click that opens the chat) is M8.T12's
// `NotificationService`, fed by the generic media job queue (`MediaJobQueue.subscribe`), so this seam never delivers.
// Nothing here sees the job's pixels or prompt: the event carries the kind, the chat and the job id.
import AntiChatFoundation
import Foundation
import Synchronization

/// What finished (architecture §5.1 `media_job.kind` families that notify).
public enum MediaCompletionKind: String, Sendable, Codable, Equatable { case image, video }

/// One finished media job.
public struct MediaJobCompleted: Sendable, Equatable, Codable {
    public var kind: MediaCompletionKind
    public var chatID: String
    public var jobID: String
    public var date: Date

    public init(kind: MediaCompletionKind, chatID: String, jobID: String, date: Date = Date()) {
        self.kind = kind; self.chatID = chatID; self.jobID = jobID; self.date = date
    }
}

/// Where M5 posts finished media jobs (log / test sink; delivery is M8.T12's `NotificationService`).
public protocol MediaCompletionService: Sendable {
    func post(_ event: MediaJobCompleted)
}

/// The event is logged (M8.T12 delivers the notification from the queue).
public struct LoggingNotificationService: MediaCompletionService {
    public init() {}
    public func post(_ event: MediaJobCompleted) {
        AppLog.log(.ui, .info, "media job completed: \(event.kind.rawValue) chat=\(event.chatID) job=\(event.jobID)")
    }
}

/// The test sink: records every posted event in order.
public final class RecordingNotificationSink: MediaCompletionService, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [MediaJobCompleted] = []
    public init() {}
    public func post(_ event: MediaJobCompleted) { lock.withLock { recorded.append(event) } }
    public var events: [MediaJobCompleted] { lock.withLock { recorded } }
}

/// The process's completion events: one service (the logger until M8; a sink in tests).
public enum MediaCompletionEvents {
    private static let current = Mutex<any MediaCompletionService>(LoggingNotificationService())

    public static var service: any MediaCompletionService {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }

    /// Posts `MediaJobCompleted` for a job that ended with a result (the only state that notifies).
    public static func jobResult(kind: MediaCompletionKind, chatID: String, jobID: String) {
        service.post(MediaJobCompleted(kind: kind, chatID: chatID, jobID: jobID))
    }
}
