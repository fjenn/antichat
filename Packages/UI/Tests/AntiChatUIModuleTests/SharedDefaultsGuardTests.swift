// fix/shared-defaults-isolation: nothing a Settings page shows may come from the test tool's `.standard` domain, which
// every test process on the Mac shares (every bundle of a run, every worktree's concurrent run). A value another
// process wrote there showed in SettingsSnapshotTests (Privacy's Offline only; General's quick-panel recorder; the
// chosen packs behind the Voice picker). App state reads `AppDefaults.standard` (a private in-memory store in a test
// process), the Settings keys `UserDefaults.antichat` (the test's scope, else that same store), the rebindable
// shortcuts `ShortcutStore`. `noSourceReadsTheSharedDomain` keeps it that way: a new direct read fails the run.
import AntiChatFoundation
import Defaults
import Foundation
import KeyboardShortcuts
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct SharedDefaultsGuardTests {
    /// The shipped sources (every package: the Settings pages and the stores behind them) never read or write the
    /// shared domain directly. Each exception names why it is not app state a page shows.
    @Test func noSourceReadsTheSharedDomain() throws {
        let packages = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let allowed: [(file: String, text: String)] = [
            ("AntiChatFoundation/Settings/AppDefaults.swift", ""),  // the definition
            ("AntiChatUI/Settings/Keys.swift", "antichat !== UserDefaults.standard"),  // identity check only
            ("AntiChatPlatform/Storage/RemoveEverythingService.swift", "removePersistentDomain"),  // Remove everything
            ("AntiChatUI/Failure/NewerDataWindow.swift", "removePersistentDomain"),  // the same, after a downgrade
            ("AntiChatUI/Settings/Privacy/ExportAllView.swift", "persistentDomain(forName:"),  // the app's domain by id, not in tests
            ("AntiChatKnowledge/Vision/ImageInputPreparer.swift", "ANTICHAT_DEV_CONTAINER"),  // launch flag, no page
            ("AntiChatUI/Shortcuts/ShortcutStore.swift", "KeyboardShortcuts."),  // the app path of the shortcut store
            ("AntiChatUI/Uninstall/InstallTestHooks.swift", "KeyboardShortcuts."),  // app-only hook on the library's storage
        ]
        let rules: [(name: String, hit: (String) -> Bool)] = [
            ("UserDefaults.standard", { $0.contains("UserDefaults.standard") }),
            ("a `= .standard` UserDefaults default", { $0.range(of: #"UserDefaults\s*=\s*\.standard\b"#, options: .regularExpression) != nil }),
            ("@AppStorage without store:", { $0.contains("@AppStorage(") && !$0.contains("store:") }),
            ("KeyboardShortcuts storage (use ShortcutStore)", {
                $0.range(of: #"KeyboardShortcuts\.(Recorder\(for:|getShortcut\(|setShortcut\(|reset\(|resetAll\()"#,
                         options: .regularExpression) != nil
            }),
        ]
        var found: [String] = []
        let fm = FileManager.default
        for package in try fm.contentsOfDirectory(atPath: packages.path).sorted() {
            let sources = packages.appendingPathComponent(package).appendingPathComponent("Sources")
            guard let walk = fm.enumerator(atPath: sources.path) else { continue }
            for case let rel as String in walk where rel.hasSuffix(".swift") {
                let text = try String(contentsOf: sources.appendingPathComponent(rel), encoding: .utf8)
                for (i, line) in text.components(separatedBy: "\n").enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    guard !code.hasPrefix("//") else { continue }
                    for rule in rules where rule.hit(code) {
                        let ok = allowed.contains { rel.hasSuffix($0.file) && ($0.text.isEmpty || code.contains($0.text)) }
                        if !ok { found.append("\(package)/Sources/\(rel):\(i + 1) \(rule.name)") }
                    }
                }
            }
        }
        #expect(found.isEmpty, "read AppDefaults.standard / UserDefaults.antichat / ShortcutStore instead: \(found)")
    }

    /// At run time: a value in the shared domain reaches neither the app store nor the Settings store, and their writes
    /// never reach it.
    @Test func theSharedDomainIsNeverRead() async {
        #expect(AppDefaults.isPrivate && AppDefaults.isTestProcess())
        let key = "sharedDefaultsGuard-\(UUID().uuidString)"
        UserDefaults.standard.set("shared", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        #expect(AppDefaults.standard.object(forKey: key) == nil)
        #expect(UserDefaults.antichat.object(forKey: key) == nil)
        let outsideScope = await Task.detached { UserDefaults.antichat.object(forKey: key) == nil }.value
        #expect(outsideScope, "the Settings store outside a test's scope read the shared domain")

        let own = "sharedDefaultsGuard-own-\(UUID().uuidString)"
        AppDefaults.standard.set(true, forKey: own)
        defer { AppDefaults.standard.removeObject(forKey: own) }
        #expect(AppDefaults.standard.bool(forKey: own) && UserDefaults.standard.object(forKey: own) == nil)
    }

    /// The rebindable shortcuts of a test live in its settings scope, never in the library's `.standard` keys.
    @Test func shortcutsLiveInTheTestsScope() {
        #expect(ShortcutStore.isPrivate)
        let key = ShortcutStore.key(.quickPanel)
        let shared = UserDefaults.standard.object(forKey: key) as? String
        #expect(ShortcutStore.get(.quickPanel) == KeyboardShortcuts.Name.quickPanel.initialShortcut)
        ShortcutStore.set(nil, for: .quickPanel)
        #expect(ShortcutStore.get(.quickPanel) == nil)
        ScopedSettingsDefaults.$scope.withValue(SettingsScope()) {  // another test's scope
            #expect(ShortcutStore.get(.quickPanel) == KeyboardShortcuts.Name.quickPanel.initialShortcut, "another test's store")
        }
        ShortcutStore.reset([.quickPanel])
        #expect(ShortcutStore.get(.quickPanel) == KeyboardShortcuts.Name.quickPanel.initialShortcut)
        #expect(UserDefaults.standard.object(forKey: key) as? String == shared, "nothing reached the library's storage")
    }
}
