// Where the rebindable shortcuts live (fix/shared-defaults-isolation). KeyboardShortcuts 3.1.0 keeps every combo in
// `UserDefaults.standard` (`KeyboardShortcuts_<name>`), with no way to pick the store. In the app that is the app
// domain and stays so: every read and write here goes through the library (global hotkey registration, its change
// notification). In a DEBUG unit-test process `.standard` is the test tool's domain, which every test process on the
// Mac shares, so a combo another process changed showed in a Settings snapshot (General's quick-panel recorder,
// Keyboard shortcuts). There the combos live in `UserDefaults.antichat` under the library's own keys and encoding:
// the test's settings scope, else the process's private store; and the recorders bind to it.
import AntiChatFoundation
import Foundation
import KeyboardShortcuts
import SwiftUI

@MainActor
public enum ShortcutStore {
    /// The library's change notification (ShortcutBindings and GlobalShortcuts observe it).
    static let didChange = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")

    /// True in a DEBUG unit-test process: combos are kept away from the shared test-tool domain.
    public static var isPrivate: Bool {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        AppDefaults.testProcessMemory != nil
        #else
        false
        #endif
    }

    /// The stored combo of `name` (its initial combo until one is set; nil = Off).
    public static func get(_ name: KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? {
        guard isPrivate else { return KeyboardShortcuts.getShortcut(for: name) }
        switch UserDefaults.antichat.object(forKey: key(name)) {
        case nil: return name.initialShortcut
        case let s as String: return s.data(using: .utf8).flatMap { try? JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: $0) }
        default: return nil  // `false`: turned off
        }
    }

    /// Sets `name`'s combo (nil = Off).
    public static func set(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name) {
        guard isPrivate else { return KeyboardShortcuts.setShortcut(shortcut, for: name) }
        let value: Any = shortcut.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? false
        UserDefaults.antichat.set(value, forKey: key(name))
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["name": name])
    }

    /// Back to the initial combos.
    public static func reset(_ names: [KeyboardShortcuts.Name]) {
        guard isPrivate else { return KeyboardShortcuts.reset(names) }
        for name in names {
            UserDefaults.antichat.removeObject(forKey: key(name))
            NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["name": name])
        }
    }

    /// The library's key, so a test store reads like the app's.
    static func key(_ name: KeyboardShortcuts.Name) -> String { "KeyboardShortcuts_\(name.rawValue)" }

    /// The recorder for `name`: the library's own storage in the app; bound to this store in a test process.
    public static func recorder(for name: KeyboardShortcuts.Name,
                                onChange: ((KeyboardShortcuts.Shortcut?) -> Void)? = nil) -> KeyboardShortcuts.Recorder<EmptyView> {
        guard isPrivate else { return KeyboardShortcuts.Recorder(for: name, onChange: onChange) }
        return KeyboardShortcuts.Recorder(shortcut: Binding(get: { get(name) }, set: { set($0, for: name) }), onChange: onChange)
    }
}
