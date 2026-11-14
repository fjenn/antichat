// M5.T10 step 4 (R-040 AC1, R-043; P-media-11 tool path): the `create_video` tool contract offered to the chat model
// when Video is available. The chat model rewrites the user's words into a detailed `prompt` (as for images, M4.T07);
// a valid call becomes the plan card (M5.T09) and, on [Start] or the countdown, one job of the media queue. The
// call never picks resolution or steps (the tier's presets and Settings → Advanced do, R-044); `length`, `shape` and
// `sound` are only the card's starting picks. `source_image_id` = the picture to animate (image-to-video).
import Foundation

public enum CreateVideoTool {
    public static let name = "create_video"
    public static let description = "Create a short video clip from a text description, or animate a picture. Use it whenever the user asks for a video, clip or animation."
    public static let lengths = ["short", "medium"]
    public static let shapes = ["square", "portrait", "landscape"]

    public static let parametersJSON = #"""
    {"type":"object","required":["prompt"],"properties":{"prompt":{"type":"string","description":"What the clip shows and how it moves, in detail."},"negative_prompt":{"type":"string","description":"What the clip must not show."},"length":{"type":"string","enum":["short","medium"],"default":"short"},"shape":{"type":"string","enum":["square","portrait","landscape"],"default":"landscape"},"sound":{"type":"boolean","default":false,"description":"Add a sound track where this Mac supports it."},"seed":{"type":"integer"},"source_image_id":{"type":"string","description":"The picture to animate (image-to-video)."}}}
    """#

    /// One validated call.
    public struct Call: Sendable, Equatable {
        public var prompt: String
        public var negativePrompt: String?
        /// nil = not named (the card starts from the tier default).
        public var length: String?
        public var shape: String?
        public var sound: Bool?
        public var seed: Int64?
        public var sourceImageID: String?

        public init(prompt: String, negativePrompt: String? = nil, length: String? = nil, shape: String? = nil,
                    sound: Bool? = nil, seed: Int64? = nil, sourceImageID: String? = nil) {
            self.prompt = prompt; self.negativePrompt = negativePrompt; self.length = length; self.shape = shape
            self.sound = sound; self.seed = seed; self.sourceImageID = sourceImageID
        }
    }

    public enum ParseError: Error, Equatable { case badArguments(String) }

    /// The schema's rules: a non-empty prompt, `length` / `shape` from their enums, `sound` a Bool, `seed` an
    /// integer ≥ 0. Unknown keys are ignored (the model's extra fields never fail a call).
    public static func parse(_ json: String) throws -> Call {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            throw ParseError.badArguments("arguments are not a JSON object")
        }
        guard let prompt = (o["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            throw ParseError.badArguments("prompt is required")
        }
        var call = Call(prompt: prompt)
        if let n = o["negative_prompt"] {
            guard let s = n as? String else { throw ParseError.badArguments("negative_prompt must be a string") }
            call.negativePrompt = s.isEmpty ? nil : s
        }
        if let l = o["length"] {
            guard let s = l as? String, lengths.contains(s) else { throw ParseError.badArguments("length must be short or medium") }
            call.length = s
        }
        if let v = o["shape"] {
            guard let s = v as? String, shapes.contains(s) else {
                throw ParseError.badArguments("shape must be square, portrait or landscape")
            }
            call.shape = s
        }
        if let v = o["sound"] {
            guard let b = v as? Bool, CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() else {
                throw ParseError.badArguments("sound must be true or false")
            }
            call.sound = b
        }
        if let v = o["seed"] {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue >= 0,
                  n.doubleValue == n.doubleValue.rounded(), n.doubleValue <= Double(Int64.max) else {
                throw ParseError.badArguments("seed must be a non-negative integer")
            }
            call.seed = n.int64Value
        }
        if let v = o["source_image_id"] {
            guard let s = v as? String else { throw ParseError.badArguments("source_image_id must be a string") }
            call.sourceImageID = s.isEmpty ? nil : s
        }
        return call
    }
}
