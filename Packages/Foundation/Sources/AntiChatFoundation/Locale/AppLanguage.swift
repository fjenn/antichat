// M9.T04 step 3 (R-102 AC1): the UI language follows macOS by default, with an override in Settings → General.
// The override is the app-domain `AppleLanguages` default (what macOS itself uses per app); it takes effect on the
// next launch, so the row shows "AntiChat will use this language after it restarts".
import Foundation

public enum AppLanguage: String, CaseIterable, Sendable, Identifiable {
    case system, en, de, fr, es, nl, pt

    public var id: String { rawValue }

    /// The languages the catalog ships (A-M9-T04a: `pt` is written in Brazilian Portuguese; pt-BR and pt-PT users
    /// both resolve to it).
    public static let shipped: [AppLanguage] = [.en, .de, .fr, .es, .nl, .pt]

    /// Copy key of the picker label (native names; "Follow macOS" for `.system`).
    public var copyKey: String {
        self == .system ? "set.general.language.value" : "set.general.language.\(rawValue)"
    }

    /// The override stored in `defaults` (nil key → follow macOS).
    public static func current(_ defaults: UserDefaults = AppDefaults.standard) -> AppLanguage {
        guard defaults.bool(forKey: overrideMarker), let first = defaults.stringArray(forKey: "AppleLanguages")?.first
        else { return .system }
        return AppLanguage(rawValue: String(first.prefix(2))) ?? .system
    }

    /// Stores the choice (`.system` removes the override).
    public static func set(_ lang: AppLanguage, _ defaults: UserDefaults = AppDefaults.standard) {
        if lang == .system {
            defaults.removeObject(forKey: "AppleLanguages")
            defaults.removeObject(forKey: overrideMarker)
        } else {
            defaults.set([lang.rawValue], forKey: "AppleLanguages")
            defaults.set(true, forKey: overrideMarker)
        }
    }

    /// The choice in effect for this process (read once; a change applies at the next launch).
    public static let atLaunch = AppLanguage.current()

    /// The language the running process actually uses (fixed at launch).
    public static var running: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// Marks that `AppleLanguages` in our domain is ours (not inherited from the global domain).
    static let overrideMarker = "appLanguageOverride"
}
