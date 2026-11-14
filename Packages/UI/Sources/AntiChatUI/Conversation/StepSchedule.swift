// fix/selection-hang: a TimelineView schedule that wakes SwiftUI only at the instants its content changes.
// `TimelineView(.periodic(from:by:))` with a sub-second interval (StatusVerb's and the reasoning line's 0.25 s, the
// video preview's 1/8 s) kept the window's view graph updating continuously while a reply or a job waited: in the
// TranscriptIdleCostTests harness 0.25 s periodic cost 2.9 s of main-thread CPU per 3 s (137k layout passes), a 1 s
// periodic nothing. Each of those updates re-placed the transcript's LazyVStack and re-updated every selectable
// Text's SelectionOverlay — the per-frame transaction chain of the XCUITest round 4 hang.
import Foundation
import SwiftUI

/// Entries: `start`, then `next(previous)` until it returns nil (each returned date must be later than the last).
struct StepSchedule: TimelineSchedule {
    let next: @Sendable (Date) -> Date?

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(upcoming: startDate, step: next)
    }

    struct Entries: Sequence, IteratorProtocol {
        var upcoming: Date?
        let step: @Sendable (Date) -> Date?

        mutating func next() -> Date? {
            guard let d = upcoming else { return nil }
            upcoming = step(d).map { Swift.max($0, d.addingTimeInterval(0.001)) }
            return d
        }
    }

    /// Every `interval` seconds from `anchor` (the next multiple after each entry), any interval: the content's own
    /// change points, not a display-rate clock.
    static func every(_ interval: TimeInterval, from anchor: Date) -> StepSchedule {
        StepSchedule { d in
            let n = (d.timeIntervalSince(anchor) / interval).rounded(.down) + 1
            return anchor.addingTimeInterval(max(0, n) * interval)
        }
    }
}
