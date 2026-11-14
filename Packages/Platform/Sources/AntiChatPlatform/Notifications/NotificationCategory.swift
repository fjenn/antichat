// M8.T12 step 1 (R-108 AC1, G-063): the five notification categories and the four Settings groups that switch them.
// Each category is registered with UNUserNotificationCenter under its raw value, with one action `open`
// (`notif.open`); the Settings groups map Responses = answer, Media jobs = image + video, Downloads = download,
// Updates = update.
import Foundation

public enum NotificationCategory: String, Sendable, CaseIterable, Codable {
    case answer, image, video, download, update

    /// The Settings toggle that switches this category.
    public var group: NotificationGroup {
        switch self {
        case .answer: .responses
        case .image, .video: .media
        case .download: .downloads
        case .update: .updates
        }
    }

    /// The event belongs to one chat: under "Only when unfocused" it also notifies while that chat is not the
    /// one on screen (A-M8-T12a: answers per the task, pictures and videos per R-042 "leave the chat").
    public var isChatBound: Bool { self == .answer || self == .image || self == .video }
}

/// Settings › General › Notifications category toggles (settings-map §1 "Notifications: categories").
public enum NotificationGroup: String, Sendable, CaseIterable, Codable {
    case responses, media, downloads, updates
}

/// Settings › General › "Notify me" (settings-map §1 "Notifications: when").
public enum NotifyWhen: String, Sendable, CaseIterable, Codable {
    case unfocused, always, never
}

/// The `UNNotificationAction` id every category carries.
public enum NotificationAction {
    public static let open = "open"
}
