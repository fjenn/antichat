// M7.T08 step 3 (R-260 AC1): [Review changes] (`conn.review`) opens a side-by-side diff of what the server changed
// since the user last accepted its tools: old vs new description and input schema per changed tool, and the added and
// removed tools. [Accept] makes the current list the accepted one (`last_reviewed_hash = tools_hash`); the changed
// tools stay on Ask until the user allows them again.
import AntiChatDesign
import AntiChatTools
import SwiftUI

struct ToolChangeReviewView: View {
    let serverName: String
    let diff: ToolChangeDiff
    var onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyText(CopyKey("mcp.toolsChanged"), ["server": serverName])).typeStyle(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.space4) {
                    ForEach(diff.changed, id: \.name) { c in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: c.name).typeStyle(.code).fontWeight(.semibold)
                            HStack(alignment: .top, spacing: Spacing.space3) {
                                side(CopyKey("conn.review.before"), c.oldDescription, c.oldSchemaJSON)
                                side(CopyKey("conn.review.after"), c.newDescription, c.newSchemaJSON)
                            }
                        }
                        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
                        .probeID("toolReview.changed.\(c.name)")
                    }
                    if !diff.added.isEmpty { list(CopyKey("conn.review.added"), diff.added) }
                    if !diff.removed.isEmpty { list(CopyKey("conn.review.removed"), diff.removed) }
                }
            }
            .frame(minHeight: 200, maxHeight: 420)
            HStack {
                Spacer()
                Button { dismiss() } label: { Text(CopyKey("conn.mcp.cancel")) }.keyboardShortcut(.cancelAction)
                Button { onAccept(); dismiss() } label: { Text(CopyKey("conn.review.accept")) }.keyboardShortcut(.defaultAction)
                    .probeID("toolReview.accept")
            }
        }
        .padding(Spacing.space5)
        .frame(width: 640)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("toolReview")
    }

    private func side(_ title: CopyKey, _ description: String, _ schema: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).typeStyle(.caption).foregroundStyle(Color.textSecondary)
            Text(verbatim: description).typeStyle(.callout).textSelection(.enabled)
            Text(verbatim: ToolHash.canonicalJSON(schema)).typeStyle(.code).foregroundStyle(Color.textSecondary)
                .textSelection(.enabled).lineLimit(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.space2)
        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.surfaceSunken))
    }

    private func list(_ title: CopyKey, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).typeStyle(.caption).foregroundStyle(Color.textSecondary)
            ForEach(names, id: \.self) { Text(verbatim: $0).typeStyle(.code) }
        }
    }
}
