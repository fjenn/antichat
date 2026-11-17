// M8.T12 (R-108, R-042 AC2; G-063). Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Services/
// NotificationService.swift (MIT, P-platform-15): the lazy `UNUserNotificationCenter` behind a headless guard (no
// crash in `swift test` / CLI processes without a bundle id), one category per kind with an Open action, and the
// delegate's `willPresent` / `didReceive` routing. Changes: the plugin / agent / peer / model posts are removed; the
// launch-time authorization request is removed (R-109: just in time, on the first event that would notify, after
// the in-app explainer, through `PermissionCoordinator`); categories are AntiChat's five (`NotificationCategory`);
// every post goes through `NotificationPolicy` (Only when unfocused / Always / Never, per Settings group) and the
// user's sound; `didReceive` hands `userInfo` to `NotificationRouter` (chat + result message).
//
// The system calls sit behind `UserNotificationClient` so tests and `-NotificationSpy <file>` (DEBUG) record the
// requests instead of delivering them.
import AntiChatFoundation
import AppKit
import Foundation
import Observation
import UserNotifications

/// One notification as AntiChat builds it (what the spy records; `UNNotificationRequest` is made from it).
public struct NotificationRequestSpec: Sendable, Hashable, Codable {
    public var id: String
    public var category: NotificationCategory
    public var title: String
    public var body: String
    /// `nil` = silent, `"default"` = the system default sound, else a sound file name (`"Glass.aiff"`).
    public var sound: String?
    public var threadID: String?
    public var userInfo: [String: String]

    public init(id: String, category: NotificationCategory, title: String, body: String, sound: String?,
                threadID: String?, userInfo: [String: String]) {
        self.id = id
        self.category = category
        self.title = title
        self.body = body
        self.sound = sound
        self.threadID = threadID
        self.userInfo = userInfo
    }
}

/// The sound picker's value (settings-map §1 "Notification sound"): `default`, `none` or a system sound name.
public enum NotificationSound: Sendable, Hashable {
    case systemDefault, none, named(String)

    public init(rawValue: String) {
        switch rawValue {
        case "", "default": self = .systemDefault
        case "none": self = .none
        default: self = .named(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .systemDefault: "default"
        case .none: "none"
        case .named(let n): n
        }
    }

    /// `NotificationRequestSpec.sound`.
    public var specValue: String? {
        switch self {
        case .systemDefault: "default"
        case .none: nil
        case .named(let n): "\(n).aiff"
        }
    }

    /// The names in `/System/Library/Sounds/*.aiff` (Basso … Tink), sorted.
    public static func systemSoundNames(directory: URL = URL(fileURLWithPath: "/System/Library/Sounds")) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "aiff" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }
}

/// What happened (the app's turn, media job, download and update events, M8.T12 step 6).
public struct NotificationEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case answer
        case image(failed: Bool)
        case video(failed: Bool)
        case download(pack: String)
        case update(version: String)
    }

    public var kind: Kind
    public var chatID: String?
    /// The reply, or the message holding the result card.
    public var messageID: String?
    /// The chat's title (nil = untitled).
    public var chatTitle: String?
    public var incognito: Bool
    public var evil: Bool

    public init(kind: Kind, chatID: String? = nil, messageID: String? = nil, chatTitle: String? = nil, incognito: Bool = false,
                evil: Bool = false) {
        self.kind = kind
        self.chatID = chatID
        self.messageID = messageID
        self.chatTitle = chatTitle
        self.incognito = incognito
        self.evil = evil
    }

    public var category: NotificationCategory {
        switch kind {
        case .answer: .answer
        case .image: .image
        case .video: .video
        case .download: .download
        case .update: .update
        }
    }
}

/// Builds the notification text (M8.T12 step 6). `text(key, args)` resolves a copy-deck key (AntiChatDesign's
/// `CopyKey`, injected: Platform does not depend on Design).
public enum NotificationContent {
    public typealias Text = @Sendable (_ key: String, _ args: [String: String]) -> String

