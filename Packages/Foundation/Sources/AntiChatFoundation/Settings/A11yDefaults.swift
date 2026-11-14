// M9.T01 (R-223 AC1, NFR-A2): how VoiceOver hears a streamed reply. "Per completed sentence or at the end (user
// setting)"; default at the end. The Defaults key is `announceReplies` (Settings → General, A-M9-T01a).
public enum AnnounceReplies: String, CaseIterable, Sendable {
    /// One polite announcement when the reply is done (first 400 characters).
    case atEnd
    /// Each completed sentence, queued, at most one announcement per 1.5 s.
    case perSentence

    public static let `default`: AnnounceReplies = .atEnd

    public var copyKey: String {
        switch self {
        case .atEnd: "set.a11y.announce.atEnd"
        case .perSentence: "set.a11y.announce.perSentence"
        }
    }
}
