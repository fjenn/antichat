// OversizeGuard (M1.T18 step 5; R-009 AC3): a single user prompt whose token estimate exceeds the model's context
// minus the output reserved for the reply can never be answered, so it is refused before any request exists
// (`ctx.tooLarge`, suggesting to attach it as a file). The composer keeps the text. Summaries cannot help: the
// prompt alone does not fit. The estimate is the vendored `TokenEstimator` (chars / 4 over UTF-8), the same one the
// budget uses, plus the per-message overhead and the ephemeral time line.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import OsaurusVendored

public enum OversizeGuard {
    /// The prompt's text as the model receives it: the composer text and its paste cards, one paragraph each.
    public static func tokens(text: String, pastedTexts: [String] = []) -> Int {
        let body = ((text.isEmpty ? [] : [text]) + pastedTexts).joined(separator: "\n\n")
        // The time line ("Current local time: 14:05 (UTC+01:00).", D-022) rides on every newest user turn.
        return TokenEstimator.estimate(body) + TokenEstimator.messageOverheadTokens + 10
    }

    /// The largest prompt the window can take with room for the reply.
    public static func limit(window: Int, reservedOutput: Int) -> Int { max(0, window - reservedOutput) }

    /// nil = fine; otherwise the error to show (`context.tooLarge` → copy `ctx.tooLarge`).
    public static func check(text: String, pastedTexts: [String] = [], window: Int, reservedOutput: Int) -> AntiChatError? {
        let n = tokens(text: text, pastedTexts: pastedTexts)
        let max = limit(window: window, reservedOutput: reservedOutput)
        guard n > max else { return nil }
        return AntiChatError(.contextTooLarge, detail: "prompt ≈ \(n) tokens > \(max) (window \(window) − \(reservedOutput) reserved)")
    }

    public static func check(text: String, pastedTexts: [String] = [], slot: ModelSlot, policy: ContextPolicy) -> AntiChatError? {
        check(text: text, pastedTexts: pastedTexts, window: policy.window(for: slot), reservedOutput: policy.reservedOutput)
    }
}
