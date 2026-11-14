// Custom instructions layer (M1.T14 step 1 (3); R-062 harness half; settings-map §6 Personalization).
// "About you" and "How should AntiChat respond" (≤ 3,000 chars each), the style preset and the four
// characteristics, rendered as the fixed sentences of `Resources/prompts/styles.json`. Default settings render
// nothing, so a user who never opens Personalization gets no layer (3) at all.
import Foundation

public struct Personalization: Sendable, Hashable, Codable {
    public enum StylePreset: String, Sendable, Hashable, Codable, CaseIterable {
        case `default`, professional, friendly, candid, efficient, quirky
    }

    public enum Level: String, Sendable, Hashable, Codable, CaseIterable {
        case more, `default`, less
    }

    /// Settings-map §6 caps both free-text fields at 3,000 characters; the composer clamps as well.
    public static let maxChars = 3000

    public var aboutYou: String
    public var howToRespond: String
    public var style: StylePreset
    public var warmth: Level
    public var enthusiasm: Level
    public var headersAndLists: Level
    public var emoji: Level

    public init(
        aboutYou: String = "", howToRespond: String = "", style: StylePreset = .default, warmth: Level = .default,
        enthusiasm: Level = .default, headersAndLists: Level = .default, emoji: Level = .default
    ) {
        self.aboutYou = aboutYou
        self.howToRespond = howToRespond
        self.style = style
        self.warmth = warmth
        self.enthusiasm = enthusiasm
        self.headersAndLists = headersAndLists
        self.emoji = emoji
    }

    /// Defaults everywhere (also what an incognito chat set to "Unpersonalized" uses, R-062 AC2).
    public static let none = Personalization()

    /// M1.T22: the Settings text areas' hard limit (R-062 AC1: the 3,001st character is refused).
    public static func clamp(_ s: String) -> String { s.count > maxChars ? String(s.prefix(maxChars)) : s }

    /// M1.T22 (R-062 AC2): the layer a turn uses. Normal and Evil chats use the settings; an incognito chat uses
    /// them when it is Personalized (settings-map §9 default) and none when it is Unpersonalized.
    public func effective(incognito: IncognitoPersonalization?) -> Personalization {
        incognito == .unpersonalized ? .none : self
    }
}

public extension PromptInputs {
    /// The inputs of one turn: the chat's mode and the personalization its incognito choice allows (R-062 AC2).
    func forTurn(mode: PromptMode, incognito: IncognitoPersonalization? = nil) -> PromptInputs {
        var i = incognito?.inputs(from: self) ?? self  // M1.T20's rule (IncognitoSession.swift)
        i.mode = mode
        return i
    }
}

/// The fixed sentences (`styles.json`). Loaded once from the Harness resource bundle.
struct StyleSentences: Decodable, Sendable {
    struct Pair: Decodable, Sendable {
        var more: String
        var less: String
    }

    var version: Int
    var about_you_header: String
    var how_to_respond_header: String
    var presets: [String: String]
    var characteristics: [String: Pair]

    static let bundled: StyleSentences = {
        guard let url = Bundle.module.url(forResource: "styles", withExtension: "json", subdirectory: "prompts"),
              let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(StyleSentences.self, from: data)
        else { preconditionFailure("AntiChatHarness: Resources/prompts/styles.json missing or invalid") }
        return s
    }()
}

enum PersonalizationLayer {
    /// Layer (3): one paragraph per non-default setting, in a fixed order.
    static func render(_ p: Personalization, sentences: StyleSentences = .bundled) -> String {
        var parts: [String] = []
        let about = PromptText.normalize(String(p.aboutYou.prefix(Personalization.maxChars)))
        if !about.isEmpty { parts.append(sentences.about_you_header + "\n" + about) }
        let how = PromptText.normalize(String(p.howToRespond.prefix(Personalization.maxChars)))
        if !how.isEmpty { parts.append(sentences.how_to_respond_header + "\n" + how) }
        var style: [String] = []
        if let s = sentences.presets[p.style.rawValue], !s.isEmpty { style.append(s) }
        for (key, level) in [("warmth", p.warmth), ("enthusiasm", p.enthusiasm), ("headers_lists", p.headersAndLists),
                             ("emoji", p.emoji)] {
            guard let pair = sentences.characteristics[key] else { continue }
            switch level {
            case .more: style.append(pair.more)
            case .less: style.append(pair.less)
            case .default: break
            }
        }
        if !style.isEmpty { parts.append(style.joined(separator: " ")) }
        return parts.joined(separator: "\n\n")
    }
}
