// The only result that leaves this package (architecture §4.3: `jobBlocked` carries no reason).

extension ChildSafetyCheck {
    /// Outcome of the child-safety check for one image or one video.
    public enum Verdict: Sendable, Equatable {
        /// The output may be shown and saved.
        case allow
        /// The output is withheld (discarded unsaved). No reason detail is exposed, by design.
        case block
    }

    /// M4 review P1-3 / P2-7: outcome of the check for one live PREVIEW (never a final output).
    public enum PreviewVerdict: Sendable, Equatable {
        /// The preview may be shown.
        case show
        /// This preview is not shown and the job goes on: the check is not valid at the preview's size, or it could
        /// not finish (timeout, detector error) while nudity was true or unknown. Fail closed for the preview only;
        /// the final output is checked on its own, with the final rules.
        case withhold
        /// The rule withholds the preview (sexual and appears to involve a minor): the job stops.
        case block
    }
}
