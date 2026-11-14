// M4.T08 step 1 (R-031 AC1, IS-8, NFR-P3): the image job card's percent. `floor(100 × completedSteps / totalSteps)`
// across the job (model loading counts as 0 %), monotonic (a later, lower value — a second sampling pass, a restarted
// count — never moves the pill back), and 100 % only once the result has arrived: a last step without a result shows
// 99 %. Pure value type; the card feeds it every `MediaJobQueue.Update`.
import Foundation

public struct JobProgressModel: Sendable, Equatable {
    public private(set) var percent: Int = 0
    public private(set) var hasResult = false

    public init() {}

    /// A step report (`progress` = completed / total, 0…1).
    public mutating func observe(progress: Double) {
        guard !hasResult, progress.isFinite else { return }
        let p = min(99, max(0, Int((progress * 100).rounded(.down))))
        percent = max(percent, p)
    }

    /// The final result arrived: 100 %.
    public mutating func finished() {
        hasResult = true
        percent = 100
    }
}
