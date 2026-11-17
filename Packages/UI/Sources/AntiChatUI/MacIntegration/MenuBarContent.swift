// M8.T13 step 1 (R-105 AC1; components.md MenuBarExtra, S-23): the menu bar item — on by default (Settings ›
// General › Menu bar item), a template icon with an activity dot while a download or a picture/video job runs.
// Its menu, in order: New Chat (⌘N), Quick Panel (shows its shortcut), Start Voice (disabled with the reason when the
// Voice pack is missing), ─, one progress row per active download / job ("Photo 42%", "Video · 1:20 left"; a click
// opens the job's chat or Settings › Capabilities), ─, Open AntiChat, Quit AntiChat (⌘Q, through the quit guards).
// During a voice conversation the item also carries the call rows (Show chat, End) and the waveform icon — it
// replaces M3.T11's CallIndicatorExtra, which shows only while this item is off.
//
// AppKit `NSStatusItem` + `NSMenu` (A-M8-T13a: instead of SwiftUI's MenuBarExtra + MenuBarExtraAccess): the menu
// is rebuilt from `MenuBarModel.items` every time it opens, its order and titles are testable without the menu
// bar, and toggling the setting inserts / removes the item at once.
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import AppKit
import Defaults
import KeyboardShortcuts
import Observation

/// One menu row as data (MenuBarModelTests).
public struct MenuBarItem: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case newChat, quickPanel, startVoice, openApp, quit, showCall, endCall
        case openChat(String)
        case openCapabilities
        case none
    }

    public var id: String
    public var title: String
    public var action: Action
    public var enabled = true
    /// Shown as the item's tooltip / second line when disabled.
    public var reason: String?
    public var keyEquivalent = ""
    public var modifiers: NSEvent.ModifierFlags = []
    public var isSeparator = false

    public static func separator(_ id: String) -> MenuBarItem {
        MenuBarItem(id: id, title: "", action: .none, isSeparator: true)
    }

    public static func == (a: MenuBarItem, b: MenuBarItem) -> Bool {
        a.id == b.id && a.title == b.title && a.action == b.action && a.enabled == b.enabled && a.reason == b.reason
            && a.keyEquivalent == b.keyEquivalent && a.modifiers == b.modifiers && a.isSeparator == b.isSeparator
    }
}

public enum MenuBarModel {
    /// A running job the menu shows.
    public struct Job: Equatable, Sendable {
        public var id: String
        public var kind: MediaJobKind
        public var chatID: String
        public var progress: Double
        public var etaSeconds: Double?

        public init(id: String, kind: MediaJobKind, chatID: String, progress: Double, etaSeconds: Double?) {
            self.id = id
            self.kind = kind
            self.chatID = chatID
            self.progress = progress
            self.etaSeconds = etaSeconds
        }
    }

    /// The menu rows for this state, in order.
    public static func items(downloads: [PackProgress], jobs: [Job], voiceReady: Bool, quickPanelShortcut: String?,
                             callActive: Bool, text: (String, [String: String]) -> String = { k, a in CopyKey(k).string(a) }) -> [MenuBarItem] {
        var rows: [MenuBarItem] = []
        if callActive {
            rows.append(MenuBarItem(id: "call.show", title: text("voice.showChat", [:]), action: .showCall))
            rows.append(MenuBarItem(id: "call.end", title: text("voice.end", [:]), action: .endCall))
            rows.append(.separator("sep.call"))
        }
        rows.append(MenuBarItem(id: "newChat", title: text("mb.newChat", [:]), action: .newChat, keyEquivalent: "n",
                                modifiers: .command))
        var qp = MenuBarItem(id: "quickPanel", title: text("mb.quickPanel", [:]), action: .quickPanel)
        if let s = quickPanelShortcut { qp.reason = s }
        rows.append(qp)
        rows.append(MenuBarItem(id: "voice", title: text("mb.voice", [:]), action: .startVoice, enabled: voiceReady,
                                reason: voiceReady ? nil : text("add.disabled.pack", ["pack": text("onb.pack.voice.name", [:])])))
        let active = downloads.filter { $0.state == .downloading || $0.state == .verifying || $0.state == .paused }
        if !active.isEmpty || !jobs.isEmpty {
            rows.append(.separator("sep.progress"))
            for p in active {
                let pack = text(StatusPill.packNameKey(p.pack), [:])
                let title = p.state == .paused ? text("pill.paused", ["pack": pack])
                    : text("pill.download", ["pack": pack, "percent": "\(p.percent)"])
                rows.append(MenuBarItem(id: "download.\(p.pack)", title: title, action: .openCapabilities))
            }
            for j in jobs {
                let pct = "\(min(99, Int((j.progress * 100).rounded(.down))))"
                let title: String
                if j.kind == .video {
                    title = j.etaSeconds.map { text("mb.job.videoEta", ["time": clock($0)]) } ?? text("mb.job.video", ["percent": pct])
                } else {
                    title = text("mb.job.image", ["percent": pct])
                }
                rows.append(MenuBarItem(id: "job.\(j.id)", title: title, action: .openChat(j.chatID)))
            }
        }
        rows.append(.separator("sep.app"))
        rows.append(MenuBarItem(id: "open", title: text("mb.open", [:]), action: .openApp))
        rows.append(MenuBarItem(id: "quit", title: text("mb.quit", [:]), action: .quit, keyEquivalent: "q", modifiers: .command))
        return rows
    }

