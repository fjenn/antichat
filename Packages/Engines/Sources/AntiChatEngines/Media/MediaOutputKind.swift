// M4.T03: the gate's vocabulary for callers. Deliberately free of ChildSafetyCheck types, so no file other than
// MediaOutputGate.swift needs (or is allowed) to import that package (R-241 audit rule 1).
import CoreGraphics
import Foundation

/// What `MediaOutputGate` decided for one output.
public enum GateOutcome: Sendable, Equatable {
    /// Show and save it.
    case allow
    /// Withhold it: discard in memory, write nothing, stop the job. No reason exists.
    case block
    /// The detectors are missing or damaged (fail closed): nothing may be produced; repair size in bytes.
    case safetyMissing(sizeBytes: Int64)
}

/// Which output of a job is being checked (one gate call per preview and per final, R-285 AC1).
public enum MediaOutputKind: String, Sendable {
    case preview, result, video
}

/// One decoded video frame for `MediaOutputGate.checkVideo` (sampling and coverage happen inside the check).
public struct MediaFrame: @unchecked Sendable {
    public let index: Int
    public let image: CGImage
    public let isPreview: Bool
    public init(index: Int, image: CGImage, isPreview: Bool) {
        self.index = index
        self.image = image
        self.isPreview = isPreview
    }
}
