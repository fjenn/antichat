// App delegate (M1.T24 step 7; R-104 AC3): the last window closing keeps the app running while Settings → General →
// Menu bar item is On (default; the item itself arrives in M8) and terminates it when Off. Windows are kept across
// quit (`NSQuitAlwaysKeepsWindows`) so state restoration reopens them (AT-104 (2)). Absorbs M1.T20's
// IncognitoAppDelegate: quitting with an incognito chat that has messages asks first (`IncognitoQuitGuard`).
// M4.T04: quitting while a media job runs asks first (`MediaJobQuitGuard`, before the incognito guard); M8.T12: a
// running video asks cancel-or-wait, and keeps the app running after the last window closes.
import AntiChatDesign
import AntiChatFoundation
import AntiChatPlatform
import AntiChatHarness
import AntiChatStorage
import AntiChatUI
import AppKit
import Defaults

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Signposts.launchPhase("willFinishLaunching")
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": true])
        // Probe/harness/dev-container/XCTest-hosted launches run in the background (never activate, no Dock icon).
        MainActor.assumeIsolated {
            BackgroundRun.enableIfWanted()
            // RC e8fe19986: a `.prohibited` run may get its main window created but never ordered in; the background
            // run orders it in (concealed) once. Onboarding keeps the main windows hidden until its last step.
            if BackgroundRun.isOn {
                BackgroundRun.presentsUnshownWindow = { Self.isMainSceneWindow($0) && OnboardingWindowController.current == nil }
            }
        }
        // M10.T02 (R-225 AC3/AC5): Move to Applications before onboarding; never for Debug or background launches.
        MainActor.assumeIsolated { MoveToApplicationsService.runIfNeeded(backgroundLaunch: BackgroundRun.isOn) }
    }

    /// A launch that restored no window (the last one was closed while the app kept running) opens one.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Signposts.launchPhase("didFinishLaunching")
        Self.startUpdaterAfterFirstPaint()
        // M9.T05 (NFR-U1): the deferred launch services (AfterFirstFrame) run once the first composer is focused in a
        // visible window; a launch that never gets there (onboarding, a blocked database, a slow Mac) runs them after
        // 1 s, and a background test/probe run (never focused) on the next run-loop turn, as early as before.
        MainActor.assumeIsolated { AfterFirstFrame.armFallback(after: BackgroundRun.isOn ? 0 : 1) }
        MainActor.assumeIsolated {
            MenuItemIdentifiers.install()  // menu items carry their own ids (menu.file.newEvilChat, …)
            #if DEBUG
            // M9.T03: the accessibility audit tests' helper (tools/ci/a11y-axstate) finds exactly this process by the
            // pid the test asked it to write, not by guessing among several running instances.
            if let path = ProcessInfo.processInfo.environment["ANTICHAT_A11Y_PIDFILE"], !path.isEmpty {
                try? String(getpid()).write(toFile: path, atomically: true, encoding: .utf8)
            }
            AXAttributeProbe.startIfAsked()  // Q-015 r5: AXValueDescription / AXHelp for the UI tests
            #endif
        }
        // M2.T18 (S-00): first run shows onboarding; the main windows wait behind it until the last step.
        if let db = Self.onboardingDatabase, OnboardingGate.shouldShow() {
            MainActor.assumeIsolated {
                let onboarding = OnboardingWindowController.present(database: db) {
                    for w in Self.hiddenForOnboarding { BackgroundRun.makeKeyAndOrderFront(w) }
                    Self.hiddenForOnboarding = []
                    Self.openWindowIfNone()
                }
                Self.hideMainWindows(except: onboarding)
                #if DEBUG || ANTICHAT_PERF_HARNESS
                if let out = LaunchOptions.current.onboardingProbe { OnboardingProbe.start(onboarding, out: out) }  // M2.T20
                if let out = LaunchOptions.current.visualQAProbe { VisualQAProbe.startOnboarding(onboarding, out: out) }  // M2.T26
                #endif
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated { Self.openWindowIfNone(atLaunch: true) }
        }
    }

    /// M10.T03 (R-219; NFR-U1): Sparkle starts a few seconds after launch, once the first window has painted, and
    /// only in Release builds launched normally (Debug, probes, dev containers and XCTest hosts never create it).
    static func startUpdaterAfterFirstPaint() {
        #if !DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated {
                guard !BackgroundRun.isOn else { return }
                UpdaterService.shared.start()
            }
        }
        #endif
    }

    /// M2.T18: set by AntiChatApp.init (the app database) so the onboarding gate can run at launch.
    nonisolated(unsafe) static var onboardingDatabase: AppDatabase?
    @MainActor static var hiddenForOnboarding: [NSWindow] = []

    /// SwiftUI may still be creating the scene's window: hide main windows for the first second.
    @MainActor static func hideMainWindows(except onboarding: OnboardingWindowController, tries: Int = 10) {
        for w in NSApp.windows where w.isVisible && w.canBecomeMain && w !== onboarding.window {
            w.orderOut(nil)
            hiddenForOnboarding.append(w)
        }
        guard tries > 0, OnboardingWindowController.current != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated { hideMainWindows(except: onboarding, tries: tries - 1) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { Self.openWindowIfNone() } }
        return false
    }

    /// File › New Window (the scene's own `openWindow`), when no main window is on screen.
    /// `atLaunch`: the scene's own window may exist but not be ordered in yet (a busy Mac, or a background run: seen
    /// at +1 s as `main-AppWindow-1`, not visible, not main-capable yet), so any window of the `main` WindowGroup
    /// counts; otherwise a second window opened at every slow launch (M8.T16, PR3 re-run).
    @MainActor
    static func openWindowIfNone(atLaunch: Bool = false) {
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        if atLaunch, NSApp.windows.contains(where: { Self.isMainSceneWindow($0) }) { return }
        let title = CopyKey("menu.file.newWindow").string()
        for top in NSApp.mainMenu?.items ?? [] {
            if let menu = top.submenu, let i = menu.items.firstIndex(where: { $0.title == title }) {
                menu.performActionForItem(at: i)
                return
            }
        }
    }

    /// A window of the `WindowGroup(id: "main")` scene (SwiftUI names them `main-AppWindow-<n>`).
    @MainActor
    static func isMainSceneWindow(_ w: NSWindow) -> Bool {
        w.identifier?.rawValue.hasPrefix(MainWindowID.main + "-") == true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // M8.T12 (R-042 AC3): a picture or video being made keeps the app running whatever the menu bar setting (the
        // Dock shows a badge until it is done); M5.T11 (NFR-VID3): closing the window never ends a video job.
        MainActor.assumeIsolated {
            MediaJobQuitGuard.terminateAfterLastWindowClosed(menuBarItem: Defaults[.menuBarItem])
                && !(MediaJobQueue.shared?.hasRunning ?? false) && AppNotifications.activeJobs.isEmpty
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // M4.T04 step 6: a running picture/video job asks first; then the incognito guard (M1.T20).
        // A relaunch the app started itself (restore, Remove everything) quits at once (review fix, M8.T16).
        MainActor.assumeIsolated {
            if AppRelaunch.inProgress {
                IncognitoQuitGuard.discardAll()
                return .terminateNow
            }
            return MediaJobQuitGuard.reply(sender) { IncognitoQuitGuard.reply(sender) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            IncognitoQuitGuard.discardAll()
            LastShownChatStore.shared.cleanExit()  // M10.T09: a normal quit; reopening is macOS restoration's
        }
    }
}
