// M4.T03 (R-285, architecture §4.3 Media): the media-job vocabulary between the app and the helper's
// MediaOutputGate / MediaJobRunner. `jobBlocked` carries no reason, score or detail, by design (D-006);
// `safetyMissing` carries only the repair size. M4.T04: `MediaJobSubmit` (app → helper, `ClientMessage.mediaJob`)
// and the job events (helper → app, `MediaEvent.job`); cancel is the ordinary `Cancel{requestID}` of the submit.
import Foundation

public typealias MediaJobID = String

/// Where the helper finds the ChildSafetyCheck detector files (resolved by the app from the installed catalog
/// entries of the `csam_check` slot) and their pinned sha256. `sizeBytes` is the repair download size shown by
/// `safety.missing` when the files are absent or damaged.
public struct SafetyManifest: Codable, Sendable, Hashable {
    public var nudityPath: String
    public var agePath: String
    /// `csc-age-bins/model.safetensors` (the body-only second age signal, A-M4-T02b).
    public var ageBinsPath: String
    public var nudity2Path: String?
    /// sha256 per catalog key (`csc-nudity`, `csc-age`, `csc-age-bins`, optional `csc-nudity2`).
    public var sha256: [String: String]
    public var sizeBytes: Int64

    public init(nudityPath: String, agePath: String, ageBinsPath: String, nudity2Path: String? = nil,
                sha256: [String: String], sizeBytes: Int64) {
        self.nudityPath = nudityPath
        self.agePath = agePath
        self.ageBinsPath = ageBinsPath
        self.nudity2Path = nudity2Path
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }
}

/// `ClientMessage.prepareSafety`: the detector manifest to compile (idempotent: a manifest already compiled answers
/// at once; another manifest recompiles).
public struct SafetyPrepareRequest: Codable, Sendable, Hashable {
    public var requestID: UUID
    public var safety: SafetyManifest
    public init(requestID: UUID = UUID(), safety: SafetyManifest) {
        self.requestID = requestID
        self.safety = safety
    }
}

/// What a media job makes (architecture §5.1 `media_job.kind`). M4.T15: `local` = an editor operation the helper
/// runs itself (Remove background, Erase; `ImageRequest.localOperation`); its result passes the gate like any other.
public enum MediaJobKind: String, Codable, Sendable, Hashable, CaseIterable {
    case image, edit, upscale, variations, video, local
}

/// One heavy GPU job, app → helper (M4.T04 step 2). The app's `MediaJobQueue` sends at most one at a time.
/// `image.outputPath` is where the helper writes the final PNG **after** the gate allowed it; allowed previews go to
/// `previewDir` (the job's xfer dir). `safety` = the installed detector files (nil ⇒ every output `safetyMissing`).
public struct MediaJobSubmit: Codable, Sendable, Hashable {
    public var job: MediaJobID
    public var kind: MediaJobKind
    public var image: ImageRequest
    public var previewDir: String?
    public var safety: SafetyManifest?
    /// M5.T10: a video job (`kind == .video`) carries its `VideoRequest` here; `image` is then only the envelope
    /// (same request id, size and output path) so the one durable queue and the one runner carry both kinds.
    public var video: VideoRequest?

    public init(job: MediaJobID, kind: MediaJobKind = .image, image: ImageRequest, previewDir: String? = nil,
                safety: SafetyManifest?) {
        self.job = job
        self.kind = kind
        self.image = image
        self.previewDir = previewDir
        self.safety = safety
    }

    /// M5.T10: a video job through the same queue and runner as images.
    public init(job: MediaJobID, video: VideoRequest, previewDir: String? = nil, safety: SafetyManifest?) {
        self.init(job: job, kind: .video, image: Self.envelope(video), previewDir: previewDir, safety: safety)
        self.video = video
    }

    /// The `ImageRequest` envelope of a video submit (never run as an image).
    public static func envelope(_ v: VideoRequest) -> ImageRequest {
        ImageRequest(requestID: v.requestID, model: ImageModelSet(key: "video", diffusionModel: "", llm: "", vae: "", footprintBytes: v.footprintBytes),
                     prompt: v.prompt, width: v.width, height: v.height, seed: v.seed, preview: "none", outputPath: v.outputPath)
    }

    /// The submit's stream id (`Cancel{requestID}` cancels the job).
    public var requestID: UUID { video?.requestID ?? image.requestID }
}

/// Events of one media job, helper → app.
public enum MediaJobEvent: Codable, Sendable, Hashable {
    /// The helper started the job (`engineInstanceID` = the helper launch that runs it; lost detection, R-291 AC2).
    case jobStarted(job: MediaJobID, engineInstanceID: String)
    /// A sampling step finished; `previewPath` is set only for a preview the gate allowed (written after the check).
    case jobProgress(job: MediaJobID, step: Int, totalSteps: Int, previewPath: String?)
    /// The final output, allowed by the gate and written to the xfer dir.
    case jobResult(job: MediaJobID, path: String, metadata: [String: String])
    /// The gate withheld a preview or the result: nothing was written; the job stopped. No reason, by design.
    case jobBlocked(job: MediaJobID)
    /// The detectors are missing or damaged: no output may be produced; `sizeBytes` = repair download size.
    case safetyMissing(job: MediaJobID, sizeBytes: Int64)
    /// The job stopped on a cancel (user, quit prompt or memory pressure); nothing more is written.
    case jobCancelled(job: MediaJobID)
    /// The engine failed (`code` = an `AntiChatError` code); no output.
    case jobFailed(job: MediaJobID, code: String)

    public var job: MediaJobID {
        switch self {
        case .jobStarted(let j, _), .jobProgress(let j, _, _, _), .jobResult(let j, _, _), .jobBlocked(let j),
             .safetyMissing(let j, _), .jobCancelled(let j), .jobFailed(let j, _): j
        }
    }

    /// The job's last event (the row leaves `running`).
    public var isTerminal: Bool {
        switch self {
        case .jobStarted, .jobProgress: false
        default: true
        }
    }
}
