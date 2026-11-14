// M7.T05 step 1 (R-228 AC1–AC4): show the fresh-information hint under a finished local answer when
//   detector hit ∧ web search is not available-and-on ∧ the chat has not dismissed it ∧ "Suggest web search when
//   helpful" is on (default true, settings-map §7, under Tools & Connections → Web search).
// The hint never turns search on: [Turn on web search] opens the consent sheet (M7.T03); [Not now] dismisses it for
// that chat (stored as the `hint:freshDismissed` marker in `chat.tools_json`, no migration). Offline (Offline only or
// no network) the hint reads `hint.fresh.offline` and has no buttons.
import AntiChatTools
import Foundation

public enum FreshnessHintPolicy {
    public enum Hint: Sendable, Equatable {
        /// `hint.fresh` + [`hint.fresh.on`] [`hint.fresh.later`].
        case offer
        /// `hint.fresh.offline`, no buttons.
        case offline
    }

    /// The `chat.tools_json` marker of a chat whose hint was dismissed (not a chip id: no menu item matches it).
    public static let dismissedMarker = "hint:freshDismissed"

    /// What to show under the answer to `prompt` (nil = nothing).
    public static func hint(prompt: String, detector: FreshnessDetector?, cutoff: String?, webNeededScore: Float? = nil,
                            search: WebSearchAvailability.State, dismissed: Bool, suggestEnabled: Bool) -> Hint? {
        guard suggestEnabled, !dismissed, search != .available,
              detector?.hit(prompt, cutoff: cutoff, webNeededScore: webNeededScore) != nil else { return nil }
        switch search {
        case .available: return nil
        case .switchedOff: return .offer
        case .offlineOnly, .noNetwork: return .offline
        }
    }

    public static func shouldShow(prompt: String, detector: FreshnessDetector?, cutoff: String?, webNeededScore: Float? = nil,
                                  search: WebSearchAvailability.State, dismissed: Bool, suggestEnabled: Bool) -> Bool {
        hint(prompt: prompt, detector: detector, cutoff: cutoff, webNeededScore: webNeededScore, search: search,
             dismissed: dismissed, suggestEnabled: suggestEnabled) != nil
    }
}
