// M2.T20 step 4 (R-203 AC2–AC4): the line above the composer while the first chat runs on the `chat_fast` starter —
// `starter.quick` "Quick model — full model downloading ({percent}%)", then `starter.upgraded` once after the switch to
// the tier model (next turn boundary), or `model.usingLighter` when the tier model did not fit. Hidden otherwise.
import AntiChatDesign
import AntiChatHarness
import SwiftUI

struct StarterLabel: View {
    let label: StarterLabelModel

    var body: some View {
        if let key = label.copyKey {
            HStack(spacing: Spacing.space2) {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .foregroundStyle(label == .upgraded ? Color.success : Color.textTertiary)
                    .accessibilityHidden(true)
                Text(text(key))
                    .typeStyle(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
                if case .quick(let p) = label {
                    ProgressView(value: Double(p), total: 100)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .frame(width: 64)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.space3)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("starterLabel")
            .probeID("starterLabel")
        }
    }

    private var symbol: String {
        switch label {
        case .upgraded: "checkmark.circle.fill"
        case .lighter: "memorychip"
        default: "bolt.circle"
        }
    }

    private func text(_ key: String) -> CopyText {
        if case .quick(let p) = label { return CopyText(CopyKey(key), ["percent": String(p)]) }
        return CopyText(CopyKey(key))
    }
}
