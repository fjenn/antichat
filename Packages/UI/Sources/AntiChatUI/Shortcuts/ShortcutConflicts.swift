// In-app collision detection (M1.T24 step 4): two actions may not share a combo. The Recorder's validation calls
// `validate`, so a colliding combo is refused (a warning, nothing saved) on top of the library's system/menu checks.
import AntiChatDesign
import KeyboardShortcuts

public enum ShortcutConflicts {
    /// The other action already using `shortcut`, if any.
    @MainActor
    public static func conflict(for shortcut: KeyboardShortcuts.Shortcut, assigningTo name: KeyboardShortcuts.Name,
                                current: (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? = {
                                    ShortcutStore.get($0)
                                }) -> KeyboardShortcuts.Name? {
        ShortcutCatalog.names.first { $0 != name && current($0) == shortcut }
    }

    /// Recorder validation: refuse a combo another action uses.
    @MainActor
    public static func validate(_ shortcut: KeyboardShortcuts.Shortcut,
                                for name: KeyboardShortcuts.Name) -> KeyboardShortcuts.ValidationResult {
        guard let other = conflict(for: shortcut, assigningTo: name),
              let entry = ShortcutCatalog.entry(for: other) else { return .allow }
        return .disallow(reason: CopyText(CopyKey("set.shortcuts.conflict"), ["action": entry.label.string()]).string)
    }

    /// Sets `shortcut` for `name` unless it collides; returns the colliding action (nothing saved) or nil (saved).
    @MainActor
    @discardableResult
    public static func assign(_ shortcut: KeyboardShortcuts.Shortcut?, to name: KeyboardShortcuts.Name) -> KeyboardShortcuts.Name? {
        if let shortcut, let other = conflict(for: shortcut, assigningTo: name) { return other }
        ShortcutStore.set(shortcut, for: name)
        return nil
    }
}
