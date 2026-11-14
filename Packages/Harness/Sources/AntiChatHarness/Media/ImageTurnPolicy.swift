// M4.T06 step 4 (R-236): what the assistant says after an image job. On T0–T2 the chat model stepped aside for the
// diffusion model, so the turn's text is the templated `img.done.caption` — no LLM call, no chat reload; the NEXT user
// message brings the chat model back (`status.loadingModel`, NFR-U3). On T3+ the chat model is resident and writes one
// sentence (the ordinary text-only step after the tool). A withheld picture gets no caption at all (the blocked tile
// speaks, D-006); a failure is the tool's error line.
import Foundation

public enum ImageTurnPolicy {
    public static let imageTools: Set<String> = ["create_image", "edit_image"]

    /// The tool result the model sees (and the turn controller reads): `{"status": done|not_shown|unavailable|failed …}`.
    public enum Outcome: Sendable, Equatable {
        /// `path`: the stored picture (M4.T08: the card of a reloaded chat shows it, like file-out results).
        case done(imageID: String, width: Int?, height: Int?, path: String? = nil)
        /// Withheld by ChildSafetyCheck (the gate): no reason, no detail.
        case notShown
        /// Photo is not installed (no model).
        case unavailable
        /// M4.T16: the ChildSafetyCheck files are missing or damaged — no output may exist; the card offers the repair
        /// download of `sizeBytes` (R-285 AC6, `safety.missing`).
        case safetyMissing(sizeBytes: Int64)
        case failed(code: String)

        public var resultJSON: String {
            switch self {
            case .done(let id, let w, let h, let path):
                var o: [String: Any] = ["status": "done", "image_id": id]
                if let w, let h { o["width"] = w; o["height"] = h }
                if let path { o["path"] = path }
                return Self.json(o)
            case .notShown: return #"{"status":"not_shown"}"#
            case .unavailable: return #"{"status":"unavailable"}"#
            case .safetyMissing(let n): return Self.json(["status": "safety_missing", "size_bytes": n])
            case .failed(let code): return Self.json(["status": "failed", "error": code])
            }
        }

        static func json(_ o: [String: Any]) -> String {
            (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }

        public static func parse(_ result: String) -> Outcome? {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any],
                  let status = o["status"] as? String else { return nil }
            switch status {
            case "done": return .done(imageID: o["image_id"] as? String ?? "", width: o["width"] as? Int, height: o["height"] as? Int,
                                      path: o["path"] as? String)
            case "not_shown": return .notShown
            case "unavailable": return .unavailable
            case "safety_missing": return .safetyMissing(sizeBytes: (o["size_bytes"] as? NSNumber)?.int64Value ?? 0)
            case "failed": return .failed(code: o["error"] as? String ?? "")
            default: return nil
            }
        }
    }

    /// Live previews only where the detectors fit beside the generator (T3+). On T0–T2 the T1 peak with the
    /// detectors resident during generation was 9.62 GB against the 9.5 GB cap (NFR-R1), so those tiers show a
    /// progress bar only and check just the final image, after the generator unloaded (lead decision, M4).
    public static func livePreviews(tier: DeviceTier) -> Bool { ![.t0, .t1, .t2].contains(tier) }

    /// T0–T2: the turn ends after the image tool with the templated caption (or nothing); T3+: the model speaks.
    public static func endsTurnWithTemplate(tier: DeviceTier) -> Bool { [.t0, .t1, .t2].contains(tier) }

    /// The templated text for `outcome` (nil = no text: withheld, unavailable or failed show their own card/line).
    public static func caption(_ outcome: Outcome, caption: String) -> String? {
        if case .done = outcome { return caption }
        return nil
    }

    /// English source of `img.done.caption` (the UI passes the localized string).
    public static let defaultCaption = "Here's your picture."
}
