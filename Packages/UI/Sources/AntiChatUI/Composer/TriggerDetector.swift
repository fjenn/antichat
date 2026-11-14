// Trigger detection for the composer's inline menu (M1.T17 step 2; R-013 AC2; IS-6, ChatGPT F-027). Pure and
// unit-tested (TriggerDetectorTests); ComposerMenus calls it on every text or caret change.
//   `/` opens the menu only at the start of the input (Claude's rule): "/ab" at offset 0 → query "ab".
//   `@` opens it anywhere a word starts (ChatGPT's rule): at the start or after whitespace, so "a@b.com" never does.
//   The query is the text from the trigger to the caret; it ends at whitespace (typing a space closes the menu).
// The meaning of the two keys never changes by mode (IS-6; ChatGPT Work mode's "@" did, and picked the wrong item).
import Foundation

public struct ComposerTrigger: Equatable, Sendable {
    public enum Key: Character, Sendable { case slash = "/", at = "@" }

    public let key: Key
    /// UTF-16 offset of the trigger character in the text.
    public let location: Int
    /// What was typed after the trigger, up to the caret.
    public let query: String

    public init(key: Key, location: Int, query: String) {
        self.key = key
        self.location = location
        self.query = query
    }

    /// The trigger character plus the query (UTF-16): what a pick removes from the text.
    public var range: NSRange { NSRange(location: location, length: 1 + (query as NSString).length) }
}

public enum TriggerDetector {
    /// The active trigger for `text` with the caret at UTF-16 offset `caret`, or nil.
    /// - Parameter hasMarkedText: an IME composition is in progress (never a trigger while composing).
    public static func detect(text: String, caret: Int, hasMarkedText: Bool = false) -> ComposerTrigger? {
        guard !hasMarkedText else { return nil }
        let ns = text as NSString
        guard caret > 0, caret <= ns.length else { return nil }
        // Walk back from the caret to the start of the current word.
        var start = caret
        while start > 0 {
            let c = ns.character(at: start - 1)
            if let scalar = Unicode.Scalar(c), CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
            start -= 1
        }
        guard start < caret else { return nil }
        let first = ns.character(at: start)
        let query = ns.substring(with: NSRange(location: start + 1, length: caret - start - 1))
        switch first {
        case 0x2F where start == 0:  // "/" at the input start only
            return ComposerTrigger(key: .slash, location: start, query: query)
        case 0x40:  // "@" at a word start
            return ComposerTrigger(key: .at, location: start, query: query)
        default:
            return nil
        }
    }

    /// `text` with the trigger and its query removed (what picking an item leaves), and the caret offset after it.
    /// A space left doubled by the removal is collapsed.
    public static func removing(_ trigger: ComposerTrigger, from text: String) -> (text: String, caret: Int) {
        let ns = text as NSString
        guard let r = removalRange(trigger, in: text) else { return (text, ns.length) }
        return (ns.replacingCharacters(in: r, with: ""), r.location)
    }

    /// The UTF-16 range a pick deletes: the trigger and its query, plus one following space when the removal would
    /// otherwise leave two spaces (or a leading one). nil when the trigger is not inside `text`.
    public static func removalRange(_ trigger: ComposerTrigger, in text: String) -> NSRange? {
        let ns = text as NSString
        var r = trigger.range
        guard NSMaxRange(r) <= ns.length else { return nil }
        let before = r.location > 0 ? ns.character(at: r.location - 1) : nil
        let after = NSMaxRange(r) < ns.length ? ns.character(at: NSMaxRange(r)) : nil
        if after == 0x20, before == nil || before == 0x20 { r.length += 1 }
        return r
    }
}
