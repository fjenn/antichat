// M6.T03 step 1 (R-279): a chat whose prompt carries a whole document asks the engine to keep that prefix warm.
// `prefixHash = sha256(stable prefix ‖ document blocks)`, where the stable prefix is the leading system layers and the
// document blocks are every `<document … untrusted="true">…</document>` of the conversation in order (they sit before
// the user's text at a fixed position, M6.T02, so a follow-up's prompt starts with the same tokens). Excerpt-only
// turns are not pinned (their excerpts change with each question).
import AntiChatEngineProtocol
import CryptoKit
import Foundation

public enum DocumentWarmth {
    /// The pin for `request`, or nil when no whole document is in its prompt.
    public static func pin(for request: ChatRequest, chatID: String) -> PrefixPin? {
        var stable: [String] = []
        var docs: [String] = []
        var inHead = true
        for item in request.messages {
            switch item {
            case .layer(let l): if inHead { stable.append(l.content) }
            case .message(let m):
                inHead = false
                guard m.role == .user else { continue }
                docs += documentBlocks(m.content)
            }
        }
        guard !docs.isEmpty else { return nil }
        let joined = (stable + docs).joined(separator: "\u{1E}")
        let hash = SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
        return PrefixPin(chatID: chatID, prefixHash: hash, priority: 1)
    }

    static func documentBlocks(_ s: String) -> [String] {
        var out: [String] = []
        var rest = s[...]
        while let start = rest.range(of: "<document "), let end = rest.range(of: "</document>", range: start.upperBound..<rest.endIndex) {
            out.append(String(rest[start.lowerBound..<end.upperBound]))
            rest = rest[end.upperBound...]
        }
        return out
    }
}