    public static func make(_ e: NotificationEvent, sound: NotificationSound, id: String = UUID().uuidString,
                            text: Text) -> NotificationRequestSpec {
        // Incognito: neither the title nor the body names the chat (it has no title anyway).
        let chatName = e.incognito ? text("title.incognito", [:]) : (e.chatTitle.flatMap { $0.isEmpty ? nil : $0 } ?? text("side.untitled", [:]))
        var title: String
        let body: String
        switch e.kind {
        case .answer:
            title = chatName
            body = e.incognito ? text("notif.answer.incognito", [:]) : text("notif.answer", ["chatTitle": chatName])
        case .image(let failed):
            title = chatName
            body = text(failed ? "notif.image.failed" : "notif.image", [:])
        case .video(let failed):
            title = chatName
            body = text(failed ? "notif.video.failed" : "notif.video", [:])
        case .download(let pack):
            title = "AntiChat"
            body = text("notif.download", ["pack": pack])
        case .update(let version):
            title = "AntiChat"
            body = text("notif.update", ["version": version])
        }
        // Evil chats: the title says so in text (not colour).
        if e.evil, e.chatID != nil { title = "Evil · " + title }
        // Incognito: the chat lives only in its window's in-memory session, so a click just brings AntiChat forward
        // (review fix) and nothing about the chat (id, thread) leaves the app.
        let route = e.incognito ? NotificationRoute(chatID: nil, messageID: nil, category: e.category)
                                : NotificationRoute(chatID: e.chatID, messageID: e.messageID, category: e.category)
        return NotificationRequestSpec(id: id, category: e.category, title: title, body: body, sound: sound.specValue,
                                       threadID: e.incognito ? nil : e.chatID, userInfo: route.userInfo)
    }
}

/// The `UNUserNotificationCenter` calls the service makes (live, or the DEBUG spy).
public protocol UserNotificationClient: Sendable {
    func add(_ request: NotificationRequestSpec) async throws
    func removeAllDelivered()
}

/// Live delivery. `UNUserNotificationCenter.current()` raises in a process without a bundle id: every call no-ops
/// there (the ported headless guard).
public struct LiveUserNotificationClient: UserNotificationClient {
    public init() {}

    static var center: UNUserNotificationCenter? { Bundle.main.bundleIdentifier != nil ? .current() : nil }

    public func add(_ r: NotificationRequestSpec) async throws {
        guard let center = Self.center else { return }
        let content = UNMutableNotificationContent()
        content.title = r.title
        content.body = r.body
        content.categoryIdentifier = r.category.rawValue
        if let thread = r.threadID { content.threadIdentifier = thread }
        content.userInfo = r.userInfo
        switch r.sound {
        case nil: content.sound = nil
        case "default"?: content.sound = .default
        case let name?: content.sound = UNNotificationSound(named: UNNotificationSoundName(name))
        }
        try await center.add(UNNotificationRequest(identifier: r.id, content: content, trigger: nil))
    }

    public func removeAllDelivered() { Self.center?.removeAllDeliveredNotifications() }
}

#if DEBUG || ANTICHAT_PERF_HARNESS
/// DEBUG `-NotificationSpy <file>`: records every request (JSON array, rewritten on each add) instead of delivering.
public final class SpyUserNotificationClient: UserNotificationClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [NotificationRequestSpec] = []
    private var removed = 0
    public let file: URL?

    public init(file: URL? = nil) { self.file = file }

    public var requests: [NotificationRequestSpec] { lock.withLock { recorded } }
    public var removeAllCount: Int { lock.withLock { removed } }

    public func add(_ r: NotificationRequestSpec) async throws {
        let all = lock.withLock { recorded.append(r); return recorded }
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(all).write(to: file, options: .atomic)
    }

    public func removeAllDelivered() { lock.withLock { removed += 1 } }
}
#endif

