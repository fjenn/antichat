// M3.T13 (R-057, P-media-03 "tools in voice turns (reuse G-012) + spoken pointer"): a voice turn is a normal chat
// turn — the same tool registry, the same per-chat toggles (`tools_json`), the same approvals; nothing here filters
// or restricts a tool (R-241). What voice adds:
//   - the spoken pointer: a turn that made a picture / video / file ends with `voice.spokenPointer*`, spoken and
//     stored (`SpokenSummary`, appended by TurnController at finalisation while a conversation runs);
//   - spoken approvals: the ApprovalCard's title is said ("{action}. Allow?", `voice.approvalPrompt`), and the next
//     final transcript may answer it — "allow once" / "always allow" / "deny" (English keywords, v1; other languages
//     use the card's buttons).
import Foundation

public enum VoiceToolPolicy {
    /// The answer a spoken reply gives to a pending approval, or nil when it is not one (it is then an ordinary turn).
    public static func approvalAnswer(_ transcript: String) -> ApprovalAnswer? {
        // Whole short phrases only, never a substring: "I wouldn't allow that" must not approve anything (M3 review
        // finding 1). A phrase may be wrapped in a polite word ("yes please", "okay, allow once").
        let words = transcript.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty && !fillers.contains($0) }
        let phrase = words.joined(separator: " ")
        if phrase.isEmpty { return ["okay", "ok"].contains(transcript.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))) ? .allowOnce : nil }
        if always.contains(phrase) { return .always }
        if deny.contains(phrase) { return .deny }
        if once.contains(phrase) { return .allowOnce }
        return nil
    }

    static let fillers: Set<String> = ["please", "okay", "ok", "um", "uh", "well", "then", "just"]
    static let always: Set<String> = ["always allow", "allow always", "always"]
    static let deny: Set<String> = ["deny", "no", "nope", "don't", "don't allow", "do not allow", "cancel", "stop",
                                    "no don't", "deny it", "deny that", "don't do it", "don't allow it", "don't allow that", "no thanks", "not allowed"]
    static let once: Set<String> = ["allow", "allow once", "allow it", "allow it once", "allow this once", "yes", "yeah",
                                    "yep", "sure", "go ahead", "do it", "yes allow", "yes allow once"]

    /// The `{action}` of the spoken approval prompt: the card's title (the tool), readable aloud.
    public static func spokenAction(tool: String) -> String {
        let t = tool.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}

/// M3.T13 step 3 (R-057 AC2): what a voice turn made, said in one sentence each (picture, video, file), in order.
public enum SpokenSummary {
    public enum Medium: String, Sendable, Hashable, CaseIterable {
        case picture, video, file
    }

    /// The medium a successful call of `tool` puts in the chat (nil: none).
    public static func medium(forTool tool: String) -> Medium? {
        switch tool {
        case "create_image": .picture
        case "create_video": .video
        case "create_file", "create_document", "create_presentation", "create_chart", "export_table": .file
        default: nil
        }
    }

    /// M9 review H4: the medium a finished call of `tool` with tool result `result` actually put in the chat. A picture or
    /// clip counts only when its outcome is `done` (made and allowed): a safety block (`not_shown`), a cancelled plan card
    /// (`not_started`), a cancelled or failed job, `unavailable` or `safety_missing` put nothing there.
    public static func medium(forTool tool: String, result: String) -> Medium? {
        switch medium(forTool: tool) {
        case .picture?:
            guard case .done? = ImageTurnPolicy.Outcome.parse(result) else { return nil }
            return .picture
        case .video?:
            guard case .done? = VideoTurnPolicy.Outcome.parse(result) else { return nil }
            return .video
        case let other: return other
        }
    }

    /// The sentence(s) for the media made (each medium once, in the order made); nil when nothing was made.
    public static func pointer(made: [Medium], sentences: [Medium: String]) -> String? {
        var seen: Set<Medium> = []
        let parts = made.filter { seen.insert($0).inserted }.compactMap { sentences[$0] }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
