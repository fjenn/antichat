// Background runs: tests and automation never get in the owner's way (the Mac is in use while they run). One switch,
// decided once per process (`BackgroundRun.wanted`):
//   • `ANTICHAT_BACKGROUND=1` forces it on, `=0` off (XCUITest, which needs a real foreground app, Q-015);
//   • otherwise an automation launch (any in-process probe or debug harness, or a throwaway `-ANTICHAT_DEV_CONTAINER`,
//     which every tools/at, tools/perf and tools/offline launch uses) or an XCTest-hosted app (integration suites);
//   • never for `-VisualQAProbe` (the visual-QA capture must show its windows; it posts no input either way).
// When on (`enable()`): activation policy `.prohibited` (no Dock icon, no app switcher, the app can never become
// active, so it never takes key focus from the owner's apps and the owner's keystrokes never land in a test), and every
// window is concealed (alpha 0, click-through) before it is drawn: explicitly by `present`, and
// for windows AppKit/SwiftUI order in by themselves by a main-run-loop observer that runs before Core Animation commits.
// Synthetic input stays in-process (`NSWindow.sendEvent` / `NSApp.sendEvent` to that window); nothing here or in the
// tests posts global CGEvent/HID events (`make audit` greps for it). The window suites in `make test-unit` turn it on
// through their parent trait (WindowSuites.swift), which also checks this process never becomes the active app.
// A background window is occluded for the window server (it is never frontmost), so AppKit/SwiftUI may draw it less
// often: probe legs that time on-screen appearance (e.g. AT-001 3b-dock, 7 visibleSeconds) read slower than on a
// frontmost window. Run those timing legs with `ANTICHAT_BACKGROUND=0` on a quiet Mac (milestone AT runs).
// Scheduling (AT-NFR-S3): a `.prohibited` app's main thread runs at priority 31 — the kernel keeps it there whatever
// QoS the thread asks for — while every GUI app (`.regular` / `.accessory`, active or not, windows visible, off-screen,
// minimised or alpha 0) gets 46/47 (measured on macOS 26.6: tools/perf/soak.sh, docs/prd/AT-NFR-S3-method.md). On a
// busy Mac a 31 main thread loses to other apps' UI threads and stalls for seconds where a user's app would not.
// `ANTICHAT_BACKGROUND_POLICY=accessory` keeps everything above (concealed windows, no activation, no Dock icon, input
// in-process only) but uses `.accessory`, so the main thread is scheduled like a user's app; the soak sets it and
// launches through LaunchServices in the background (`open -g`), which never activates the app. If the app becomes
// active anyway it deactivates at once and logs it.
// Unshown windows (RC e8fe19986): under `.prohibited` SwiftUI may create a scene's window and never order it in (Apple:
// a prohibited app "may not create windows"; seen on macOS 26.6.2 as `main-AppWindow-1` alpha 1, not on screen, for
// every probe launch whether or not state restoration had a window to restore, while `.accessory` and `.regular`
// launches showed it). The app registers which windows it expects on screen (`presentsUnshownWindow`: the main
// scene's windows outside onboarding); the observer orders each such window in, concealed, the first time it sees it
// unshown. Once per window: a window the app or a test later closes or hides stays so. Normal launches never get here.
import AntiChatFoundation
import AppKit

@MainActor
public enum BackgroundRun {
    public nonisolated static let environmentKey = "ANTICHAT_BACKGROUND"
    /// `accessory`: the background run uses `.accessory` instead of `.prohibited` (see the file header).
    public nonisolated static let policyKey = "ANTICHAT_BACKGROUND_POLICY"

