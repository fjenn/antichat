// FreshnessHintView (M7.T05 step 2; R-228 AC1/AC4; S-10): under a finished local answer whose question probably
// needs current information while web search is off. Online: `hint.fresh` + [`hint.fresh.on`] (the consent sheet;
// accepting turns search on everywhere, the answer is not re-run) and [`hint.fresh.later`] (hides it in this chat).
// Offline: `hint.fresh.offline`, no buttons. It never turns search on by itself.
import AntiChatDesign
import AntiChatHarness
import SwiftUI

struct FreshnessHintView: View {
    let hint: FreshnessHintPolicy.Hint
    let onTurnOn: () -> Void
    let onLater: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
            Image(systemName: hint == .offline ? "wifi.slash" : "globe").foregroundStyle(Color.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.space2) {
                Text(CopyKey(hint == .offline ? "hint.fresh.offline" : "hint.fresh"))
                    .typeStyle(.callout).foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .probeID("freshHint.text")
                if hint == .offer {
                    HStack(spacing: Spacing.space2) {
                        Button(action: onTurnOn) { Text(CopyKey("hint.fresh.on")) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .probeID("freshHint.on")
                        Button(action: onLater) { Text(CopyKey("hint.fresh.later")) }
                            .buttonStyle(.borderless).controlSize(.small)
                            .probeID("freshHint.later")
                    }
                }
            }
        }
        .padding(Spacing.space3)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.textPrimary.opacity(0.05)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("freshHint")
        .probeID("freshHint")
    }
}
