// M8.T11 (AT-226, AT-NFR-D7; tools/install-test): headless launch arguments for the install/remove test environment
// (no Accessibility grant needed in a VM). DEBUG builds only; each one acts and exits before any window opens.
//   -SeedLoginItem YES          SMAppService.mainApp.register()
//   -SeedShortcuts YES          sets the quick-panel and dictation shortcuts to non-default combos (⌃⌥Q, ⌃⌥D)
//   -PrintLoginItemStatus YES   prints `loginItem=<status>` (notRegistered / enabled / requiresApproval / notFound)
//   -PrintShortcuts YES         prints `shortcut <name>=<nil|default|custom>` for every name (custom = not the
//                               name's initial combo: a reinstall after Uninstall must show none)
//   -RunRemoveEverything YES    RemoveEverythingService.run() exactly as the confirmed sheet (typed check bypassed)
//   -RunUninstall YES           UninstallService.run() + Trash (`-UninstallKeepBundle YES` skips the Trash: dev runs)
import AntiChatFoundation
import AntiChatPlatform
import AppKit
import Foundation
import KeyboardShortcuts
import ServiceManagement
import UserNotifications

public enum InstallTestHooks {
    /// The shortcuts a reinstall must find unset (quick panel and dictation register in M8.T13 / M11; the names are
    /// reserved here so the reset covers them).
    static let seeded: [(KeyboardShortcuts.Name, KeyboardShortcuts.Shortcut)] = [
        (.quickPanel, .init(.q, modifiers: [.control, .option])),  // M8.T13: default ⌥Space, so seed another combo
        (.init("dictation"), .init(.d, modifiers: [.control, .option])),
    ]

    /// Handles the first hook present and exits; returns false when none is (the app launches normally).
    @MainActor public static func handle(_ defaults: UserDefaults = AppDefaults.standard) -> Bool {
        #if DEBUG
        func on(_ k: String) -> Bool { defaults.bool(forKey: k) }
        if on("SeedLoginItem") {
            do { try SMAppService.mainApp.register() } catch { print("loginItem register error: \(error)") }
            print("loginItem=\(status())")
            exit(0)
        }
        if on("SeedShortcuts") {
            for (n, s) in seeded { KeyboardShortcuts.setShortcut(s, for: n) }
            print("shortcuts seeded \(seeded.count)")
            exit(0)
        }
        if on("PrintLoginItemStatus") {
            print("loginItem=\(status())")
            exit(0)
        }
        if on("PrintShortcuts") {
            for n in seeded.map(\.0) + ShortcutCatalog.names.filter({ n in !seeded.contains { $0.0 == n } }) {
                let s = KeyboardShortcuts.getShortcut(for: n)
                print("shortcut \(n.rawValue)=\(s == nil ? "nil" : s == n.initialShortcut ? "default" : "custom")")
            }
            exit(0)
        }
        if on("RunRemoveEverything") {
            Task { @MainActor in
                let r = await RemoveEverythingRunner.run()
                print("removeEverything removed=\(r.removed.count) leftovers=\(r.leftovers.count) keychain=\(r.keychainLeft.count) relay=\(r.relayNote)")
                exit(r.leftovers.isEmpty && r.keychainLeft.isEmpty ? 0 : 5)
            }
            RunLoop.main.run()
        }
        if on("RunUninstall") {
            Task { @MainActor in
                let script = try? await uninstallService().run()
                print("uninstall waiter=\(script?.path ?? "failed")")
                if !on("UninstallKeepBundle") {
                    // Isolation audit: explicitly @Sendable (nonisolated), not a main-actor closure.
                    let code: Int32 = script == nil ? 5 : 0
                    let done: @Sendable ([URL: URL], (any Error)?) -> Void = { _, _ in exit(code) }
                    NSWorkspace.shared.recycle([Bundle.main.bundleURL], completionHandler: done)
                } else {
                    exit(script == nil ? 5 : 0)
                }
            }
            RunLoop.main.run()
        }
        #endif
        return false
    }

    static func status() -> String {
        switch SMAppService.mainApp.status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
    }
}

/// `UNUserNotificationCenter.removeAllDeliveredNotifications()` (R-226 AC1: nothing of AntiChat stays in Notification
/// Center); skipped for a process without a bundle (tests).
enum NotificationCleanup {
    static func removeAllDelivered() {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
