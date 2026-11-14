// DislikeMenu (M1.T10 step 4; components.md ActionBar 👎): titled "What went wrong?" (`msg.dislike.title`) with
// [Try again] [Think harder] [It refused] [Report a problem…]. "It refused" writes a local `feedback(kind=refused)`
// row; "Report a problem…" opens the ReportProblemSheet shell. Nothing here sends anything anywhere.
import AntiChatDesign
import SwiftUI

struct DislikeMenu: View {
    enum Choice { case tryAgain, thinkHarder, refused, report }

    /// The chat is replying: the two regenerate rows wait for it.
    var busy = false
    let onChoose: (Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(CopyKey("msg.dislike.title"))
                .typeStyle(.headline)
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, Spacing.space2)
                .padding(.bottom, Spacing.space1)
                .accessibilityIdentifier("dislike.title")
            PopoverRow(symbol: "arrow.clockwise", label: CopyText(CopyKey("msg.dislike.tryAgain")), id: "dislike.tryAgain") {
                onChoose(.tryAgain)
            }
            .disabled(busy)
            PopoverRow(symbol: "lightbulb", label: CopyText(CopyKey("msg.dislike.thinkHarder")), id: "dislike.thinkHarder") {
                onChoose(.thinkHarder)
            }
            .disabled(busy)
            PopoverRow(symbol: "hand.raised", label: CopyText(CopyKey("msg.dislike.refused")), id: "dislike.refused") {
                onChoose(.refused)
            }
            PopoverRow(symbol: "exclamationmark.bubble", label: CopyText(CopyKey("msg.dislike.report")), id: "dislike.report") {
                onChoose(.report)
            }
        }
        .padding(Spacing.space2)
        .frame(width: 240)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dislikeMenu")
    }
}
