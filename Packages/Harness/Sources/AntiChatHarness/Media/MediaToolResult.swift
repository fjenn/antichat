// M4.T16 (Release run at T4): what the chat model sees of a picture / video tool result. The stored result keeps the
// file path (the card of a reloaded chat shows the picture from it), but the model never needs it — it refers to a
// picture by `image_id` / `video_id` — and on T3+, where the model writes the sentence after the tool, it copied the
// path into the reply as a Markdown image (`![…](/…/Library/Application Support/…)`): a broken link that shows the
// user's folder layout. The model's copy drops `path` and `poster`; everything else is unchanged.
import Foundation

public enum MediaToolResult {
    static let hiddenKeys = ["path", "poster"]

    /// The model-visible text of `result` for tool `name` (unchanged for every other tool or non-JSON text).
    public static func forModel(name: String, result: String) -> String {
        guard ImageTurnPolicy.imageTools.contains(name) || VideoTurnPolicy.videoTools.contains(name),
              var o = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any] else { return result }
        // Nothing was made: without this line models answer "unavailable" with a vague or wrong sentence.
        if o["status"] as? String == "unavailable" {
            o["note"] = "Nothing was created: a download this needs is missing or not finished. Tell the user in one short sentence to check Settings > Capabilities and try again."
            return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? result
        }
        guard hiddenKeys.contains(where: { o[$0] != nil }) else { return result }
        for k in hiddenKeys { o.removeValue(forKey: k) }
        // The card already shows the result: without this line models append a made-up image link under it.
        if o["status"] as? String == "done" {
            o["note"] = "The result is already shown to the user. Reply with one short sentence. Do not add a link or a Markdown image."
        }
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? result
    }
}

/// M4.T16 (Release run at T4): the key that ties a media tool call to its queue job and plan (`TurnContext.toolCallID`,
/// `MediaJobQueue.job(forCall:)`, `VideoPlanBroker`). Local models number their calls per reply (`call_1` in every
/// turn), so the bare call id let an edit's card attach to the previous turn's finished create job — it showed the
/// old picture as the edit's result for the whole run, and a reopened earlier turn could show a later job. The reply
/// id makes it unique.
public enum MediaCallKey {
    public static func make(messageID: String?, callID: String) -> String {
        guard let messageID, !messageID.isEmpty else { return callID }
        return "\(messageID)/\(callID)"
    }

    /// The reply id of a key made with one (nil for a bare call id). R-291 AC2: a job row keeps it as `message_id`, so
    /// a relaunched card finds its interrupted job.
    public static func messageID(of key: String?) -> String? {
        guard let key, let slash = key.firstIndex(of: "/") else { return nil }
        let id = String(key[..<slash])
        return id.isEmpty ? nil : id
    }
}
