// M2.T20 step 6 (R-201 AC7): the first chat after onboarding — headline `empty.headline`, the composer focused and three
// suggestion chips from the packs chosen in onboarding (installed or still queued): a personalization chip
// (`sugg.personal`) and one sample prompt per chosen pack (e.g. "Talk to me" only when Voice was chosen), topped up with
// chat lines. The chosen packs persist (`packs.enabled`) for the empty state of later chats too.
import AntiChatDesign
import AntiChatFoundation
import AntiChatPlatform
import Foundation

public enum StarterSuggestions {
    public static let didFinish = Notification.Name("AntiChat.StarterSuggestions.didFinish")
    static let firstChatKey = "onboarding.firstChatPending"
    static let packsKey = "packs.enabled"

    /// Onboarding finished with `packs` chosen: the next new chat is the first chat.
    public static func onboardingFinished(packs: Set<ModelPack>, defaults: UserDefaults = AppDefaults.standard) {
        defaults.set(packs.map(\.rawValue).sorted(), forKey: packsKey)
        defaults.set(true, forKey: firstChatKey)
        NotificationCenter.default.post(name: didFinish, object: nil)
    }

    /// The packs chosen in onboarding (nil before it ran).
    public static func chosenPacks(defaults: UserDefaults = AppDefaults.standard) -> Set<SuggestionPack>? {
        (defaults.array(forKey: packsKey) as? [String]).map { Set($0.compactMap(SuggestionPack.init(rawValue:))) }
    }

    /// True once, for the first new chat after onboarding.
    public static func consumeFirstChat(defaults: UserDefaults = AppDefaults.standard) -> Bool {
        guard defaults.bool(forKey: firstChatKey) else { return false }
        defaults.removeObject(forKey: firstChatKey)
        return true
    }

    /// Exactly three chips: personalization, one per chosen non-chat pack, then chat lines.
    public static func chips(packs: Set<SuggestionPack>) -> [Suggestion] {
        var out = [Suggestion(key: CopyKey("sugg.personal"), pack: .chat, symbol: "person.crop.circle")]
        for pack in [SuggestionPack.voice, .photo, .video] where packs.contains(pack) {
            if let s = SuggestionProvider.catalog[pack]?.first { out.append(s) }
        }
        for s in SuggestionProvider.catalog[.chat] ?? [] where out.count < 3 { out.append(s) }
        return Array(out.prefix(3))
    }
}
