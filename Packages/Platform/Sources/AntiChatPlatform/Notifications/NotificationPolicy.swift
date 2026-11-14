// M8.T12 step 3 (R-108 AC1): whether an event notifies. Never → no; the category's group off → no; Always → yes;
// Only when unfocused → AntiChat is not the active app, or its main window is not the key window, or (chat-bound
// categories) the chat the event belongs to is not the one on screen.
import Foundation

public struct NotificationPolicy: Sendable, Equatable {
    public var when: NotifyWhen
    public var groups: Set<NotificationGroup>

    public init(when: NotifyWhen = .unfocused, groups: Set<NotificationGroup> = Set(NotificationGroup.allCases)) {
        self.when = when
        self.groups = groups
    }

    /// What the app looked like when the event happened.
    public struct Focus: Sendable, Equatable {
        /// `NSApp.isActive`.
        public var appActive: Bool
        /// A main window of AntiChat is the key window.
        public var mainWindowKey: Bool
        /// The event's chat is the one shown in the key main window (ignored for downloads and updates).
        public var chatVisible: Bool

        public init(appActive: Bool, mainWindowKey: Bool, chatVisible: Bool) {
            self.appActive = appActive
            self.mainWindowKey = mainWindowKey
            self.chatVisible = chatVisible
        }

        /// The user is looking at AntiChat's main window.
        public var focused: Bool { appActive && mainWindowKey }
    }

    public func shouldNotify(_ category: NotificationCategory, focus: Focus) -> Bool {
        guard groups.contains(category.group) else { return false }
        switch when {
        case .never: return false
        case .always: return true
        case .unfocused:
            if !focus.focused { return true }
            return category.isChatBound && !focus.chatVisible
        }
    }
}
