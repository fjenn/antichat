// M3.T12 step 2 (R-280 AC2): when a conversation falls back to half duplex (no echo cancellation on this output:
// barge-in by voice is off and the mic is gated while the assistant speaks), one line under the orb says
// `voice.headphones` — once per session: it shows when the switch happens and goes after 10 s or a click.
// Accessibility id `voice.headphonesHint`.
import AntiChatDesign
import AppKit
import SwiftUI

struct HeadphonesHint: View {
    static let visibleFor: Duration = .seconds(10)
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.space2) {
            Image(systemName: "headphones")
                .foregroundStyle(Color.textSecondary)
                .accessibilityHidden(true)
            Text(CopyKey("voice.headphones"))
                .typeStyle(.callout)
                .foregroundStyle(Color.textSecondary)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .task {
            // M3 review P2-4: with VoiceOver on, the hint stays until it is dismissed (it was announced; it must still be
            // there when the user navigates to it).
            guard !NSWorkspace.shared.isVoiceOverEnabled else { return }
            try? await Task.sleep(for: Self.visibleFor)
            onDismiss()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("voice.headphonesHint")
    }
}
