// M8.T12 (R-108, R-042 AC2; G-063): the app side of notifications. Feeds `NotificationService` (AntiChatPlatform)
// with the user's Settings, the copy deck, what is on screen (`focus(chatID:)`) and the app's events:
//   answers   a turn that ended `done` (ChatSessions' completion pass, every window);
//   pictures  the media job queue's terminal updates (`MediaJobQueue.subscribe`, the generic job-event API: image
//   videos    and video jobs alike, so M5's video jobs notify without any video-specific code here);
//   downloads a pack's download finishing (`MenuBarProgressModel.onPackFinished`);
//   updates   `updateReady(version:)`, called by M10.T03 (Sparkle) — the category is wired now.
// A click (`NotificationRouter`) brings AntiChat forward, opens the chat and scrolls to the result, flashing it.
// While a picture or video is being made the Dock shows a badge (closing the last window never stops the job).
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import AntiChatStorage
import AppKit
import Defaults
import Observation

@MainActor
public enum AppNotifications {
    private static var started = false
    private static var database: AppDatabase?
    private static var jobWatch: Task<Void, Never>?
    /// Jobs already notified (a terminal update can arrive twice: the queue's broadcast and a reconcile).
    private static var notifiedJobs: Set<String> = []
    /// Picture / video jobs queued or running, by kind (the quit guard asks "a video is still being made").
    public private(set) static var activeJobs: [String: MediaJobKind] = [:]
    public static var hasActiveVideo: Bool { activeJobs.values.contains(.video) }
    private static var jobChats: [String: String] = [:]
    private static var jobETA: [String: Double?] = [:]
    /// Called after every job update (the quit guard's Wait).
    static var jobsChanged: [UUID: @MainActor () -> Void] = [:]
    /// Opens a main window when none is on screen (set by the app: File › New Window).
    public static var openWindow: (@MainActor () -> Void)?
    /// Every event handed to the service with its outcome (probe).
    public private(set) static var posted: [(event: NotificationEvent, outcome: NotificationService.Outcome)] = []

    /// The Settings › General values as a policy.
    public static var policy: NotificationPolicy {
        var groups = Set<NotificationGroup>()
        if Defaults[.notifyResponses] { groups.insert(.responses) }
        if Defaults[.notifyMedia] { groups.insert(.media) }
        if Defaults[.notifyDownloads] { groups.insert(.downloads) }
        if Defaults[.notifyUpdates] { groups.insert(.updates) }
        return NotificationPolicy(when: NotifyWhen(rawValue: Defaults[.notifyWhen]) ?? .unfocused, groups: groups)
    }

    /// Once, at launch (after the database opened).
    public static func start(database: AppDatabase, queue: MediaJobQueue? = MediaJobQueue.shared) {
        guard !started else { return }
        started = true
        self.database = database
        let service = NotificationService.shared
        service.policy = { AppNotifications.policy }
        service.sound = { NotificationSound(rawValue: Defaults[.notificationSound]) }
        service.text = { key, args in CopyKey(key).string(args) }
        service.configureOnLaunch()
        PermissionExplainers.install()
        NotificationRouter.shared.handler = { perform($0) }
        DownloadsLaunch.menuBar.onPackFinished = { pack in
            let name = StatusPill.packName(pack)
            post(NotificationEvent(kind: .download(pack: name)), chatID: nil)
        }
        if let queue { watch(queue) }
        Task { _ = await PermissionCoordinator.shared.status(.notifications) }  // Settings banner; never a request
    }

    /// M10.T03 (Sparkle "update ready") posts through here.
    public static func updateReady(version: String) {
        post(NotificationEvent(kind: .update(version: version)), chatID: nil)
    }

    // MARK: Events

    /// ChatSessions' completion pass: a reply that ended `done`.
    static func turnCompleted(chatID: String, assistantID: String, status: MessageStatus, incognito: Bool, database: AppDatabase) {
        guard status == .done else { return }
        let chat = incognito ? nil : (try? ChatRepository(database).chat(chatID)) ?? nil
        let e = NotificationEvent(kind: .answer, chatID: chatID, messageID: assistantID,
                                  chatTitle: chat?.title, incognito: incognito,
                                  evil: chat?.mode == .evil)
        post(e, chatID: chatID)
    }

