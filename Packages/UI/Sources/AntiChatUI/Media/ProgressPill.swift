// M4.T08 step 1 (IS-8, NFR-P3): the image job card's % pill.
import AntiChatDesign
import SwiftUI

extension EnvironmentValues {
    /// VQ round 65 (S-12): the clock a snapshot reads the % pill at (nil = live, ticking every second). Snapshots used
    /// to start their jobs in the distant future so the seconds stayed 0, and every state read "… · 0 s" at 30–90 %.
    @Entry var mediaClockNow: Date? = nil
}

/// "{percent}% · {seconds} s", the seconds ticking every second (NFR-P3: the card changes at least every second).
struct ProgressPill: View {
    let percent: Int
    let startedAt: Date
    @Environment(\.mediaClockNow) private var frozenNow

    /// The pill's text at `date`.
    static func text(percent: Int, startedAt: Date, at date: Date) -> String {
        CopyText(CopyKey("img.progress"), ["percent": "\(percent)",
                                           "seconds": "\(Int(max(0, date.timeIntervalSince(startedAt))))"]).string
    }

    var body: some View {
        if let frozenNow {
            pill(Self.text(percent: percent, startedAt: startedAt, at: frozenNow))
        } else {
            TimelineView(.periodic(from: startedAt, by: 1)) { ctx in
                pill(Self.text(percent: percent, startedAt: startedAt, at: ctx.date))
            }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(verbatim: text)
            .typeStyle(.footnote).monospacedDigit()
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, Spacing.space2).padding(.vertical, 2)
            .background(Capsule().fill(Color.surfaceRaised.opacity(0.9)))
            // M9.T05 P3: the text is the element's own AX label (the XCUITest catch-up found this pill's label empty,
            // the text only in its AX value, so a client reading the label — the P3 leg — saw a pill that never
            // changed), and it is marked as updating frequently so assistive apps re-read it while the job runs.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: text))
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("imageJobCard.progress")
    }
}
