// M2.T17 step 6 (R-240 AC1, R-241 prompt rule): the Evil prompt is the Normal prompt plus exactly one style sentence,
// the catalog's `tone_sentence` (fallback: the bundled baseline catalog's). It ships in the signed catalog, so it
// changes without an app release; it is one style sentence and the only prompt difference between the modes
// (D-005, D-006). Harness does not import Platform: the catalog side conforms to
// `ToneSentenceProviding` in AntiChatUI and is injected at the composition root.
// Placement: the M1 prompt layer (2) "mode clause" (PromptLayers; cache-stable, before custom instructions), which
// is the only place the two modes differ (A-M2-T17a: M2.md says "last stable layer"; M1.T14 fixed layer 2).
import AntiChatStorage
import Foundation

public protocol ToneSentenceProviding: Sendable {
    /// The catalog `tone_sentence` (current verified catalog, else the bundled baseline).
    var toneSentence: String { get }
}

public struct FixedToneSentence: ToneSentenceProviding {
    public let toneSentence: String
    public init(_ s: String) { toneSentence = s }
}

public enum ToneClause {
    /// The prompt mode for a chat of `mode`.
    public static func promptMode(_ mode: ChatMode, tone: any ToneSentenceProviding) -> PromptMode {
        switch mode {
        case .normal: .normal
        case .evil: .evil(toneSentence: tone.toneSentence.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Prompt settings for a chat of `mode`: Normal = the shared settings; Evil = the same, read through a view that
    /// sets only the mode clause.
    public static func settings(_ base: PromptSettings, mode: ChatMode, tone: any ToneSentenceProviding) -> PromptSettings {
        guard mode == .evil else { return base }
        return PromptSettings(derivedFrom: base) { inputs in
            var i = inputs
            i.mode = promptMode(.evil, tone: tone)
            return i
        }
    }
}