    /// The generic job-event stream: every picture/video job's terminal state notifies once.
    static func watch(_ queue: MediaJobQueue) {
        jobWatch?.cancel()
        jobWatch = Task { @MainActor in
            let updates = await queue.subscribe()
            for await u in updates {
                var ended: MediaJobRecord?
                if [.done, .failed, .blocked, .lost].contains(u.state), !notifiedJobs.contains(u.job) {
                    notifiedJobs.insert(u.job)
                    ended = (try? await queue.row(u.job)) ?? nil
                }
                if u.state == .queued || u.state == .running {
                    if activeJobs[u.job] == nil || jobChats[u.job] == nil, let row = (try? await queue.row(u.job)) ?? nil {
                        activeJobs[u.job] = MediaJobKind(rawValue: row.kind) ?? .image
                        jobChats[u.job] = row.chatID
                        jobETA[u.job] = row.etaS
                    }
                } else {
                    activeJobs[u.job] = nil
                    jobChats[u.job] = nil
                    jobETA[u.job] = nil
                }
                // M8.T13: the menu bar's progress rows.
                JobActivity.shared.update(u, kind: activeJobs[u.job] ?? .image, chatID: jobChats[u.job] ?? "", etaSeconds: jobETA[u.job] ?? nil)
                updateDockBadge(queue)
                if let ended {
                    let posting = jobEnded(ended, state: u.state)
                    // A quit held by "Wait" lets the end notification go out first, but never waits more than 5 s
                    // for it (review fix: an explainer nobody can see must not hold the quit).
                    if MediaJobQuitGuard.waiting {
                        await withTaskGroup(of: Void.self) { g in
                            g.addTask { await posting.value }
                            g.addTask { try? await Task.sleep(for: .seconds(5)) }
                            await g.next()
                            g.cancelAll()
                        }
                    }
                }
                jobsChanged.values.forEach { $0() }
            }
        }
    }

    @discardableResult
    static func jobEnded(_ row: MediaJobRecord, state: MediaJobState) -> Task<Void, Never> {
        let failed = state != .done
        let kind: NotificationEvent.Kind = MediaJobKind(rawValue: row.kind) == .video ? .video(failed: failed) : .image(failed: failed)
        let chat = database.flatMap { (try? ChatRepository($0).chat(row.chatID)) ?? nil }
        // A job whose chat is not in the app database belongs to an incognito chat: no title anywhere.
        let e = NotificationEvent(kind: kind, chatID: row.chatID, messageID: row.messageID,
                                  chatTitle: chat?.title, incognito: chat == nil,
                                  evil: chat?.mode == .evil)
        return post(e, chatID: row.chatID)
    }

    @discardableResult
    static func post(_ e: NotificationEvent, chatID: String?) -> Task<Void, Never> {
        let focus = focus(chatID: chatID)
        return Task { @MainActor in
            let outcome = await NotificationService.shared.post(e, focus: focus)
            posted.append((e, outcome))
            if posted.count > 64 { posted.removeFirst(posted.count - 64) }
        }
    }

    // MARK: Focus

    /// What the user is looking at right now (NotificationPolicy step 3).
    /// No application object (a process that never made one, e.g. a unit-test run in which no suite touched
    /// `NSApplication.shared` before a turn finished): nothing is on screen. `NSApp` is implicitly unwrapped, and
    /// reading `.keyWindow` through nil trapped the whole test process (FilesIntakeHostTests run alone, or first).
    public static func focus(chatID: String?) -> NotificationPolicy.Focus {
        // The quick panel showing that very chat counts as looking at it (M8.T13).
        if let chatID, QuickPanelController.shared.isVisible, QuickPanelController.shared.model.chatID == chatID {
            return NotificationPolicy.Focus(appActive: true, mainWindowKey: true, chatVisible: true)
        }
        guard let app = NSApp as NSApplication? else {
            return NotificationPolicy.Focus(appActive: false, mainWindowKey: false, chatVisible: false)
        }
        let key = app.keyWindow
        let keyState = IncognitoQuitGuard.states.first { $0.window != nil && $0.window === key }
        let visible = chatID != nil && keyState?.currentChatID == chatID
        return NotificationPolicy.Focus(appActive: app.isActive, mainWindowKey: keyState != nil, chatVisible: visible)
    }

    // MARK: Click