@MainActor @Observable
public final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationService(client: NotificationService.clientFromLaunchOptions())

    /// What a post did (tests, probe).
    public enum Outcome: String, Sendable, Equatable {
        case delivered
        /// The feature flag is off (rollback).
        case disabled
        /// Policy said no (Never, the group is off, or the user is looking at it).
        case suppressed
        /// macOS notifications are off for AntiChat, or the user answered the explainer with Not now.
        case notAllowed
        case failed
    }

    @ObservationIgnored public let client: any UserNotificationClient
    @ObservationIgnored private let permissions: PermissionCoordinator
    /// The user's Settings (UI supplies them from Defaults).
    @ObservationIgnored public var policy: @MainActor () -> NotificationPolicy = { NotificationPolicy() }
    @ObservationIgnored public var sound: @MainActor () -> NotificationSound = { .systemDefault }
    @ObservationIgnored public var text: NotificationContent.Text = { key, _ in key }
    /// Every post's outcome, newest last (tests, probe).
    public private(set) var outcomes: [(category: NotificationCategory, outcome: Outcome)] = []
    @ObservationIgnored private var configured = false

    public init(client: any UserNotificationClient, permissions: PermissionCoordinator = .shared) {
        self.client = client
        self.permissions = permissions
        super.init()
    }

    /// The app's launch: the delegate and the five categories (each with Open). No authorization request (R-109).
    public func configureOnLaunch() {
        guard !configured else { return }
        configured = true
        guard client is LiveUserNotificationClient, let center = LiveUserNotificationClient.center else { return }
        center.delegate = self
        let open = UNNotificationAction(identifier: NotificationAction.open, title: text("notif.open", [:]), options: [.foreground])
        center.setNotificationCategories(Set(NotificationCategory.allCases.map {
            UNNotificationCategory(identifier: $0.rawValue, actions: [open], intentIdentifiers: [], options: [])
        }))
    }

    /// Posts `event` when the policy allows it; asks for permission just in time (explainer first) on the first
    /// event that would notify.
    @discardableResult
    public func post(_ event: NotificationEvent, focus: NotificationPolicy.Focus) async -> Outcome {
        let outcome = await deliver(event, focus: focus)
        outcomes.append((event.category, outcome))
        if outcomes.count > 64 { outcomes.removeFirst(outcomes.count - 64) }
        return outcome
    }

    private func deliver(_ event: NotificationEvent, focus: NotificationPolicy.Focus) async -> Outcome {
        guard FeatureFlag.notifications.isEnabled() else { return .disabled }
        guard policy().shouldNotify(event.category, focus: focus) else { return .suppressed }
        guard await permissions.ensureNotifications() else { return .notAllowed }
        let spec = NotificationContent.make(event, sound: sound(), text: text)
        do {
            try await client.add(spec)
            return .delivered
        } catch {
            AppLog.log(.ui, .error, "notification \(event.category.rawValue): \(error)")
            return .failed
        }
    }

    /// Remove everything / Uninstall (M8.T10/T11).
    public func removeAllDelivered() { client.removeAllDelivered() }

    // MARK: UNUserNotificationCenterDelegate (ported)

    /// "Always" also shows while AntiChat is in front.
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                                   withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                                   withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard response.actionIdentifier == NotificationAction.open
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let info = response.notification.request.content.userInfo
        var strings: [String: String] = [:]
        for (k, v) in info { if let k = k as? String, let v = v as? String { strings[k] = v } }
        Task { @MainActor in NotificationRouter.shared.open(userInfo: strings) }
    }

    static func clientFromLaunchOptions() -> any UserNotificationClient {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if let path = LaunchOptions.current.notificationSpy { return SpyUserNotificationClient(file: URL(fileURLWithPath: path)) }
        #endif
        return LiveUserNotificationClient()
    }
}
