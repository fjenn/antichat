// M4.T04 step 7: the `-UseScriptedImageEngine <script.json>` script (DEBUG/test only). The app reads the JSON and
// sends an `ImageModelSet` whose `diffusionModel` is `scripted:<steps>:<delayMs>:<crashAtStep>:<slowCancelMs>`; the
// helper's ScriptedImageEngine (Engines/Jobs) runs it instead of sd-server. No weights, no content: gradient outputs.
import Foundation

public struct ScriptedImageScript: Codable, Sendable, Equatable {
    public var steps: Int
    /// Milliseconds per step.
    public var delayMs: Int
    /// Abort the helper at this step (0 = never).
    public var crashAtStep: Int
    /// After a cancel, wait this long before stopping (0 = at once).
    public var slowCancelMs: Int
    /// Declared memory footprint (allocated as MTLBuffers for the job's lifetime).
    public var footprintBytes: UInt64

    public init(steps: Int = 4, delayMs: Int = 50, crashAtStep: Int = 0, slowCancelMs: Int = 0, footprintBytes: UInt64 = 0) {
        self.steps = steps
        self.delayMs = delayMs
        self.crashAtStep = crashAtStep
        self.slowCancelMs = slowCancelMs
        self.footprintBytes = footprintBytes
    }

    enum CodingKeys: String, CodingKey { case steps, delayMs, crashAtStep, slowCancelMs, footprintBytes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        steps = try c.decodeIfPresent(Int.self, forKey: .steps) ?? 4
        delayMs = try c.decodeIfPresent(Int.self, forKey: .delayMs) ?? 50
        crashAtStep = try c.decodeIfPresent(Int.self, forKey: .crashAtStep) ?? 0
        slowCancelMs = try c.decodeIfPresent(Int.self, forKey: .slowCancelMs) ?? 0
        footprintBytes = try c.decodeIfPresent(UInt64.self, forKey: .footprintBytes) ?? 0
    }

    public static func load(_ url: URL) throws -> ScriptedImageScript {
        try JSONDecoder().decode(ScriptedImageScript.self, from: Data(contentsOf: url))
    }

    public func modelSet(key: String = "scripted-image") -> ImageModelSet {
        ImageModelSet(key: key, diffusionModel: "scripted:\(steps):\(delayMs):\(crashAtStep):\(slowCancelMs)", llm: "", vae: "",
                      footprintBytes: footprintBytes)
    }
}
