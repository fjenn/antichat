// SummaryNotice (M1.T18 step 2; R-009 AC2, R-233 AC1): the one-line `ctx.summarised` notice at the boundary of
// the summary the prompt now uses (shown once, after the last summarised message, from the moment a reply used
// it). Clicking it expands the list of the summarised turns; the originals themselves stay in the thread above,
// unchanged (non-destructive compaction).
import AntiChatDesign
import AntiChatStorage
import SwiftUI

struct SummaryNotice: View {
    struct Turn: Identifiable, Equatable {
        var id: String
        var role: MessageRole
        var text: String
    }

    /// The summarised turns, oldest first.
    let turns: [Turn]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: Spacing.space2) {
                    Image(systemName: "rectangle.compress.vertical")
                        .imageScale(.small)
                    Text(CopyText(CopyKey("ctx.summarised")))
                        .typeStyle(.footnote)
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(Color.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .probeID("summaryNotice")
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            if expanded {
                VStack(alignment: .leading, spacing: Spacing.space1) {
                    ForEach(turns) { turn in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                            Image(systemName: turn.role == .user ? "person" : "sparkle")
                                .imageScale(.small)
                                .foregroundStyle(Color.textTertiary)
                            Text(verbatim: Self.excerpt(turn.text))
                                .typeStyle(.footnote)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(2)
                        }
                        .accessibilityElement(children: .combine)
                        .probeID("summarisedTurn")
                    }
                }
                .padding(.leading, Spacing.space4)
                .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
                .probeID("summarisedTurns")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.space2)
    }

    /// First line, at most 160 characters.
    static func excerpt(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 160 ? String(trimmed.prefix(160)) + "…" : trimmed
    }
}