    /// A clicked notification: AntiChat forward, the chat open at the result.
    static func perform(_ d: NotificationDestination) {
        BackgroundRun.activate()
        switch d {
        case .chat(let id, let messageID):
            withWindow { state in
            if let w = state.window { BackgroundRun.makeKeyAndOrderFront(w) }
            state.open(.chat(id))
            // The conversation exists once the route applied (same run loop pass or the next).
            Task { @MainActor in
                for _ in 0..<20 {
                    if state.currentChatID == id, let c = state.conversation?(), !c.messages.isEmpty || messageID == nil {
                        c.reveal(messageID)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            }
        case .capabilities:
            SettingsNavigator.shared.request(.capabilities)
            SettingsPresenter.shared.show()
        case .updates:
            SettingsNavigator.shared.request(.general, row: "updates.check")
            SettingsPresenter.shared.show()
        case .app:
            withWindow { s in if let w = s.window { BackgroundRun.makeKeyAndOrderFront(w) } }
        }
    }

    /// The key main window's state, else any visible main window's, else any (nil when no window exists).
    public static func targetWindow() -> WindowState? {
        let states = IncognitoQuitGuard.states
        if let s = states.first(where: { $0.window != nil && $0.window === (NSApp as NSApplication?)?.keyWindow }) { return s }
        if let s = states.first(where: { $0.window?.isVisible == true && !$0.isIncognito }) { return s }
        return states.first(where: { !$0.isIncognito }) ?? states.first
    }

    /// Runs `body` with a main window: the target window now, or a new one once it exists (File › New Window).
    public static func withWindow(_ body: @escaping @MainActor (WindowState) -> Void) {
        if let s = targetWindow(), s.window?.isVisible ?? true {
            body(s)
            return
        }
        openWindow?()
        Task { @MainActor in
            for _ in 0..<60 {
                if let s = targetWindow(), s.window != nil {
                    body(s)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    // MARK: Dock badge (R-042 AC3)

    /// The number of pictures / videos queued or being made (the job keeps running with every window closed).
    static func updateDockBadge(_ queue: MediaJobQueue) {
        let label: String? = queue.hasRunning || !activeJobs.isEmpty ? "\(max(1, activeJobs.count))" : nil
        guard let app = NSApp as NSApplication? else { return }  // no application object (headless test process)
        if app.dockTile.badgeLabel != label { app.dockTile.badgeLabel = label }
    }
}

/// The in-app explainers `PermissionCoordinator` shows before a system request (R-109 AC2). Notifications: a banner
/// over the conversation (`perm.notifications.why`, [Allow notifications] [Not now]); the event that triggered it
/// waits for the answer.
@MainActor @Observable
public final class PermissionExplainers {
    public static let shared = PermissionExplainers()

    /// The kind whose explainer is on screen (nil = none).
    public internal(set) var pending: PermissionRequestKind?
    @ObservationIgnored private var answer: CheckedContinuation<Bool, Never>?
    /// DEBUG / probe: answers instead of waiting for a click (nil = wait).
    @ObservationIgnored public var scriptedAnswer: Bool?

    static func install() {
        PermissionCoordinator.shared.explainer = { kind in await PermissionExplainers.shared.ask(kind) }
    }

    public func ask(_ kind: PermissionRequestKind) async -> Bool {
        // The banner lives in a conversation: with no main window on screen nobody could answer (review fix) —
        // treated as Not now for this launch, never a system dialog without its explainer.
        // Q-015 r6: a window of a hidden app (⌘H) or a minimized one is not on screen yet can be answered when the
        // user comes back — the common case for the first notifying event (a reply that ends while the user is
        // away). Treating it as Not now meant no explainer and no notification for the whole launch.
        if scriptedAnswer == nil, !IncognitoQuitGuard.states.contains(where: { Self.canAnswer(in: $0.window) }) { return false }
        if let scriptedAnswer {
            pending = kind
            defer { pending = nil }
            return scriptedAnswer
        }
        answer?.resume(returning: false)
        pending = kind
        return await withCheckedContinuation { answer = $0 }
    }

    /// A main window the explainer can show in: on screen, or hidden with the app (⌘H) or minimized (it shows on the
    /// user's return). A closed window (none) cannot.
    static func canAnswer(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.isVisible || window.isMiniaturized || NSApp?.isHidden == true
    }

    /// [Allow notifications] (true) or [Not now] (false).
    public func respond(_ allow: Bool) {
        pending = nil
        answer?.resume(returning: allow)
        answer = nil
    }
}

/// App-wide toasts every main window shows (bottom centre; M8.T12 `quit.waiting`).
@MainActor @Observable
public final class AppToasts {
    public static let shared = AppToasts()
    public var current: Toast?

    public func show(_ toast: Toast) { current = toast }
}
