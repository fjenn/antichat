// VersionSwitcher (components.md §3: ‹ 2/3 ›; states first · middle · last · single = hidden; P-shell-03). Sits in
// the reply's ActionBar row and under a user bubble with versions (M1.T10 step 3, IS-11). ‹ at the first version
// and › at the last are disabled; both are disabled while the chat is replying (the label stays, J02 reads it).
import AntiChatDesign
import SwiftUI

struct VersionSwitcher: View {
    let index: Int
    let total: Int
    var enabled = true
    /// Accessibility identifier stem: `<id>` (the "n / N" text), `<id>.previous`, `<id>.next`.
    let id: String
    let onStep: (Int) -> Void

    var body: some View {
        if total > 1 {
            HStack(spacing: Spacing.space1) {
                arrow("chevron.left", delta: -1, disabled: index <= 1, tip: "msg.version.previous", suffix: "previous")
                Text(CopyText(CopyKey("msg.version"), ["current": "\(index)", "total": "\(total)"]))
                    .typeStyle(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityIdentifier(id)
                arrow("chevron.right", delta: 1, disabled: index >= total, tip: "msg.version.next", suffix: "next")
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func arrow(_ symbol: String, delta: Int, disabled: Bool, tip: String, suffix: String) -> some View {
        Button { onStep(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled || !enabled ? Color.textTertiary : Color.textSecondary)
        .disabled(disabled || !enabled)
        .tooltip(CopyText(CopyKey(tip)))
        .accessibilityLabel(Text(CopyKey(tip)))
        .accessibilityIdentifier("\(id).\(suffix)")
    }
}