    /// "1:20" (m:ss), "1:02:03" past an hour.
    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The activity dot shows while something downloads or a job runs.
    public static func isBusy(downloads: [PackProgress], jobs: [Job]) -> Bool {
        !jobs.isEmpty || downloads.contains { $0.state == .downloading || $0.state == .verifying }
    }
}

/// The running jobs the menu bar shows (fed by AppNotifications' watch of the generic job queue).
@MainActor @Observable
public final class JobActivity {
    public static let shared = JobActivity()
    public private(set) var jobs: [MenuBarModel.Job] = []

    func update(_ u: MediaJobQueue.Update, kind: MediaJobKind, chatID: String, etaSeconds: Double?) {
        if u.state == .queued || u.state == .running {
            let j = MenuBarModel.Job(id: u.job, kind: kind, chatID: chatID, progress: u.progress, etaSeconds: etaSeconds)
            if let i = jobs.firstIndex(where: { $0.id == u.job }) { jobs[i] = j } else { jobs.append(j) }
        } else {
            jobs.removeAll { $0.id == u.job }
        }
    }
}

@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    public static let shared = MenuBarController()

    private(set) var statusItem: NSStatusItem?
    private var lastBusy: Bool?
    private var lastCall: Bool?
    /// Every action the menu performed (probe).
    public private(set) var performed: [MenuBarItem.Action] = []

    public var isInserted: Bool { statusItem != nil }
    public var button: NSStatusBarButton? { statusItem?.button }

    /// The menu as AppKit builds it when it opens: titles (separators as "—"), enabled flags, second lines and the
    /// right-aligned shortcut (the row model's text for it; probe).
    public func renderedMenu() -> [(title: String, enabled: Bool, subtitle: String?, shortcut: String?)] {
        guard let menu = statusItem?.menu else { return [] }
        menuNeedsUpdate(menu)
        let rows = currentItems()
        return menu.items.map { item in
            let row = rows.first { $0.id == item.representedObject as? String }
            let shortcut = item.keyEquivalent.isEmpty ? nil : row?.action == .quickPanel ? row?.reason : item.keyEquivalent
            return (item.isSeparatorItem ? "—" : item.title, item.isEnabled, item.subtitle, shortcut)
        }
    }

    /// Starts following the setting (once, at launch).
    public func start() {
        sync()
        observe()
    }

    /// Inserts or removes the item to match Settings › General › Menu bar item (and `ff.menuBar`).
    public func sync() {
        let want = Defaults[.menuBarItem] && FeatureFlag.menuBar.isEnabled()
        if want, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.setAccessibilityIdentifier("menuBarItem")
            item.button?.setAccessibilityLabel("AntiChat")
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            item.menu = menu
            // Background runs (tests, probes) keep the item out of the owner's menu bar; its menu still builds. AppKit
            // saves `isVisible` under the autosave name, so test runs use their own name and every run sets it
            // (review fix: a test run must not leave the owner's item hidden).
            let background = BackgroundRun.wanted()
            item.autosaveName = background ? "AntiChatMenuBarItem.background" : "AntiChatMenuBarItem"
            item.isVisible = !background
            statusItem = item
            lastBusy = nil
            updateIcon()
        } else if !want, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        VoiceCallIndicator.shared.menuBarShowsCall = statusItem != nil
    }

    /// Re-renders the icon and the menu whenever the setting, downloads, jobs or a call change.
    private func observe() {
        withObservationTracking {
            _ = DownloadsLaunch.menuBar.packs
            _ = JobActivity.shared.jobs
            _ = VoiceCalls.shared.isActive
            _ = menuBarSetting.value
        } onChange: {
            Task { @MainActor in
                MenuBarController.shared.sync()
                MenuBarController.shared.updateIcon()
                MenuBarController.shared.observe()
            }
        }
    }

    private let menuBarSetting = DefaultsMirror()

    /// Template icon; the dotted variant while busy; the waveform during a call.
    func updateIcon() {
        guard let button = statusItem?.button else { return }
        let busy = MenuBarModel.isBusy(downloads: DownloadsLaunch.menuBar.packs, jobs: JobActivity.shared.jobs)
        let call = VoiceCalls.shared.isActive
        guard busy != lastBusy || call != lastCall else { return }
        lastBusy = busy
        lastCall = call
        button.image = Self.icon(busy: busy, call: call)
        // Q-015 r4: while this item carries the call (CallIndicatorExtra stays hidden), it says so, as the indicator's
        // label does (`voice.callActive`); before, VoiceOver heard "AntiChat, idle" during a call.
        button.setAccessibilityValue(call ? CopyKey("voice.callActive").string([:]) : busy ? "busy" : "idle")
    }

    static func icon(busy: Bool, call: Bool) -> NSImage? {
        let name = call ? "waveform" : "bubble.left.and.text.bubble.right"
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "AntiChat") else { return nil }
        guard busy else {
            base.isTemplate = true
            return base
        }
        let size = NSSize(width: 20, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            base.draw(in: NSRect(x: 0, y: 1, width: 17, height: 16))
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)).fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "AntiChat"
        return img
    }

    /// The rows for now.
    public func currentItems() -> [MenuBarItem] {
        let shortcut = ShortcutStore.get(.quickPanel)?.description
        return MenuBarModel.items(downloads: DownloadsLaunch.menuBar.packs, jobs: JobActivity.shared.jobs,
                                  voiceReady: VoiceAvailability.shared.packReady, quickPanelShortcut: shortcut,
                                  callActive: VoiceCalls.shared.isActive)
    }

    // MARK: NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for row in currentItems() {
            if row.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: row.title, action: #selector(clicked(_:)), keyEquivalent: row.keyEquivalent)
            item.keyEquivalentModifierMask = row.modifiers
            item.target = self
            item.isEnabled = row.enabled
            item.representedObject = row.id
            item.setAccessibilityIdentifier("menuBar.\(row.id)")
            if row.action == .quickPanel {
                // vq/voice-mac-capture (S-23): the panel's global shortcut, right-aligned like ⌘N and ⌘Q. As a subtitle
                // it wrapped under "Quick Panel". The key equivalent only shows it: the global hotkey opens the panel
                // (pressing it with this menu open runs the same action).
                if let s = ShortcutStore.get(.quickPanel), let key = s.nsMenuItemKeyEquivalent {
                    item.keyEquivalent = key
                    item.keyEquivalentModifierMask = s.modifiers
                }
                item.toolTip = row.reason
            } else if let reason = row.reason {
                item.toolTip = reason
                // The reason a row is disabled as its second line (macOS 14+ subtitle).
                if !row.enabled { item.subtitle = reason }
            }
            menu.addItem(item)
        }
    }

    @objc private func clicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let row = currentItems().first(where: { $0.id == id }) else { return }
        run(row.action)
    }

    /// Performs `action` (the menu, the probe and the UI tests' path).
    public func run(_ action: MenuBarItem.Action) {
        performed.append(action)
        switch action {
        case .quickPanel: QuickPanelController.shared.show(.menu)
        case .showCall:
            BackgroundRun.activate()
            VoiceCalls.shared.showChat?()
        case .endCall: VoiceCalls.shared.current?.end()
        case .quit: NSApp.terminate(nil)
        case .none: break
        case .openCapabilities:
            SettingsNavigator.shared.request(.capabilities)
            BackgroundRun.activate()
            SettingsPresenter.shared.show()
        case .newChat:
            BackgroundRun.activate()
            AppNotifications.withWindow { s in
                if let w = s.window { BackgroundRun.makeKeyAndOrderFront(w) }
                s.newChat()
            }
        case .startVoice:
            BackgroundRun.activate()
            AppNotifications.withWindow { s in
                if let w = s.window { BackgroundRun.makeKeyAndOrderFront(w) }
                s.startVoice?()
            }
        case .openApp:
            BackgroundRun.activate()
            // R-042 AC3 (Q-015 r5): with every window closed, the new one comes back on the chat that was shown (a job
            // keeps running after the close); a window that is still open is only brought forward.
            let reopen = AppNotifications.targetWindow().map { $0.window?.isVisible != true } ?? true
            let restore = reopen ? WindowState.lastChatRoute : nil
            AppNotifications.withWindow { s in
                if let restore, s.route == .newChat, !s.isDocked { s.open(restore) }
                if let w = s.window { BackgroundRun.makeKeyAndOrderFront(w) }
            }
        case .openChat(let id):
            NotificationRouter.shared.route(.chat(id: id, messageID: nil))
        }
    }
}

/// Mirrors the Defaults key into Observation (the menu bar item follows the toggle at once).
@MainActor @Observable
final class DefaultsMirror {
    var value = Defaults[.menuBarItem]
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        task = Task { @MainActor [weak self] in
            for await v in Defaults.updates(.menuBarItem, initial: false) { self?.value = v }
        }
    }
}

/// M3.T11's call indicator shows only while the menu bar item is off (the item carries the call otherwise).
@MainActor @Observable
public final class VoiceCallIndicator {
    public static let shared = VoiceCallIndicator()
    public var menuBarShowsCall = false
}
