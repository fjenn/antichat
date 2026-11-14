// Recovery actions an `AntiChatError` offers (architecture.md §7.1). The UI maps each to a button whose label
// comes from the copy deck; the error is shown on the object that failed (IS-10).
import Foundation

public enum RecoveryAction: Codable, Sendable, Hashable {
    case retry
    /// Settings deep link, e.g. `privacy.archived` (settings-map ids).
    case openSettings(path: String)
    /// Re-download a model; `slot` = catalog key when known.
    case redownload(slot: String?)
    case useSmallerModel
    /// `x-apple.systempreferences:` pane id.
    case openSystemSettings(pane: String)
    case exportData
    // M1 additions for the copy-deck §8 actions "Restart AntiChat", "Report a problem", "Continue",
    // "Update AntiChat" (A-M1-T05a).
    case restartApp
    case reportProblem
    case continueTurn
    case updateApp
}
