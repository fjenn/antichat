// Calibration parameters of the decision rule (model-matrix §10.3). The shipped values live in
// Resources/thresholds.json (versioned); calibration (M4.T02) may change values (version + 1), never the rule.
import Foundation

package struct Thresholds: Sendable, Equatable {
    /// `thresholds.json` version these values came from (0 = code defaults, tests only).
    package var version: Int = 0
    /// Freepik EVA02: P(medium) + P(high) ≥ tN ⇒ nude.
    package var tN: Double = 0.35
    /// Marqo-384 (optional second signal): P(NSFW) ≥ tN2 ⇒ nude. `.infinity` = signal off.
    package var tN2: Double = 0.50
    /// Adult age boundary.
    package var adultAge: Double = 18
    /// Safety margin (years) for an age estimated from a face (+ matched body).
    package var mFace: Double = 7
    /// Safety margin (years) for a body-only age (person without a usable face).
    package var mBody: Double = 12
    /// SigLIP2 age bins (body-only second age signal): P(Child 0–12) + P(Teen 13–20) ≥ this ⇒ minor.
    /// `.infinity` = signal off (`T_age_bins: null`).
    package var tAgeBins: Double = .infinity
    /// A face is usable if Vision's confidence ≥ this…
    package var minFaceConfidence: Double = 0.5
    /// …and its shorter side ≥ this many pixels.
    package var minFaceSide: Double = 24
    /// A face belongs to a body when at least this fraction of the face box lies inside the body box.
    package var minFaceInBody: Double = 0.6
    /// Per-image deadline (seconds). Exceeding it while nude is true or unknown ⇒ block.
    package var timeout: Double = 2.0
    /// M4 review P1-3: the shortest preview side (px) at which the check counts as valid. A smaller preview is never
    /// shown (`PreviewVerdict.withhold`); finals are unaffected. `.infinity` = no preview is ever shown.
    package var previewMinSide: Double = 512

    package init() {}

    /// The file format of `thresholds.json`. `T_n2: null` turns the second nudity signal off; `T_age_bins: null`
    /// (or absent, files before v3) turns the body-only age-bin signal off.
    private struct File: Decodable {
        let version: Int
        let T_n: Double
        let T_n2: Double?
        let m_face: Double
        let m_body: Double
        let T_age_bins: Double?
        let face_min_conf: Double
        let face_min_side_px: Double
        let face_in_body_min: Double
        let timeout_ms: Double
        /// v4 (M4 review P1-3); absent (older files) = no preview is shown (fail closed).
        let preview_min_side_px: Double?
    }

    /// Decodes a `thresholds.json`. Any missing key or out-of-range value throws (the caller fails closed).
    package static func decode(_ data: Data) throws -> Thresholds {
        let f = try JSONDecoder().decode(File.self, from: data)
        let probabilities = [f.T_n, f.T_n2 ?? 0, f.T_age_bins ?? 0, f.face_min_conf, f.face_in_body_min]
        guard f.version >= 1, probabilities.allSatisfy({ (0...1).contains($0) }),
              f.m_face >= 0, f.m_body >= 0, f.face_min_side_px >= 0, f.timeout_ms > 0, (f.preview_min_side_px ?? 0) >= 0 else {
            throw ThresholdsError.invalid
        }
        var t = Thresholds()
        t.version = f.version
        t.tN = f.T_n
        t.tN2 = f.T_n2 ?? .infinity
        t.mFace = f.m_face
        t.mBody = f.m_body
        t.tAgeBins = f.T_age_bins ?? .infinity
        t.minFaceConfidence = f.face_min_conf
        t.minFaceSide = f.face_min_side_px
        t.minFaceInBody = f.face_in_body_min
        t.timeout = f.timeout_ms / 1000
        t.previewMinSide = f.preview_min_side_px ?? .infinity
        return t
    }

    /// The shipped thresholds (package resource).
    package static func bundled() throws -> Thresholds {
        guard let url = Bundle.module.url(forResource: "thresholds", withExtension: "json") else {
            throw ThresholdsError.missing
        }
        return try decode(Data(contentsOf: url))
    }
}

package enum ThresholdsError: Error, Sendable { case missing, invalid }
