// StatusVerb (components.md §3; IS-2, NFR-U3/U4): the pending assistant node's label, recomputed from
// `StatusLineModel` on a timeline: the dot alone, "Loading model…" while a load is reported, else a status verb
// after 2.5 s without text. No seconds counter for plain replies.
import AntiChatDesign
import AntiChatHarness
import SwiftUI

public struct StatusVerbView: View {
    let model: StatusLineModel
    let sentAt: Date

    public init(model: StatusLineModel, sentAt: Date) {
        self.model = model
        self.sentAt = sentAt
    }

    public var body: some View {
        // Wakes only when the line changes (2.5 s, then each verb step: StatusLineModel.nextChange), never on a
        // sub-second clock (fix/selection-hang: a 0.25 s periodic timeline updated the window's graph continuously).
        TimelineView(Self.schedule(model, sentAt: sentAt)) { context in
            let elapsed = Duration.milliseconds(Int(max(0, context.date.timeIntervalSince(sentAt)) * 1000))
            let line = model.status(elapsed: elapsed)
            HStack(spacing: Spacing.space2) {
                if line.showsDot { PendingDot() }
                if let key = line.copyKey {
                    Text(CopyText(CopyKey(key), line.copyArgs))
                        .typeStyle(.subhead)
                        .foregroundStyle(Color.textSecondary)
                        .accessibilityIdentifier("statusVerb")
                        .transition(.opacity)
                }
            }
            .tokenAnimation(.base, value: line)
        }
        .frame(minHeight: 24, alignment: .leading)
    }

    /// The instants the status line changes: now, then `nextChange` after each (none once the last verb shows).
    static func schedule(_ model: StatusLineModel, sentAt: Date) -> StepSchedule {
        StepSchedule { d in
            let elapsed = Duration.milliseconds(Int(max(0, d.timeIntervalSince(sentAt)) * 1000))
            return model.nextChange(after: elapsed).map { sentAt.addingTimeInterval(Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) }
        }
    }
}
