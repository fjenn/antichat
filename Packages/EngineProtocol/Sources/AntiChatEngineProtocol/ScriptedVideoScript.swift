// M5.T03 (DEBUG / test only): the script behind `-UseScriptedVideoEngine <script.json>`. A video job whose
// `VideoRequest.generator` is `swift-scripted:<json>` runs the helper's ScriptedVideoEngine instead of the runtime:
// step events, an animated preview per step and a final gradient frame sequence (2–3 s at 16 fps by default), so the
// UI and the gate wiring can be tested without the video runtime (M5.T05, T06, T11).
import Foundation

public struct ScriptedVideoScript: Codable, Sendable, Equatable {
    public var steps: Int = 3
    public var delayMs: Int = 50
    /// Final frames and their rate.
    public var frames: Int = 40
    public var fps: Int = 16
    /// Frames per step's animated preview (0 = no previews).
    public var previewFrames: Int = 6
    /// The scripted clip carries a silent audio track (M5.T07 mux tests).
    public var audio: Bool = false

    public init(steps: Int = 3, delayMs: Int = 50, frames: Int = 40, fps: Int = 16, previewFrames: Int = 6, audio: Bool = false) {
        self.steps = steps
        self.delayMs = delayMs
        self.frames = frames
        self.fps = fps
        self.previewFrames = previewFrames
        self.audio = audio
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        steps = try c.decodeIfPresent(Int.self, forKey: .steps) ?? 3
        delayMs = try c.decodeIfPresent(Int.self, forKey: .delayMs) ?? 50
        frames = try c.decodeIfPresent(Int.self, forKey: .frames) ?? 40
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 16
        previewFrames = try c.decodeIfPresent(Int.self, forKey: .previewFrames) ?? 6
        audio = try c.decodeIfPresent(Bool.self, forKey: .audio) ?? false
    }

    public static let scheme = "swift-scripted:"

    /// The `VideoRequest.generator` value for this script.
    public var generator: String {
        Self.scheme + (String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "{}")
    }

    public static func parse(generator: String?) -> ScriptedVideoScript? {
        guard let g = generator, g.hasPrefix(scheme) else { return nil }
        return try? JSONDecoder().decode(ScriptedVideoScript.self, from: Data(g.dropFirst(scheme.count).utf8))
    }

    public static func load(_ path: String) -> ScriptedVideoScript? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(ScriptedVideoScript.self, from: d)
    }
}
