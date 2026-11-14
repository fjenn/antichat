// M5.T11 (R-041 AC1/AC4, NFR-P3, NFR-B3/B5; P-media-10 progress fan-out): what the VideoJobCard needs beyond the
// generic media progress — the helper's stage (`VideoProgress`: spawn → encode → denoise steps → decode frames), the
// latest gated preview set (the frames of one step, each written by the helper only after the gate allowed it), and the
// governor's state (paused hot / for another app, the `thermal.serious` line). MediaJobQueue folds the job's stream into
// it; the card re-attaches from the queue's snapshot after navigation.
// `VideoJobProgress` maps it onto the monotonic `JobProgressModel`: encode 0 %, denoise steps 0…90 %, decode frames
// 90…99 %, 100 % only with the result.
import AntiChatEngineProtocol
import Foundation

public struct VideoJobStatus: Sendable, Equatable {
    /// `spawn`, `encode`, `load`, `denoise`, `decode`, `frames`, `cancelled` (nil = not started).
    public var stage: String?
    public var step = 0
    public var total = 0
    /// The step whose preview frames are in `previewFrames` (A-M5-07: only steps ≥ 3/4 of the schedule have any).
    public var previewStep: Int?
    public var previewFrames: [String] = []
    /// "hot" (thermal critical, [Resume]) / "app" (another app on the GPU); nil = running.
    public var paused: String?
    /// The card's notice line (`thermal.serious`), nil = none.
    public var notice: String?
    /// The job's child runs at background priority (another app holds the GPU).
    public var background = false

    public init(stage: String? = nil, step: Int = 0, total: Int = 0, previewStep: Int? = nil, previewFrames: [String] = [],
                paused: String? = nil, notice: String? = nil, background: Bool = false) {
        self.stage = stage; self.step = step; self.total = total; self.previewStep = previewStep
        self.previewFrames = previewFrames; self.paused = paused; self.notice = notice; self.background = background
    }

    /// Folds a helper media event of this job. True when something the card shows changed.
    @discardableResult
    public mutating func apply(_ e: MediaEvent) -> Bool {
        let before = self
        switch e {
        case .videoProgress(let p):
            stage = p.stage
            if p.totalSteps > 0 || p.step > 0 {
                step = p.step
                total = p.totalSteps
            } else if p.stage != "denoise" {
                step = 0
                total = 0
            }
        case .scheduler(let n) where n.action == "videoState":
            paused = n.detail["paused"].flatMap { $0.isEmpty ? nil : $0 }
            notice = n.detail["notice"].flatMap { $0.isEmpty ? nil : $0 }
            background = n.detail["background"] == "1"
        case .job(.jobProgress(_, let s, let t, let path?)):
            addPreview(path, step: s)
            if stage == nil || stage == "denoise" {
                stage = "denoise"
                if s >= step { step = s; total = t }
            }
        default:
            break
        }
        return self != before
    }

    /// A gated preview frame (`preview-SSSS-FF.jpg` of step SSSS, frame FF; a single-frame step has one).
    public mutating func addPreview(_ path: String, step s: Int) {
        let st = Self.previewStep(path) ?? s
        if previewStep != st {
            previewStep = st
            previewFrames = []
        }
        if !previewFrames.contains(path) { previewFrames.append(path) }
    }

    static func previewStep(_ path: String) -> Int? {
        let name = (path as NSString).lastPathComponent
        let parts = name.split(separator: "-")
        guard parts.count >= 2, parts[0] == "preview" else { return nil }
        return Int(parts[1].prefix { $0.isNumber })
    }
}

/// The video card's percent from the stage (monotonic, 100 only with the result).
public enum VideoJobProgress {
    public static let denoiseShare = 0.90

    /// Completed fraction 0…1 for `status` (nil stage = 0).
    public static func fraction(_ s: VideoJobStatus) -> Double {
        switch s.stage {
        case "denoise"?:
            guard s.total > 0 else { return 0 }
            return denoiseShare * min(1, Double(s.step) / Double(s.total))
        case "decode"?, "frames"?, "write"?, "mux"?:
            let f = s.total > 0 ? min(1, Double(s.step) / Double(s.total)) : 0
            return denoiseShare + (1 - denoiseShare) * f
        default:
            return 0  // spawn / encode / load: 0 %
        }
    }
}
