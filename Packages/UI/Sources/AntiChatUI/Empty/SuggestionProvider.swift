// Empty-state headline and suggestion cards (M1.T07 step 2; screens.md S-05, components.md §5 SuggestionCard).
// Static local lists per pack, filtered by the enabled packs. No network, no model call (AT-001 leg 4).
import AntiChatDesign
import AntiChatFoundation
import Foundation

/// The packs a suggestion can come from (VISION §0: Chat, Voice, Photo, Video; Files is the chat file tools).
public enum SuggestionPack: String, CaseIterable, Sendable {
    case chat, voice, photo, video, files
}

public struct Suggestion: Identifiable, Hashable, Sendable {
    public let key: CopyKey
    public let pack: SuggestionPack
    public let symbol: String
    public var id: String { key.rawValue }
    /// What a click puts in the composer (the visible line itself).
    public var text: String { key.string() }
}

/// SplitMix64: a tiny seedable generator, so a fixed seed set gives the same headlines and cards on every run.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public enum EmptyHeadline {
    /// One calm headline on every new chat (`empty.headline`); it used to change at random between five.
    public static let key = CopyKey("empty.headline")

    public static func pick(seed: UInt64) -> CopyKey { key }
}

public enum SuggestionProvider {
    public static let maxCards = 4

    /// Every registered list (M1 shows chat only; the others appear once their pack is installed and on).
    public static let catalog: [SuggestionPack: [Suggestion]] = [
        .chat: [
            Suggestion(key: CopyKey("sugg.chat.1"), pack: .chat, symbol: "lightbulb"),
            Suggestion(key: CopyKey("sugg.chat.2"), pack: .chat, symbol: "envelope"),
            Suggestion(key: CopyKey("sugg.chat.3"), pack: .chat, symbol: "sparkles"),
            Suggestion(key: CopyKey("sugg.chat.4"), pack: .chat, symbol: "calendar"),
        ],
        .voice: [Suggestion(key: CopyKey("sugg.voice"), pack: .voice, symbol: "waveform")],
        .photo: [Suggestion(key: CopyKey("sugg.image"), pack: .photo, symbol: "photo")],
        .files: [
            Suggestion(key: CopyKey("sugg.pdf"), pack: .files, symbol: "doc.text"),
            Suggestion(key: CopyKey("sugg.sheet"), pack: .files, symbol: "tablecells"),
        ],
        .video: [],
    ]

    /// Packs that are installed and turned on. M1 default: chat only. `-FakeInstalledPacks` / `-FakeDisabledPacks`
    /// (M1.md convention 10) override it; the real pack state arrives with M2's capability manager.
    public static func enabledPacks(options: LaunchOptions = .current) -> Set<SuggestionPack> {
        var packs: Set<SuggestionPack> = [.chat]
        // M2.T20: the packs chosen in onboarding (installed or still downloading).
        if options.fakeInstalledPacks == nil, options.fakeDisabledPacks == nil, let chosen = StarterSuggestions.chosenPacks() {
            packs.formUnion(chosen)
        }
        if let installed = options.fakeInstalledPacks {
            packs.formUnion(installed.compactMap { SuggestionPack(rawValue: $0.lowercased()) })
        }
        if let disabled = options.fakeDisabledPacks {
            packs.subtract(disabled.compactMap { SuggestionPack(rawValue: $0.lowercased()) })
        }
        return packs
    }

    /// Up to `maxCards` suggestions from the enabled packs: one per non-chat pack first (shows what is possible,
    /// P5), then chat lines; order inside the result is shuffled by `seed`.
    public static func suggestions(enabled: Set<SuggestionPack>, seed: UInt64) -> [Suggestion] {
        var g = SeededGenerator(seed: seed ^ 0x5EED)
        var picked: [Suggestion] = []
        for pack in SuggestionPack.allCases where pack != .chat && enabled.contains(pack) {
            if let s = catalog[pack]?.randomElement(using: &g) { picked.append(s) }
        }
        if enabled.contains(.chat) {
            for s in (catalog[.chat] ?? []).shuffled(using: &g) where picked.count < maxCards { picked.append(s) }
        }
        return Array(picked.prefix(maxCards)).shuffled(using: &g)
    }
}
