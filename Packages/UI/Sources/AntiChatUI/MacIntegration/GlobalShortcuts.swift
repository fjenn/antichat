// M8.T13 step 3 (R-106 AC1; P-media-06 KeyboardShortcuts 3.1.0): the global quick-panel hotkey — default ⌥Space,
// changeable or Off in Settings › General (KeyboardShortcuts.Recorder; Off = no shortcut). The handler runs on key
// down (the panel is up before the key is released; NFR-U9). When the combination is taken — by a macOS shortcut,
// or registered by another app (Carbon `RegisterEventHotKey` refuses it) — the row says `qp.conflict`.
// `-QuickPanelHotkeyHook YES` (DEBUG): the distributed notification `app.antichat.test.quickPanelHotkey` calls the
// same handler (UI tests, `make perf METRIC=U9`); its `uptime` is the poster's clock just before posting.
import AntiChatFoundation
import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import Observation

public extension KeyboardShortcuts.Name {
    /// R-106: the quick panel (default ⌥Space). The name is the one Uninstall resets (InstallTestHooks).
    static let quickPanel = Self("quickPanel", initial: .init(.space, modifiers: .option))
}

@MainActor @Observable
public final class GlobalShortcuts {
    public static let shared = GlobalShortcuts()

    /// The quick-panel combination is taken elsewhere (the Settings row shows `qp.conflict`).
    public private(set) var conflict = false
    /// The handler ran (probe / tests).
    public private(set) var fired = 0
    @ObservationIgnored private var handler: (@MainActor (QuickPanelController.Trigger) -> Void)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    public static let hookName = Notification.Name("app.antichat.test.quickPanelHotkey")

    /// Registers the hotkey (and, DEBUG, the hook). Once.
    func install(_ handler: @escaping @MainActor (QuickPanelController.Trigger) -> Void) {
        guard self.handler == nil else { return }
        self.handler = handler
        // Tests, probes and perf runs (background runs) never register the system-wide hotkey: it would take the
        // owner's ⌥Space while they run. They open the panel through the DEBUG hook below.
        if !BackgroundRun.wanted() {
            recheck()
            KeyboardShortcuts.onKeyDown(for: .quickPanel) {
                let at = ProcessInfo.processInfo.systemUptime
                MainActor.assumeIsolated { GlobalShortcuts.shared.fire(.hotkey(at: at)) }
            }
            observers.append(NotificationCenter.default.addObserver(
                forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"), object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { GlobalShortcuts.shared.recheck() } })
        }
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if LaunchOptions.current.quickPanelHotkeyHook {
            observers.append(DistributedNotificationCenter.default().addObserver(
                forName: Self.hookName, object: nil, queue: .main
            ) { n in
                let at = (n.userInfo?["uptime"] as? String).flatMap(TimeInterval.init) ?? ProcessInfo.processInfo.systemUptime
                let action = n.userInfo?["action"] as? String ?? "toggle"
                MainActor.assumeIsolated {
                    switch action {
                    case "hide": QuickPanelController.shared.hide()
                    case "show": QuickPanelController.shared.show(.posted(at: at))
                    default: GlobalShortcuts.shared.fire(.posted(at: at))
                    }
                }
            })
        }
        #endif
    }

    func fire(_ trigger: QuickPanelController.Trigger) {
        fired += 1
        handler?(trigger)
    }

    /// Re-checks the current combination (at install and after every change in the recorder).
    public func recheck() {
        guard let s = ShortcutStore.get(.quickPanel) else {
            conflict = false
            return
        }
        // Our own registration would make the Carbon test fail: test with it paused.
        let enabled = KeyboardShortcuts.isEnabled(for: .quickPanel)
        if enabled { KeyboardShortcuts.disable(.quickPanel) }
        conflict = Self.isTaken(s)
        if enabled { KeyboardShortcuts.enable(.quickPanel) }
    }

    /// Taken by a macOS shortcut, or registered by another app.
    public static func isTaken(_ s: KeyboardShortcuts.Shortcut) -> Bool {
        if s.isTakenBySystem { return true }
        guard let code = s.key?.rawValue else { return false }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4143_5150), id: 1)  // 'ACQP'
        let status = RegisterEventHotKey(UInt32(code), carbonModifiers(s.modifiers), id, GetEventDispatcherTarget(), 0, &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status != noErr
    }

    static func carbonModifiers(_ m: NSEvent.ModifierFlags) -> UInt32 {
        var c = 0
        if m.contains(.command) { c |= cmdKey }
        if m.contains(.option) { c |= optionKey }
        if m.contains(.control) { c |= controlKey }
        if m.contains(.shift) { c |= shiftKey }
        return UInt32(c)
    }
}
