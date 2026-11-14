// M8.T12 step 7 (R-042 AC2, R-108): a clicked notification → where the app goes. `userInfo` carries `chatID` and
// (for answers and finished media) `messageID`; the app brings itself forward, opens the chat and scrolls to that
// message (the result card) and flashes it. A click that arrives before the app's windows exist (a cold launch
// from Notification Center) is held until a handler is installed.
import Foundation

public struct NotificationRoute: Sendable, Hashable, Codable {
    public var chatID: String?
    public var messageID: String?
    public var category: NotificationCategory?

    public init(chatID: String?, messageID: String?, category: NotificationCategory?) {
        self.chatID = chatID
        self.messageID = messageID
        self.category = category
    }

    public static let chatKey = "chatID", messageKey = "messageID", categoryKey = "category"

    /// The notification's `userInfo` (only string values are read).
    public init?(userInfo: [AnyHashable: Any]) {
        let chat = (userInfo[Self.chatKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let message = (userInfo[Self.messageKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let category = (userInfo[Self.categoryKey] as? String).flatMap(NotificationCategory.init(rawValue:))
        guard chat != nil || category != nil else { return nil }
        self.init(chatID: chat, messageID: message, category: category)
    }

    public var userInfo: [String: String] {
        var d: [String: String] = [:]
        if let chatID { d[Self.chatKey] = chatID }
        if let messageID { d[Self.messageKey] = messageID }
        if let category { d[Self.categoryKey] = category.rawValue }
        return d
    }
}

/// Where the app should go for a route (the UI performs it).
public enum NotificationDestination: Sendable, Equatable {
    /// Open the chat, scroll to `messageID` (nil = the end) and flash it.
    case chat(id: String, messageID: String?)
    /// A finished download: Settings › Capabilities.
    case capabilities
    /// An update ready to install: Settings › Updates.
    case updates
    /// Nothing to open beyond bringing the app forward.
    case app
}

@MainActor
public final class NotificationRouter {
    public static let shared = NotificationRouter()

    /// Performs a destination (set by the app once its windows exist).
    public var handler: ((NotificationDestination) -> Void)? {
        didSet {
            guard let handler, !held.isEmpty else { return }
            let pending = held
            held = []
            pending.forEach(handler)
        }
    }

    private var held: [NotificationDestination] = []
    /// Every routed destination (tests, probes).
    public private(set) var routed: [NotificationDestination] = []

    public init() {}

    public static func destination(for route: NotificationRoute) -> NotificationDestination {
        if let chat = route.chatID { return .chat(id: chat, messageID: route.messageID) }
        switch route.category {
        case .download: return .capabilities
        case .answer, .image, .video: return .app  // an incognito chat (no id travels)
        case .update: return .updates
        default: return .app
        }
    }

    /// A click on a delivered notification (default action or `open`).
    public func open(userInfo: [AnyHashable: Any]) {
        route(NotificationRoute(userInfo: userInfo).map(Self.destination(for:)) ?? .app)
    }

    public func route(_ d: NotificationDestination) {
        routed.append(d)
        if let handler { handler(d) } else { held.append(d) }
    }
}
