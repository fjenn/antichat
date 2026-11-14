// Settings → Personalization → prompt layer 3 (M1.T22 step 4, R-062 AC2): observes the Personalization keys and
// writes them into the chat environment's `PromptSettings`, which every TurnController snapshots once per turn —
// so an edit applies to the next new turn of every Normal and Evil chat, never mid-turn (M1.T14).
import AntiChatHarness
import Defaults
import Foundation

public final class PersonalizationSync: @unchecked Sendable {
    private var observation: Defaults.Observation?

    /// The current settings as the Harness value (unknown stored strings fall back to Default).
    public static func current() -> Personalization {
        Personalization(
            aboutYou: Personalization.clamp(Defaults[.aboutYou]),
            howToRespond: Personalization.clamp(Defaults[.howToRespond]),
            style: Personalization.StylePreset(rawValue: Defaults[.stylePreset]) ?? .default,
            warmth: Personalization.Level(rawValue: Defaults[.warmth]) ?? .default,
            enthusiasm: Personalization.Level(rawValue: Defaults[.enthusiasm]) ?? .default,
            headersAndLists: Personalization.Level(rawValue: Defaults[.headersAndLists]) ?? .default,
            emoji: Personalization.Level(rawValue: Defaults[.emoji]) ?? .default)
    }

    /// Starts syncing into `settings` (applies the current values immediately).
    public init(_ settings: PromptSettings) {
        observation = Defaults.observe(keys: .aboutYou, .howToRespond, .stylePreset, .warmth, .enthusiasm,
                                       .headersAndLists, .emoji) {
            let p = Self.current()
            settings.update { $0.personalization = p }
        }
    }

    deinit { observation?.invalidate() }
}
