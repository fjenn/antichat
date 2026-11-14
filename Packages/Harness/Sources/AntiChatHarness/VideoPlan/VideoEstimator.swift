// M5.T08 step 3 (R-046 AC2, G-046; P-media-12 design port of AtomicBot-ai/atomic-chat-core@6c7e9e8
// `src/diffusion/video-estimate.ts`, MIT — written from the PRD/patch description, the donor source is not in this
// repo): how long a video preset takes on this Mac and whether it fits the memory budget B.
//   time   = (encode_s + steps × t_step_s + frames × decode_s_per_frame) × history factor
//   memory = fits (peak + what must stay resident ≤ 85 % of B) | tight (≤ B) | exceeds (> B)
// The coefficients come from the speed table (`catalog/video-speed.yaml`, bundled as `video-speed.json`, A-M5-10):
// S4 measured on the dev Mac, S1–S3 = S4 × the pp512 ratio (K-015, hypotheses); the history factor (VideoHistory,
// median actual/estimated of the last 5 local runs of the preset) corrects the scaled rows on real hardware.
import Foundation

/// `video-speed.json`: presets (geometry + steps) and one coefficient row per speed class × preset.
public struct VideoSpeedTable: Codable, Sendable, Equatable {
    public struct Preset: Codable, Sendable, Equatable, Hashable {
        public var key: String
        public var model: String
        public var mode: String
        public var width: Int
        public var height: Int
        public var frames: Int
        public var steps: Int
        public init(key: String, model: String, mode: String, width: Int, height: Int, frames: Int, steps: Int) {
            self.key = key; self.model = model; self.mode = mode; self.width = width; self.height = height
            self.frames = frames; self.steps = steps
        }
    }

    public struct Row: Codable, Sendable, Equatable {
        public var speedClass: String
        public var preset: String
        public var encodeS: Double
        public var tStepS: Double
        public var decodeSPerFrame: Double
        public var peakGB: Double
        /// `measured` (S4, this Mac) or `scaled` (S1–S3 by pp512; a hypothesis).
        public var source: String
        public var n: Int?
        public var note: String?
        enum CodingKeys: String, CodingKey {
            case speedClass = "speed_class", preset, encodeS = "encode_s", tStepS = "t_step_s"
            case decodeSPerFrame = "decode_s_per_frame", peakGB = "peak_gb", source, n, note
        }
        public init(speedClass: String, preset: String, encodeS: Double, tStepS: Double, decodeSPerFrame: Double,
                    peakGB: Double, source: String, n: Int? = nil, note: String? = nil) {
            self.speedClass = speedClass; self.preset = preset; self.encodeS = encodeS; self.tStepS = tStepS
            self.decodeSPerFrame = decodeSPerFrame; self.peakGB = peakGB; self.source = source; self.n = n; self.note = note
        }
    }

    public var schema: Int
    public var presets: [Preset]
    public var rows: [Row]

    public init(schema: Int = 1, presets: [Preset], rows: [Row]) {
        self.schema = schema; self.presets = presets; self.rows = rows
    }

    public func preset(_ key: String) -> Preset? { presets.first { $0.key == key } }
    public func row(speedClass: String, preset: String) -> Row? { rows.first { $0.speedClass == speedClass && $0.preset == preset } }
    /// The presets this speed class has coefficients for, in table order.
    public func presets(speedClass: String) -> [Preset] { presets.filter { row(speedClass: speedClass, preset: $0.key) != nil } }

    /// The bundled table (empty when the resource is missing: every estimate is then nil, eligibility says chip).
    public static let bundled: VideoSpeedTable = {
        guard let url = Bundle.module.url(forResource: "video-speed", withExtension: "json"),
              let data = try? Data(contentsOf: url), let t = try? JSONDecoder().decode(VideoSpeedTable.self, from: data) else {
            return VideoSpeedTable(presets: [], rows: [])
        }
        return t
    }()
}

public enum VideoEstimator {
    /// Memory verdict against the budget B (donor `video-estimate.ts`: fits / tight / exceeds).
    public enum MemoryVerdict: String, Sendable, Equatable, Codable { case fits, tight, exceeds }

    /// Above this share of B the job still fits but leaves little room: `tight`.
    public static let tightShare = 0.85

    public struct Estimate: Sendable, Equatable {
        public var preset: String
        public var encodeS: Double
        /// One denoise step, already × the history factor (VideoETA compares observed steps with it).
        public var tStepS: Double
        public var steps: Int
        public var decodeS: Double
        public var historyFactor: Double
        public var verdict: MemoryVerdict
        public var source: String
        /// The whole job: encode + steps × t_step + decode (each × the history factor).
        public var seconds: Double { encodeS + Double(steps) * tStepS + decodeS }
        /// `video.estimate` "About {minutes} min on this Mac": whole minutes, rounded up, at least 1.
        public var minutes: Int { max(1, Int((seconds / 60).rounded(.up))) }
    }

    public static func verdict(peakGB: Double, residentGB: Double = 0, budgetGB: Double) -> MemoryVerdict {
        let need = peakGB + residentGB
        if need > budgetGB + 1e-9 { return .exceeds }
        return need <= tightShare * budgetGB + 1e-9 ? .fits : .tight
    }

    /// The table time of `preset` on `speedClass` before any history (nil = no row).
    public static func baseSeconds(preset: String, speedClass: String, table: VideoSpeedTable = .bundled) -> Double? {
        estimate(preset: preset, speedClass: speedClass, budgetGB: .infinity, history: [], table: table)?.seconds
    }

    /// - Parameters: `residentGB` = what must stay loaded during the job (T2: 0, chat is unloaded first; T3+: the chat
    ///   model, co-resident when it fits B). `history` = this Mac's past runs (any preset; VideoHistory filters).
    public static func estimate(preset key: String, speedClass: String, budgetGB: Double, residentGB: Double = 0,
                                history: [VideoHistory.Run] = [], table: VideoSpeedTable = .bundled) -> Estimate? {
        guard let p = table.preset(key), let r = table.row(speedClass: speedClass, preset: key) else { return nil }
        let f = VideoHistory.factor(history, preset: key)
        return Estimate(preset: key, encodeS: r.encodeS * f, tStepS: r.tStepS * f, steps: p.steps,
                        decodeS: Double(p.frames) * r.decodeSPerFrame * f, historyFactor: f,
                        verdict: verdict(peakGB: r.peakGB, residentGB: residentGB, budgetGB: budgetGB), source: r.source)
    }
}