    /// The background run's activation policy: `.prohibited` unless `ANTICHAT_BACKGROUND_POLICY=accessory`.
    public nonisolated static func policy(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> NSApplication.ActivationPolicy {
        environment[policyKey]?.lowercased() == "accessory" ? .accessory : .prohibited
    }

    /// Whether this process should run in the background (see the file header for the rule).
    public nonisolated static func wanted(environment: [String: String] = ProcessInfo.processInfo.environment,
                                          options: LaunchOptions = .current) -> Bool {
        switch environment[environmentKey] {
        case "1", "YES", "true": return true
        case "0", "NO", "false": return false
        default: break
        }
        if options.visualQAProbe != nil { return false }
        if options.isAutomationRun { return true }
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }

    public private(set) static var isOn = false

    /// Which windows the app expects on screen (see the file header); nil: none are ordered in by the observer.
    public static var presentsUnshownWindow: ((NSWindow) -> Bool)?
    private static var checkedWindows = Set<ObjectIdentifier>()

    /// Turns background mode on for the rest of the process (idempotent).
    public static func enable() {
        guard !isOn else { return }
        isOn = true
        let app = NSApplication.shared
        let policy = policy()
        app.setActivationPolicy(policy)
        if policy == .accessory {
            // An accessory app can be activated; a background run never stays active (the owner's focus is never taken).
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                   queue: .main) { _ in
                MainActor.assumeIsolated {
                    AppLog.log(.ui, .error, "background run became active: deactivating")
                    NSApp.deactivate()
                }
            }
        }
        for w in app.windows where w.isVisible { conceal(w) }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated {
                if let wants = presentsUnshownWindow { presentUnshown((NSApp as NSApplication?)?.windows ?? [], wants: wants) }
                concealVisibleWindows()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// `enable()` when `wanted()`; the app calls this before it finishes launching.
    public static func enableIfWanted() {
        if wanted() { enable() }
    }

    /// Shows `window` the way the app/probe would (`makeKeyAndOrderFront`), or, in background mode, orders it in
    /// concealed without activating anything. The window becomes key only if the app is already active, which a
    /// background run never is: tests and probes deliver input to the window itself (`sendEvent`).
    public static func makeKeyAndOrderFront(_ window: NSWindow) {
        guard isOn else { window.makeKeyAndOrderFront(nil); return }
        present(window)
    }

    /// Orders `window` in (concealed in background mode) without making it key or activating the app.
    public static func orderFront(_ window: NSWindow) {
        guard isOn else { window.orderFront(nil); return }
        present(window)
    }

    /// `NSApp.activate()` outside background mode; a no-op inside it.
    public static func activate() {
        guard !isOn else { return }
        (NSApp as NSApplication?)?.activate()  // nil: a headless process (no application object)
    }

    /// Orders `window` in concealed (enables background mode first). Window host tests use this instead of
    /// `orderFront` / `makeKeyAndOrderFront`.
    public static func present(_ window: NSWindow) {
        enable()
        conceal(window)
        window.orderFrontRegardless()
        window.makeKey()  // in-process bookkeeping only: an app that is not active gets no key window
    }

    /// Alpha 0 and click-through (a `.prohibited` app's windows are already out of ⌘` and the app switcher). Layout, rendering into the window's layers,
    /// `cacheDisplay` snapshots and `sendEvent` delivery are unaffected.
    public static func conceal(_ window: NSWindow) {
        if window.alphaValue != 0 { window.alphaValue = 0 }
        if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
        // `.accessory`: also out of window cycling and Mission Control (a `.prohibited` app's windows already are).
        if (NSApp as NSApplication?)?.activationPolicy() == .accessory, !window.collectionBehavior.contains(.ignoresCycle) {
            window.collectionBehavior.insert([.ignoresCycle, .transient])
        }
    }

    /// Orders in (concealed) each window `wants` matches that is neither visible nor minimised, the first time it
    /// matches; later checks of that window do nothing (it may have been closed or hidden on purpose since).
    static func presentUnshown(_ windows: [NSWindow], wants: (NSWindow) -> Bool) {
        for w in windows where !checkedWindows.contains(ObjectIdentifier(w)) && wants(w) {
            checkedWindows.insert(ObjectIdentifier(w))
            guard !w.isVisible, !w.isMiniaturized else { continue }
            AppLog.log(.ui, .info, "background run: ordering in unshown window \(w.identifier?.rawValue ?? "?")")
            present(w)
        }
    }

    private static func concealVisibleWindows() {
        for w in (NSApp as NSApplication?)?.windows ?? [] where w.isVisible && (w.alphaValue != 0 || !w.ignoresMouseEvents) { conceal(w) }
    }
}
